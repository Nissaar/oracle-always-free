<!-- Design notes of the original private repository, kept as the technical reference. The README is the entry point. -->

> Design notes. Regions, names and sizes mentioned here are the original author's examples; the values you set are listed in
> [CONFIGURATION.md](CONFIGURATION.md) and the README says what to do.

# oracle-always-free

Everything on Oracle Cloud's Always Free tier in `af-johannesburg-1`, built by
OpenTofu (`tofu`) and applied by GitHub Actions with a manual apply step. GitHub
logs in to Oracle with its own OIDC token, so no Oracle API key is stored
anywhere; the only stored Oracle credential is the S3 key of the state bucket
(see "State and locking").

## What gets built

| Piece | Where | Free? |
|---|---|---|
| Compartment `freetier` | `bootstrap/main.tf` | Yes |
| Buckets `tfstate`, `backups`, `zot`, `openbao-snapshots` | `bootstrap/main.tf` | Yes, 20 GB in total |
| Quotas capping the tenancy at the Always Free amounts (Arm 2 OCPU / 12 GB, 2 micros, 200 GB disk, 20 GB object storage) | `bootstrap/main.tf` | Yes; anything bigger is refused, not billed |
| $1 budget: email on any forecast charge and on reaching $1 | `bootstrap/main.tf` | Yes |
| Keyless CI login: GitHub OIDC trust, `oracle-always-free-plan` / `oracle-always-free-apply` service users | `bootstrap/identity.tf` | Yes |
| S3 users + keys for backups (restic), Zot and the OpenTofu state (`s3-tfstate`), each limited to its bucket | `bootstrap/identity.tf` | Yes |
| Vault + software key: the Flux deploy key, the SOPS age key and every cluster secret (External Secrets) | `bootstrap/main.tf` | Yes: software keys free, 150 secrets Always Free |
| `cluster-secrets-reader` user: reads the secrets of that vault only (API key made on your laptop, never in state) | `bootstrap/secrets-reader.tf` | Yes |
| Change alerts: OCI Events rule + Notifications topic + email subscription (policies, users, identity providers; quotas and the GitHub trust NOT covered, see "Change alerts") | `bootstrap/audit-events.tf` | Yes (Events free; Notifications: 1,000 emails a month free) |
| VCN: private API subnet, private worker subnet (NAT), public subnet | `infra/network.tf` | Yes |
| OKE **Basic** cluster `oke-free`, private API endpoint only, flannel | `infra/oke.tf` | Yes (Basic = no control-plane fee) |
| Node pool: 2 x Arm A1, 1 OCPU / 6 GB, 50 GB boot each | `infra/oke.tf` | Yes |
| Bastion (port-forwarding sessions into the VCN) | `infra/bastion.tf` | Yes |
| 2 x AMD E2.1.Micro VMs (`enable_micros`, on since 2026-11-06), each running one Docker stack | `infra/micros.tf`, `stacks/` | Yes |

Disk: node boot volumes and micro boot volumes share the 200 GB. With both
micros on, nodes stay at 50 GB (2 x 50 + 2 x 50 = 200, exactly the limit; Oracle refuses a boot volume under 50 GB). OpenTofu refuses a
mix above 200 before creating anything, and the quota refuses it again.

## Pipeline

```
PR            validate (fmt, validate, tflint) + trivy -> plan as oracle-always-free-plan (read only) -> plan on the PR
push to main  same, plan as oracle-always-free-apply -> plan saved as an artifact (7 days)
manual        Actions -> tofu -> Run workflow (main), type "apply"
              -> applies exactly the plan saved for the current main commit
manual        Actions -> flux-bootstrap -> Run workflow, type "bootstrap"
              -> installs Flux through a Bastion tunnel (first time and disaster recovery)
```

- **Login.** `scripts/oci-login.sh` swaps the job's GitHub OIDC token for a
  60-minute Oracle session token at the identity domain and refreshes it every
  20 minutes. The identity Oracle hands out depends on the token's `sub`:
  `pull_request` -> plan user, `refs/heads/main` -> apply user. Tokens from any
  other repo are refused (`client_claim` = this repository).
