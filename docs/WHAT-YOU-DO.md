# What you do, in order

Everything you have to do by hand. Commands run from the folder of YOUR private copy of this repository
(called `~/oracle-always-free` below) on your laptop unless a step says otherwise. `<your-...>` always means a value of yours;
docs/CONFIGURATION.md lists every variable and `./scripts/preflight.sh` checks them before you start. Steps 13 and 14 describe
an optional integration of the original author's own setup (a monitors repository mirrored on a home server): skip them
unless you have the same. Never paste a key or secret into
chat; the steps pipe them straight to where they belong.

## 0. Tools on the laptop (once)

### 0a. OCI CLI

```bash
python3 -m venv ~/.venvs/oci && ~/.venvs/oci/bin/pip install oci-cli
echo 'export PATH="$HOME/.venvs/oci/bin:$PATH"' >> ~/.bashrc && . ~/.bashrc
oci --version
```

### 0b. OpenTofu

OpenTofu replaced Terraform in this repo on 2026-11-06: every command is
`tofu ...`, the `terraform` binary is no longer used (you can keep it
installed; nothing here calls it).

1. In WSL, install it from OpenTofu's own apt repository (the official
   installer, Debian/Ubuntu method). It asks for your sudo password:
   ```bash
   cd /tmp
   curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
   chmod +x install-opentofu.sh
   ./install-opentofu.sh --install-method deb
   rm -f install-opentofu.sh
   cd -
   ```
   Updates then come with `sudo apt update && sudo apt upgrade`.
2. Check: `tofu version` prints `OpenTofu v1.13.x` or newer (CI uses 1.13.9;
   the code needs at least 1.12.0).
3. If you ever ran `terraform init` in this repo, delete the old provider
   downloads once (they came from registry.terraform.io):
   `rm -rf bootstrap/.terraform infra/.terraform`.

`gh`, `jq` and `age` are already installed.

## 1. Create the GitHub repos

```bash
cd ~/oracle-always-free && gh repo create <your-github-user>/oracle-always-free --private --source . --push
cd ~/k8s-free-gitops      && gh repo create <your-github-user>/k8s-free-gitops      --private --source . --push
```

## 2. Log in to Oracle from the laptop

```bash
oci session authenticate --region <your-home-region> --profile-name oracle-always-free-admin
```
A browser opens: sign in as you (the tenancy admin). The session lasts 1 hour;
`oci session refresh --profile oracle-always-free-admin` extends it.

## 3. Find your tenancy OCID

Oracle Console -> top-right profile icon -> **Tenancy: <name>** -> **OCID** -> Copy.

## 4. Run the bootstrap

1. Use a fresh terminal (no `AWS_ACCESS_KEY_ID` left over from
   cloudflare-free; the script unsets them anyway), in `~/oracle-always-free`:
   ```bash
   ./scripts/bootstrap.sh <tenancy-ocid> <your-email>
   ```
2. OpenTofu shows its plan with local state (the state bucket does not exist
   yet). Type `yes`. It creates the compartment, buckets, quotas, the $1
   budget, the CI login, the vault and the S3 users `s3-backup`, `s3-zot`
   and `s3-tfstate` with one key each. Oracle allows one budget on the
   tenancy: if you already made one in the console, the script says
   `Keeping the budget you already have` and creates none.
   It also creates the change-alert email (topic, subscription, Events rule):
   click the confirmation mail it sends, step 19.
3. Then, without asking and without printing any key, the script:
   - sets the GitHub secrets `OCI_STATE_ACCESS_KEY_ID` and
     `OCI_STATE_SECRET_ACCESS_KEY` (the `s3-tfstate` key; CI reads the state
     with it),
   - writes the same key to `~/.aws/credentials`, profile `oracle-tfstate`,
     mode 600 (your laptop reads the state with it from now on; the line
     `State key written to ... profile [oracle-tfstate]` confirms it),
   - writes `bootstrap/backend.tf` (s3 backend, your namespace) and moves
     the state into the `tfstate` bucket. A brand-new key can take a minute
     to work: lines like `State migration failed (attempt 1 of 10), retrying
     in 30 s` are normal; it gives up after 5 minutes and leaves the state
     local (nothing lost; just run the script again),
   - writes the namespace into `infra/backend.tf`, sets the repo's Actions
     variables and the `OCI_OIDC_CLIENT_SECRET` secret.