- **Why apply is a run you start.** GitHub Free private repos have no approval
  button on environments.
- **bootstrap/ is never applied by CI.** It holds IAM, quotas, budget and
  buckets; you run it from your laptop with your own login. CI cannot delete
  buckets or change who may log in.
- Pipeline failures are picked up by ChatOps (`infra` channel polls GitHub).
- Actions are pinned by commit SHA; Renovate updates them and the
  OpenTofu/Trivy/tflint versions. OpenTofu >= 1.12.0, CI pins 1.13.9
  (`TOFU_VERSION`); providers come from registry.opentofu.org and the lock
  files cover linux_amd64, linux_arm64 and darwin_arm64.

## State and locking

OpenTofu has no `oci` backend (its built-in backends: azurerm, consul, cos,
gcs, http, kubernetes, local, oss, pg, remote, s3;
https://opentofu.org/docs/language/settings/backends/configuration/). Both
roots therefore use the `s3` backend against Oracle's S3-compatible API:

- Bucket `tfstate` (versioned, old versions kept 30 days), keys
  `bootstrap/terraform.tfstate` and `infra/terraform.tfstate`, endpoint
  `https://<namespace>.compat.objectstorage.af-johannesburg-1.oraclecloud.com`,
  region `af-johannesburg-1`, path-style, AWS-only checks and checksums off.
  `infra/backend.tf` is in git; `bootstrap/backend.tf` is written by
  `scripts/bootstrap.sh` (both get the namespace from it).
- Credentials: a customer secret key of the user `s3-tfstate`, which may only
  read the bucket and manage objects in `tfstate` (`bootstrap/identity.tf`,
  same pattern as `s3-backup` and `s3-zot`). The backend reads it from the
  AWS-style profile `oracle-tfstate` in `~/.aws/credentials`. CI writes that
  profile from the secrets `OCI_STATE_ACCESS_KEY_ID` /
  `OCI_STATE_SECRET_ACCESS_KEY` (`scripts/tfstate-profile.sh`);
  `bootstrap.sh` sets both secrets and the laptop profile (mode 600) without
  printing the key. Only the state uses this key: the OCI provider in CI
  still logs in keyless (OIDC -> session token).
- Every PR and main run sees the state key, so anyone who can push a branch
  here could write the state. Keep the repo private and single-owner (the same
  holds for the cloudflare-free API token).
- First run: `bootstrap.sh` applies `bootstrap/` with local state (the bucket
  and the key do not exist yet), then moves the state into the bucket.
- **Locking risk.** `use_lockfile = true` makes OpenTofu write
  `<key>.tflock` with a conditional PUT (`If-None-Match: *`). Whether
  Oracle's S3 API honours that header is NOT verified. The real guard is the
  workflow `concurrency` group `tofu-main` (shared by `tofu.yml` apply and
  `flux-bootstrap.yml`); PR plans never write state. Do not apply `infra/`
  from the laptop while a CI run is going.
  - If `tofu init`, `plan` or the bootstrap migration fails on the lock
    (errors such as `PreconditionFailed`, `NotImplemented` or anything naming
    `If-None-Match` / `.tflock`): run
    `STATE_LOCKFILE=false ./scripts/bootstrap.sh <tenancy-ocid> <email>`,
    which sets `use_lockfile = false` in both backend files, then commit
    them. Locking is then only the concurrency group.
  - If Oracle silently ignores the header, nothing fails and the lock simply
    protects nothing; the concurrency group still does.

## Micro VMs and their stacks

Each micro gets Docker and its stack from `stacks/<name>/` through cloud-init
(`infra/micro-cloud-init.yaml`, first boot only). Secrets are never in
OpenTofu: they go into `/opt/stacks/<name>/.env` on the VM by hand
(docs/WHAT-YOU-DO.md, steps 11-14). No swap; every container has a memory cap.

| VM | Stack | What runs | Memory caps |
|---|---|---|---|
| `micro-edge` | `stacks/micro-edge/` | Tailscale (exit node, subnet router for `10.0.0.0/16`), AdGuard Home (tailnet DNS; its whole config, blocklists included, lives in git: `stacks/micro-edge/adguard/AdGuardHome.yaml`, applied with `scripts/micro-edge-adguard.sh push`), `registry` as a read-only pull-through cache of ghcr.io on `micro-edge:5000` | 480 MB |
| `micro-kuma` | `stacks/micro-kuma/` | Uptime Kuma 2 (location `oracle`), AutoKuma, `sync` (git checkout of `uptime-kuma/remote-monitors/oracle` from the Gogs mirror on the Home server, over the tailnet), `push` (heartbeat to the Home Kuma every 60 s over the tailnet), Tailscale (serves the Kuma UI on `https://kuma-oracle.<tailnet>.ts.net`) | 720 MB |

- Everything on the tailnet: AdGuard, the ghcr cache and the Kuma UI answer on
  tailnet addresses only. Only Tailscale's UDP 41641 is published; the security
  list blocks everything else from the internet.
- Kuma's own checks leave through the normal Docker network, never through the
  tailnet or an exit node, so "oracle" really is Johannesburg.
- Alerts: AutoKuma creates a webhook notification `worker` (the alert-details
  Worker, `POST /kuma/oracle`); the Worker only pages when two locations agree.
- The ghcr cache exists for the GCP VM (IPv6 only; ghcr.io has no IPv6). It
  pulls `ghcr.io/bigboot/autokuma` through it. Tags are re-checked upstream on
  every pull, so `:latest`-style tags stay current.
- Git source: one method for both remote Kumas, Gogs on the Home server over
  the tailnet (read-only Gogs user). micro-kuma could use GitHub directly (it
  has IPv4), but the GCP VM cannot, and one setup is easier to keep right.
- The same Kuma stack lives in gcp-always-free `stacks/kuma/`; keep both copies
  identical (only `.env.example` differs).
- cloud-init only runs on the first boot and `user_data` is in
  `ignore_changes`: a stack edit here does not rebuild the VM. Copy changed
  files to the VM by hand (step 14) or replace the VM.

## Secrets for the cluster

The cluster's secrets live in OCI Vault `freetier`, one Vault secret per
Kubernetes Secret, named `<namespace>-<secret>`, content a JSON object of the
Secret's keys. External Secrets Operator in the cluster reads them as
`cluster-secrets-reader` (read `secret-bundles` and `secrets`, only where
`target.vault.id` is this vault). You write them from the laptop with
`scripts/put-secret.sh <name> <file.json>`; nothing is pasted into the
console and nothing goes through OpenTofu state. The reader's API key comes
from `scripts/make-reader-key.sh` (docs/WHAT-YOU-DO.md step 15) and is the
only secret still sealed with SOPS in the k8s-free-gitops repo.

## Reaching the cluster

The API has no public address. After Flux has installed the Tailscale
operator (k8s-free-gitops repo), you and ChatOps use `tailscale configure kubeconfig
oke-free`. Before that, and for disaster recovery, `flux-bootstrap.yml` opens a
30-minute Bastion session.

## Tailscale access rules (draft)

`tailscale/` holds a DRAFT tailnet policy that tags the servers and restricts
who may reach what (you reach every tag; ChatOps reaches only the cluster API;
the remote Kumas reach only the Home Kuma and the ghcr.io cache; servers
reach neither each other nor your devices otherwise). It is **not applied**:
no admin access exists here. `tailscale/README.md` has the exact owner steps,
the flow checks and the rollback; `python3 tailscale/check.py` and
`python3 -m unittest tailscale/test_check.py` run the offline checks (CI runs
them too).

## Change alerts

`bootstrap/audit-events.tf` sends an email when an IAM policy, a user or an
identity provider is created, changed or deleted. It is part of the bootstrap
stack, so only you can remove it (CI has no access to it). Pieces: Notifications
topic `audit-changes`, an EMAIL subscription, and the Events rule `audit-changes`
(all in the tenancy root compartment: policies and users belong to the tenancy).

- **Event types** (Oracle "Services that Produce Events", IAM section):
  `com.oraclecloud.identityControlPlane.` + `CreatePolicy`, `UpdatePolicy`,
  `DeletePolicy`, `CreateUser`, `UpdateUser`, `DeleteUser`,
  `UpdateUserCapabilities`, `UpdateUserState`, `CreateIdentityProvider`,
  `UpdateIdentityProvider`, `DeleteIdentityProvider`. Oracle's pages spell the
  prefix and the action in different cases, so the rule lists each in both.
- **Not covered, because Oracle's reference lists no event for them:** quota
  policies (Limits service) and the Identity Domains objects (the GitHub
  identity propagation trust, the OAuth app, `oci_identity_domains_user` users).
  Whether the legacy user events above also fire for domain users is unverified:
  run the test below once and see. Until then a quota or trust change sends no
  email (Console -> Observability -> Audit still records it, you just have to look).
- **Address:** `audit_email`, empty = the `alert_email` you gave
  `bootstrap.sh`. Another address: `AUDIT_EMAIL=<address> ./scripts/bootstrap.sh <tenancy-ocid> <alert-email>`
  (give it on every run: the script rewrites `bootstrap/terraform.tfvars`). The
  address is never in git.
- **After the apply: open the confirmation email from Oracle Notifications and
  click "Confirm subscription". Without that click NO alert is ever
  delivered** (Console -> Developer Services -> Notifications -> Topics ->
  `audit-changes` shows the subscription as Pending until then; check the spam
  folder; the link expires after 7 days, then delete and re-create the
  subscription by re-applying with `tofu apply -replace=oci_ons_subscription.audit_email`).
- **Test:** Console -> Identity & Security -> Policies -> any harmless policy,
  edit its description, save. The email arrives within a few minutes. Also try
  editing a user (and a domain user) to learn what is covered.
- **Remove:** delete `bootstrap/audit-events.tf` (and the `audit_email` variable),
  run `./scripts/bootstrap.sh <tenancy-ocid> <alert-email>`; the rule, topic and
  subscription are destroyed.
- The alert also fires for changes the bootstrap itself makes: expect mails
  after every bootstrap apply that touches IAM.

## OS patching

- **Micros:** `unattended-upgrades` daily, no automatic reboot (mode `alert`: reminder every 3 days, reboot with ChatOps `reboot <machine>`), post-boot check, ntfy alert with the machine name. Same script on every machine: `patch/` (README there), shipped in cloud-init and applied by hand to the existing micros (`docs/WHAT-YOU-DO.md` section 17).
- **Cluster nodes:** never patched in place. The node image is pinned in `infra/node-image.auto.tfvars`; the `node-image` workflow proposes a newer one as a pull request; the apply replaces the nodes one at a time. What restarts and what does not: `docs/NODE-IMAGE.md`.

## Layout

```
bootstrap/   run once from your laptop (scripts/bootstrap.sh); backend.tf written by it
infra/       applied by CI
stacks/      Docker stacks of the micro VMs (installed by cloud-init)
scripts/     bootstrap.sh, oci-login.sh (CI), tfstate-profile.sh (state key ->
             profile oracle-tfstate), put-flux-secrets.sh,
             put-secret.sh (any cluster secret -> Vault), make-reader-key.sh
tailscale/   DRAFT tailnet access rules + checker (not applied; tailscale/README.md)
docs/WHAT-YOU-DO.md   every manual step, in order
```

## Not tested yet

Nothing here has run against Oracle: fmt, validate, tflint and trivy pass
locally; the stacks pass `docker compose config` and shellcheck, and `sync.sh`
was run against a local git repo. First-run risks: the identity-propagation trust (Oracle's docs are
thin; modelled on falcosecurity/test-infra, which runs it in production), quota
statement names, Arm capacity in Johannesburg ("Out of host capacity":
re-run the apply later), and the s3 backend on Oracle's S3 API (the lock file
above; `tofu fmt`/`validate` pass, but no state has been written to Oracle
yet).