4. Check: `ls bootstrap/terraform.tfstate` says "No such file" (the state is
   in the bucket now), and GitHub -> <your-github-user>/oracle-always-free -> **Settings** ->
   **Secrets and variables** -> **Actions** lists `OCI_OIDC_CLIENT_SECRET`,
   `OCI_STATE_ACCESS_KEY_ID` and `OCI_STATE_SECRET_ACCESS_KEY`.
5. Commit the two backend files by name and push:
   ```bash
   git status --short     # bootstrap/backend.tf (new), infra/backend.tf (modified)
   git add bootstrap/backend.tf infra/backend.tf
   git commit -m "chore: set state backend" && git push
   ```
6. New laptop later (the `oracle-tfstate` profile is missing and the script
   says so): log in as in step 2, then
   `./scripts/tfstate-profile.sh --from-state`. It reads the key from the
   bootstrap state with your own Oracle login and writes the profile again
   (prints only the file name). Do not copy `~/.aws/credentials` around.

If an apply stops half-way, run the same command again: the state is local
until the end, so it carries on with what is missing. One known case: the
vault's address (`...-management.kms...`) gives `no such host` for a few
minutes after the vault is created; a re-run creates the key.

If it fails on `oci_limits_quota` (a quota name Oracle doesn't accept), re-run
with the quotas off and tell me the error:
`TF_VAR_enable_quotas=false ./scripts/bootstrap.sh ...`

If the state migration (or later a `tofu init`/`plan` in CI) fails on the lock
file (`PreconditionFailed`, `NotImplemented`, `If-None-Match`, `.tflock`):
Oracle's S3 API does not take OpenTofu's lock file. Re-run with
`STATE_LOCKFILE=false ./scripts/bootstrap.sh <tenancy-ocid> <your-email>`
and commit both backend files as in 5. From then on only the workflows'
concurrency group keeps two runs apart, so never apply `infra/` from the
laptop while a CI run is going (README "State and locking").

## 5. Create the cluster

1. GitHub -> <your-github-user>/oracle-always-free -> **Actions** -> **tofu**: wait for the
   run of your push to finish green (it is the plan). Its step "State bucket
   key (profile oracle-tfstate)" must pass; if it says
   `set OCI_STATE_ACCESS_KEY_ID`, step 4 did not set the secrets: run it
   again.
2. **Run workflow** -> branch `main` -> type `apply` -> **Run workflow**.
3. About 15 minutes. If it fails with **Out of host capacity**, Johannesburg
   has no free Arm capacity right now: run the apply again later.

## 6. S3 keys (backups and Zot)

(The third key, `s3-tfstate`, was already handled by step 4; these outputs
leave it out.)

```bash
tofu -chdir=bootstrap output -json s3_access_keys      # key ids, not secret
tofu -chdir=bootstrap output -json s3_secret_keys      # SECRET: only in your terminal
tofu -chdir=bootstrap output -raw s3_endpoint
```
- `backup` pair -> Home server, `<home-server-repo>/backup/.env`
  (see that folder's README / SETUP-GUIDE section "backup").
- `zot` pair -> now in OCI Vault (the cluster reads it through External
  Secrets). Needs step 15 first. Run (nothing is printed):
  ```bash
  jq -n --slurpfile id <(tofu -chdir=bootstrap output -json s3_access_keys) \
        --slurpfile sk <(tofu -chdir=bootstrap output -json s3_secret_keys) \
        '{AWS_ACCESS_KEY_ID: $id[0].zot, AWS_SECRET_ACCESS_KEY: $sk[0].zot}' \
    | ./scripts/put-secret.sh zot-zot-s3 -
  ```
  -> `created zot-zot-s3 (keys: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)`.

## 7. Flux secrets into the vault

```bash
age-keygen -o ~/.config/sops/age/cluster.txt      # once; back it up like your other age key
./scripts/put-flux-secrets.sh ~/.config/sops/age/cluster.txt
```
Use the public key it printed (`age1...`) in the k8s-free-gitops repo's `.sops.yaml`
before you seal any secret there (only one is left: the Vault reader key of
step 15). The script adds a write deploy key to
<your-github-user>/k8s-free-gitops (Flux commits image digests) and stores both private halves in
OCI Vault.

## 8. Install Flux

GitHub -> <your-github-user>/oracle-always-free -> Actions -> **flux-bootstrap** -> Run
workflow -> type `bootstrap`. The last step lists the Flux Kustomizations;
from then on, merging to <your-github-user>/k8s-free-gitops is the deploy.

## 9. After the Tailscale operator is up

```bash
tailscale configure kubeconfig oke-free
kubectl get nodes
flux get all -A
```

## 10. Micro VMs

1. `ssh-keygen -t ed25519 -f ~/.ssh/oracle-micros`
2. Repo -> Settings -> Secrets and variables -> Actions -> **Variables** ->
   New: `MICRO_SSH_PUBLIC_KEY` = contents of `~/.ssh/oracle-micros.pub`.
3. `enable_micros` is `true` by default and `enable_micro_kuma` is `false` (step 14 explains what it needs; set it to
   `true` in `infra/variables.tf` through a pull request when you want it). Run the apply
   (Actions -> tofu -> Run workflow -> `apply`). The apply log ends with
   `micro_private_ips`; note both addresses (`10.0.20.x`).

## 11. SSH into a micro (Bastion; used by steps 12-14)

The micros have no SSH from the internet. First time, go through the Bastion:

1. Oracle Console -> menu -> **Identity & Security** -> **Bastion** ->
   compartment `freetier` -> bastion `freetier` -> **Create session**.
2. Session type **SSH port forwarding session**; Connect to the target host
   by **IP address**; IP address = the micro's `10.0.20.x` (step 10.3, or
   Compute -> Instances -> the micro -> Private IPv4 address); Port `22`.
   SSH key: **Choose SSH key file** -> `~/.ssh/oracle-micros.pub`.
   **Create session** and wait until it is Active.
3. The session's **...** menu -> **Copy SSH command**. Paste it into a
   terminal, replace `<privateKey>` with `~/.ssh/oracle-micros` and
   `<localPort>` with `2222`, run it and leave it open.
4. Second terminal: `ssh -i ~/.ssh/oracle-micros -p 2222 ubuntu@localhost`

Once micro-edge's subnet route is approved (step 12), any laptop on the
tailnet with `tailscale set --accept-routes` can skip the Bastion:
`ssh -i ~/.ssh/oracle-micros ubuntu@10.0.20.x`.

## 12. micro-edge: Tailscale exit node, subnet router, AdGuard

> Since 12 Nov the AdGuard settings and blocklists are in git (`stacks/micro-edge/adguard/AdGuardHome.yaml`): after the setup wizard, change them there and run `./scripts/micro-edge-adguard.sh push` instead of clicking in the UI.

cloud-init has already started the stack (it needs no secret).

1. SSH into micro-edge (step 11), then:
   `cd /opt/stacks/micro-edge && sudo docker compose logs tailscale | grep login.tailscale.com`
   Open the link and log in with your Tailscale account. (Empty output:
   wait a minute after the first boot and run it again.)
2. Tailscale admin console (https://login.tailscale.com/admin/machines) ->
   `micro-edge` -> **...** -> **Edit route settings** -> tick
   `10.0.0.0/16` and **Use as exit node** -> Save.
3. Same menu -> **Disable key expiry** (else it drops off after 180 days).
4. From a device on the tailnet, open `http://micro-edge:3000` (AdGuard's
   setup wizard): Admin Web Interface **All interfaces**, port `80`; DNS
   server **All interfaces**, port `53`; create the AdGuard admin login (keep
   it in your password manager). Afterwards the UI is `http://micro-edge`.
5. Optional, to use AdGuard for the whole tailnet: admin console -> **DNS**
   -> **Add nameserver** -> **Custom** -> micro-edge's `100.x.y.z` address
   (shown on its Machines row). Leave "Override local DNS" off at first.
6. Check the ghcr.io cache (used by the GCP VM) from a tailnet device:
   `curl -s http://micro-edge:5000/v2/` prints `{}`.

## 13. Home side for the remote Kumas (OPTIONAL, original author's setup; the GCP VM uses the same)

Only if you run `enable_micro_kuma = true`. What the stack needs is generic: a git repository (any host) with AutoKuma monitor
files, a read-only token for it, optionally a webhook for alerts and a push-monitor URL of another Uptime Kuma. The steps
below describe how the original author provides those; adapt them to your own git host.

The remote Kumas fetch their monitor files from Gogs on the Home server
over the tailnet, and ping the Home Kuma there. <home-server-repo> already
has the `kuma-home` Tailscale sidecar (serves `/api/push/`); it must also
serve Gogs.

1. Gogs mirror (skip if `self-hosted` is already mirrored in Gogs): Gogs ->
   **+** -> **New Migration**. Clone address
   `https://github.com/<your-github-user>/<home-server-repo>.git`; Auth username = your GitHub
   user; Auth password = a GitHub fine-grained token with **Contents: Read**
   on `<your-github-user>/<home-server-repo>` only; tick **This repository will be a mirror**;
   Repository name `self-hosted` -> **Migrate repository**. Then the repo ->
   **Settings** -> **Mirror settings** -> Interval `1` (hour) -> Update.
   (Monitor changes reach the remote Kumas within about an hour.)
2. Read-only Gogs user: **Admin panel** -> **Users** -> **Create new
   account** -> username `kuma-sync`, any long random password. Repo
   `self-hosted` -> **Settings** -> **Collaboration** -> add `kuma-sync`,
   access **Read**.
3. Log in as `kuma-sync` in a private window -> **Your settings** ->
   **Applications** -> **Generate new token** -> name `kuma-oracle` ->
   copy the token (for step 14). Make a second one named `kuma-gcp` for the
   GCP VM later. Revoking one never affects the other.
4. The `kuma-home` sidecar already serves Gogs at `/` (<home-server-repo>
   `uptime-kuma/serve.json`, done 2026-11-06). On the Home server, after
   `git pull`: `cd <home-server-dir>/uptime-kuma && docker compose
   --profile tailnet up -d tailscale` so it picks the change up.
   (When Gogs is retired, point it at `http://gitea_app:3000` instead and
   change `GIT_URL` on both remote Kumas.)
5. Your tailnet name: admin console -> **DNS** -> "Tailnet name" (like
   `tail1234.ts.net`). The git URL is then
   `https://kuma-home.<tailnet name>/<your Gogs user>/self-hosted.git`.
6. On the Home server, in your own terminal only (these are secrets):
   `grep -E '^KUMA_(WORKER_URL|TOKEN|PUSH_TOKEN_ORACLE|PUSH_TOKEN_GCP)=' <home-server-dir>/uptime-kuma/.env`
   The push URL for Oracle is
   `https://kuma-home.<tailnet name>/api/push/<KUMA_PUSH_TOKEN_ORACLE>`
   (`uptime-kuma/setup.sh` also prints both push URLs).
7. If your tailnet has a custom access policy (not the default "allow
   all"), allow `kuma-oracle` and `kuma-gcp` to reach `kuma-home:443`,
   and `kuma-gcp` to reach `micro-edge:5000`.

## 14. micro-kuma: the "oracle" Uptime Kuma (OPTIONAL: `enable_micro_kuma = true`)

1. SSH into micro-kuma (step 11), then:
   ```bash
   cd /opt/stacks/micro-kuma
   sudo cp .env.example .env && sudo chmod 600 .env && sudo nano .env
   ```
   Fill in: `KUMA_ADMIN_USER` (e.g. `admin`), `KUMA_ADMIN_PASSWORD` (make one
   with `openssl rand -base64 24`; keep it in your password manager),
   `GIT_URL` and `GIT_USERNAME=kuma-sync` / `GIT_TOKEN` (step 13),
   `KUMA_WORKER_URL`, `KUMA_TOKEN`, `KUMA_PUSH_URL` (step 13.6). Leave
   `TS_AUTHKEY` empty. Save (Ctrl+O, Enter, Ctrl+X).
2. `sudo ./up.sh`. The first time it stops with "Tailscale is not logged in":
   `sudo docker compose logs tailscale | grep login.tailscale.com`, open the
   link, log in, then `sudo ./up.sh` again.
3. Admin console -> Machines -> `kuma-oracle` -> **...** -> **Disable key
   expiry**.
4. From a tailnet device open `https://kuma-oracle.<tailnet name>` (the
   first load can take a minute while the certificate is issued) and create
   the admin account with exactly `KUMA_ADMIN_USER` / `KUMA_ADMIN_PASSWORD`
   from `.env`.
5. Check, on the VM:
   `sudo docker compose logs sync` -> "N file(s) updated from commit ...";
   `sudo docker compose logs autokuma` -> "Created Monitor ..." lines;
   `sudo docker compose logs push` -> no lines is good. In the Home Kuma,
   the push monitor "Kuma oracle" turns green within 2 minutes.
6. Later changes to `stacks/micro-kuma/` in this repo do not reach the VM by
   themselves (cloud-init ran once). Copy the changed file, e.g. from the
   laptop with the Bastion tunnel of step 11 open:
   `scp -i ~/.ssh/oracle-micros -P 2222 stacks/micro-kuma/sync.sh ubuntu@localhost:/tmp/`
   then on the VM `sudo cp /tmp/sync.sh /opt/stacks/micro-kuma/ && sudo ./up.sh`.
   `sudo ./up.sh` alone pulls newer images (floating tags) and restarts what
   changed.

## 15. The cluster's key to the vault (External Secrets)

Every cluster secret now lives in OCI Vault `freetier`; the cluster reads
them with one read-only user, `cluster-secrets-reader`
(`bootstrap/secrets-reader.tf`: may read the secrets of this vault, nothing
else). Its API key is made on your laptop; only the public half goes to
Oracle, the private half goes sealed into the k8s-free-gitops repo. Do this before
the k8s-free-gitops repo's step 6 (Flux bootstrap); Flux retries if you are late.

1. Oracle login (step 2), or refresh it:
   `oci session refresh --profile oracle-always-free-admin`
2. Create the user, group and policy (reads the state with the laptop
   profile `oracle-tfstate` of step 4; in a fresh terminal, so no R2
   `AWS_*` keys are exported):
   ```bash
   tofu -chdir=bootstrap init -input=false
   tofu -chdir=bootstrap apply
   ```
   The plan adds 4 things (`oci_identity_domains_user.secrets_reader`,
   `oci_identity_group.secrets_reader`,
   `oci_identity_user_group_membership.secrets_reader`,
   `oci_identity_policy.secrets_reader`) and changes nothing else. Type
   `yes`. (If you have not run step 4 yet, step 4 does this for you.)
3. The k8s-free-gitops repo's `.sops.yaml` must hold your age public key (step 7,
   k8s-free-gitops repo step 2). Check: `grep age1 ~/k8s-free-gitops/.sops.yaml` shows
   your key, not `age1REPLACE_WITH_YOUR_PUBLIC_KEY`.
4. Make the key, upload its public half, seal the private half:
   ```bash
   ./scripts/make-reader-key.sh            # k8s-free-gitops repo at ~/k8s-free-gitops
   ```
   Good output: `uploaded public key xx:xx:...`, `sealed ->
   infrastructure/controllers/external-secrets/oci-vault-reader.sops.yaml`,
   `listed in ...kustomization.yaml`, `filled OCI_TENANCY_OCID,
   OCI_VAULT_OCID, OCI_VAULT_READER_OCID ...`. If the upload fails, the
   script prints the public key and the console path (Identity & Security
   -> Domains -> Default -> Users -> `cluster-secrets-reader` -> **API
   keys** -> **Add API key** -> **Paste a public key**), waits for Enter and
   carries on.
5. Commit in the k8s-free-gitops repo (by name, never `git add -A`):
   ```bash
   cd ~/k8s-free-gitops
   git status --short     # exactly the 3 files below
   git add clusters/oke/cluster-settings.yaml \
     infrastructure/controllers/external-secrets/oci-vault-reader.sops.yaml \
     infrastructure/controllers/external-secrets/kustomization.yaml
   git commit -m "External Secrets: OCI Vault reader key" && git push
   ```
6. Check in the console: Identity & Security -> Domains -> Default ->
   Users -> `cluster-secrets-reader` -> **API keys**: one key whose
   fingerprint is the one the script printed.
7. Later, to rotate: run step 4 again, commit as in 5, and once
   `kubectl get clustersecretstore oci-vault` says `Valid`/Ready, delete
   the old key with the `oci ... api-key delete` line the script printed.

## 16. Putting a secret into the vault

`./scripts/put-secret.sh <name> <file.json>` creates the Vault secret
`<name>` or adds a new version when the content changed (same content:
nothing written). `-` instead of a file reads stdin, so values can be piped
in without a file. The JSON must be one object of strings, e.g.
`{"TUNNEL_TOKEN": "..."}`. Names follow the cluster convention
`<namespace>-<secret>`; the k8s-free-gitops repo's `docs/WHAT-YOU-DO.md` (steps 5,
18, 20-22) has the exact command for each one.

- Always Free: 150 secrets per tenancy, 40 versions per secret. Each
  changed `put-secret.sh` run is one version; if Oracle ever refuses a new
  version, delete old ones: console -> Identity & Security -> Vault ->
  `freetier` -> Secrets -> the secret -> **Versions** -> `...` on an old
  version -> **Delete** (takes effect after 1 day at the earliest).
- To see what is there (names only):
  `oci --auth security_token --profile oracle-always-free-admin vault secret list --compartment-id "$(tofu -chdir=bootstrap output -raw OCI_COMPARTMENT_OCID)" --query 'data[].{name:"secret-name",state:"lifecycle-state"}' --output table`
- The cluster re-reads every secret every hour. At once:
  `kubectl -n <namespace> annotate externalsecret <secret> force-sync=$(date +%s) --overwrite`

## If the keyless login fails

The run log of "Oracle login" shows Oracle's error. Check in the Console:
Identity & Security -> Domains -> Default -> Integrated applications ->
`github-oracle-always-free` is **Activated**, and Identity & Security -> Domains ->
Default -> Security -> Identity propagation trusts -> `github-oracle-always-free`
exists. Send me the error text (it contains no secret).

## 17. OS patching of the micros

Security updates install by themselves every day; nothing reboots by itself (mode `alert`: a reminder by ntfy every 3 days while a
reboot waits, you reboot with ChatOps `reboot micro-edge <code>`). The two micros already exist, so cloud-init will not run again:
apply the same script by hand. Do the **Google VM first** (gcp-always-free `docs/WHAT-YOU-DO.md`, D), then these, then Home.
Design and secrets (names only): <home-server-repo> `ops/patch/README.md`.

1. Merge the pull request (the plan shows only `user_data` ignored: no change to the running VMs). SSH needs the Tailscale subnet
   route (step 11) or the Bastion.
2. From `~/oracle-always-free`, for **micro-edge** (private IP in the Hosts table; `<micro-edge-private-ip>` at the last check):
   ```bash
   scp -i ~/.ssh/oracle-micros patch/patch-agent patch/apply-patching.sh ubuntu@<micro-edge-private-ip>:/tmp/
   ssh -i ~/.ssh/oracle-micros ubuntu@<micro-edge-private-ip> \
     "sudo bash /tmp/apply-patching.sh --host micro-edge --day fri --kuma no --containers 'edge_tailscale edge_adguard edge_ghcr_cache' --ts-container edge_tailscale"
   ssh -i ~/.ssh/oracle-micros ubuntu@<micro-edge-private-ip>
   sudoedit /etc/patch-agent.env       # PATCH_NTFY_URL, PATCH_ALERT_URL, PATCH_HEARTBEAT_URL (names; values from <home-server-repo>)
   sudo patch-agent report             # last line ends with: feed
   exit
   ```
3. **micro-kuma** (when it exists): the same with its private IP and
   `--host micro-kuma --day fri --kuma yes --containers 'kuma_tailscale kuma_app kuma_autokuma kuma_sync kuma_push' --ts-container kuma_tailscale --push-container kuma_push`.
4. In the server topic: `patchstatus` lists both. Re-running step 2 is safe any time (it prints `already up to date`).

## 18. The node image (pull request, not patching)

Once: Actions -> **node-image** -> Run workflow. It opens a pull request that **pins** the image the pool runs now (changes nothing).
Check the plan comment shows no change to the node pool, merge. From then on a newer image arrives as a pull request every time Oracle
publishes one; `docs/NODE-IMAGE.md` says what a replacement does to the cluster before you apply it.
Optional secret (name only): `NODE_IMAGE_PR_TOKEN`.

## 19. Change alerts (email when policies, users or identity providers change)

Added 2026-11-25 (`bootstrap/audit-events.tf`, README "Change alerts"). Once, from your laptop with your own login (as in step 2):

1. Nothing to set if the alerts may go to the address you gave `bootstrap.sh`. For another address, give it on the command line (never in git):
   ```bash
   AUDIT_EMAIL=<other-address> ./scripts/bootstrap.sh <tenancy-ocid> <alert-email>
   ```
   Without it:
   ```bash
   ./scripts/bootstrap.sh <tenancy-ocid> <alert-email>
   ```
2. Read the plan: it must add one topic, one subscription and one Events rule, nothing else. Type `yes`.
3. **OPEN THE EMAIL FROM ORACLE NOTIFICATIONS AND CLICK "Confirm subscription". THE ALERTS DO NOT WORK UNTIL YOU DO.** (Spam folder too; the link lasts 7 days.)
4. Test: Console -> Identity & Security -> Policies -> any harmless policy -> edit the description -> save. A mail arrives within minutes. Put the description back.
5. Quotas and the GitHub trust do not send mail (Oracle lists no event for them); README "Change alerts" says why and how to check them in the Audit log.
