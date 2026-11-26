# oracle-always-free

Everything Oracle Cloud's **Always Free** tier offers that is useful for a small self-hosted setup, as code: a
Kubernetes cluster with two Arm nodes, micro VMs, a vault, object storage, quotas that refuse anything that
would cost money, a budget alert, and a GitHub Actions pipeline that logs in to Oracle **without a stored key**.
Built with [OpenTofu](https://opentofu.org) (`tofu`, not Terraform).

> **Use it from a PRIVATE repository of your own, not from a fork** (reasons in [Use it](#use-it), step 1).
> This is community code, not affiliated with Oracle. Free-tier limits change: check Oracle's current Always Free page.
> `Nissaar` below is the GitHub account that publishes this repository; `<your-...>` is always a value of yours.
> Every variable is listed in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## What you get for free

| Piece | Defined in | Free allowance used |
|---|---|---|
| Compartment `freetier`, VCN with a private API subnet, a private worker subnet (NAT) and a public subnet | `bootstrap/main.tf`, `infra/network.tf` | Yes |
| OKE **Basic** cluster `oke-free`, private API endpoint only | `infra/oke.tf` | Yes (Basic has no control-plane fee) |
| Node pool: 2 x Arm A1, 1 OCPU / 6 GB, 50 GB boot volume each | `infra/oke.tf` | Arm: 2 OCPU / 12 GB in total (the authors found Oracle halved the old 4 / 24 in 2026: check yours) |
| AMD `E2.1.Micro` VMs: `micro-edge` (Tailscale exit node + AdGuard), optional `micro-kuma` (Uptime Kuma) | `infra/micros.tf`, `stacks/` | up to 2 micros, if Oracle has capacity |
| Bastion for port-forwarding sessions into the VCN | `infra/bastion.tf` | Yes |
| Buckets `tfstate`, `backups`, `zot`, `openbao-snapshots` | `bootstrap/main.tf` | 20 GB object storage in total |
| Vault with a software key (Flux deploy key, SOPS age key, every cluster secret) | `bootstrap/main.tf` | 150 secrets |
| **Quotas** capping the whole tenancy at the free amounts | `bootstrap/variables.tf` | anything bigger is refused, not billed |
| **Budget** `always-free-guard` (mail on a forecast charge and when it is reached) | `bootstrap/main.tf` | Yes |
| Keyless GitHub login (OIDC trust, `<repo>-plan` read-only and `<repo>-apply` users) | `bootstrap/identity.tf` | Yes |
| E-mail alert when IAM policies, users or identity providers change | `bootstrap/audit-events.tf` | Yes (Notifications: 1,000 mails a month) |
| Optional: OS patching of the micros, node-image pull requests, a draft Tailscale policy | `patch/`, `.github/workflows/node-image.yml`, `tailscale/` | n/a |

More detail on every piece, the pipeline and the state backend: [docs/DESIGN.md](docs/DESIGN.md).

## Who it is for

You want a free, always-on Kubernetes cluster and two small VMs on Oracle Cloud, managed from git, and you are comfortable
with a terminal, GitHub and reading an OpenTofu plan. It is **not** a managed service: you operate it, you read the plans, and
Oracle can still say "Out of host capacity" in your region (see Troubleshooting). It does not need a domain; the sibling
repository `cloudflare-free` adds one.

## Accounts, tools and the one thing that can still cost money

- An **Oracle Cloud account** with a home region and tenancy-admin rights. Whether your account type (Always Free only, trial,
  or pay as you go) can create the OKE cluster and Arm nodes: **verify** on Oracle's pages. Your home region is fixed when the
  account is created: Always Free resources only exist there.
- A **GitHub account** and the GitHub CLI `gh`, logged in (`gh auth login`).
- On your laptop (Linux or WSL): `git`, `jq`, `python3`, `openssl`, [OpenTofu](https://opentofu.org/docs/intro/install/) 1.12 or newer
  (CI pins 1.13.9) and the OCI CLI. Install steps are in [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) step 0.
- An e-mail address for budget and change alerts. A Tailscale account for the micro VMs (optional).

**The one thing that can still cost money:** leaving the Always Free allowance. The quotas refuse compute, block storage and
object storage beyond the free amounts, and the budget e-mails you, but a budget is an alert, **not a cut-off**. The remaining
ways to pay are outbound traffic above Oracle's free monthly amount and anything you create by hand outside this code (or
after upgrading the account and removing the quotas). Look at **Billing -> Cost Analysis** after the first week.

## Use it

Every command runs on your laptop in the folder of your private copy. Steps marked **verify** were not run by anyone yet.

**1. Make your own PRIVATE copy** (clone, then push to a new private repository):

```bash
git clone https://github.com/Nissaar/oracle-always-free.git my-oracle-free && cd my-oracle-free
git remote rename origin upstream
gh repo create <your-github-user>/<your-private-repo> --private --source . --remote origin --push
git remote -v          # origin = your private copy, upstream = this repository
```

Why private and not a fork: the saved plan files (workflow artifacts) can contain values that are secret, pull-request comments
show your plan, and CI holds the keys to your tenancy; a public repository lets strangers read all of it, and a fork of a public
repository is always public. Why clone and not "Use this template": the shared history lets you merge updates later (see
[Keep it up to date](#keep-it-up-to-date)). Do not add other people with write access you do not trust: see Security notes.

**2. Harden the repository settings now, before the first secret exists** (web: **Settings**; the commands are **verify**):

```bash
SLUG=<your-github-user>/<your-private-repo>
# Actions: read-only default token; fork pull requests need your approval; Actions may not approve pull requests
gh api -X PUT "repos/$SLUG/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/$SLUG/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
```

Also in **Settings -> Code security**: enable secret scanning and push protection (private repositories may need GitHub's paid
secret-protection plan: the gitleaks workflow of this repository scans every push and pull request either way). **Protect
`main`** (require a pull request and one review, enforce for admins): branch protection on a private repository needs GitHub Pro,
Team or Enterprise; on the Free plan it is not available, so keep the repository single-owner. The apply identity trusts the `main`
branch, so whoever can push to `main` can apply.

**3. Log in to Oracle as the tenancy admin** (a browser opens; the session lasts 1 hour; extend it with `oci session refresh --profile oracle-always-free-admin`):

```bash
oci session authenticate --region <your-home-region> --profile-name oracle-always-free-admin
```

**4. Check everything before touching anything** (read-only; the tenancy OCID is in the Console: profile menu -> **Tenancy** -> **OCID** -> Copy):

```bash
./scripts/preflight.sh <your-tenancy-ocid> <you@example.com> <your-github-user>/<your-private-repo>
```

It lists tools, variables, files and logins as `[ ok ]`, `[warn]` or `[FAIL]` and ends with `Nothing to fix (...)` or with what to
fix. Fix every `[FAIL]` and run it again. The warning about `infra/backend.tf` is expected: the next step writes it.

**5. Bootstrap** (one command: applies `bootstrap/`, sets the GitHub secrets and variables, moves the state into Oracle):

```bash
CLUSTER_REPO=<your-github-user>/<your-k8s-free-gitops-copy> ./scripts/bootstrap.sh <your-tenancy-ocid> <you@example.com>
```

`CLUSTER_REPO` is optional here (only `flux-bootstrap.yml` needs it; you can set it later). The script validates its arguments,
writes `bootstrap/terraform.tfvars` (git-ignored), runs `tofu init` and `tofu apply`: **OpenTofu prints the full plan and waits for
you to type `yes`: that is your first plan.** Then it sets the secrets `OCI_STATE_ACCESS_KEY_ID`, `OCI_STATE_SECRET_ACCESS_KEY`,
`OCI_OIDC_CLIENT_SECRET` and the variables `OCI_TENANCY_OCID`, `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCI_NAMESPACE`,
`OCI_OIDC_DOMAIN_URL`, `OCI_OIDC_CLIENT_ID`, `OCI_VAULT_OCID`, `OCI_VAULT_KEY_OCID` without printing a key, writes the laptop profile
`oracle-tfstate` (mode 600) and migrates the state into the `tfstate` bucket. Expected lines: `==> State key (user s3-tfstate) -> GitHub
secrets and laptop profile oracle-tfstate`, possibly `State migration failed (attempt 1 of 10), retrying in 30 s` (normal for the first
minutes), and at the end `Done. Commit bootstrap/backend.tf and infra/backend.tf, then push.`

**6. Commit the two backend files (by name) and push; CI now plans your cluster:**

```bash
git status --short                                   # bootstrap/backend.tf (new), infra/backend.tf (modified)
git add bootstrap/backend.tf infra/backend.tf && git commit -m "chore: set state backend" && git push
```

**7. Read the plan.** GitHub: **Actions -> tofu**: the run of your push is the plan for `infra/` (the jobs `validate`, `trivy`,
`patch-tests`, then `plan`). When it is green, read the plan in the run summary (`Plan: N to add, 0 to change, 0 to destroy.`).
If the `plan` job is *skipped*, the variable `OCI_TENANCY_OCID` is empty: step 5 did not finish.

**8. Apply it yourself:** **Actions -> tofu -> Run workflow -> branch `main` -> type `apply`**. It applies exactly the plan of the
latest `main` commit. Expect about 15 minutes.

**9. Continue** with [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) from step 5 (S3 keys, Flux secrets, installing Flux, the micro VMs).

Only want to read a plan on your laptop, without CI? (**verify**)
```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars   # fill in your values; git-ignored
tofu -chdir=infra init && tofu -chdir=infra plan           # needs the oracle-tfstate profile that bootstrap.sh wrote
```

## How the pieces fit with the other three repositories

Order to use them: **this repository first** (cluster, vault, state), then `cloudflare-free` (domain, tunnel, logins), then
`k8s-free-gitops` (what Flux runs on the cluster). `gcp-always-free` is independent (one more small VM). Hand-offs: the vault from this
repository holds the secrets the cluster reads (`scripts/put-secret.sh`); `scripts/make-reader-key.sh` and `scripts/put-flux-secrets.sh`
connect it to your `k8s-free-gitops` copy; the Cloudflare tunnel token goes into the vault. Recipes: [docs/RECIPES.md](docs/RECIPES.md).

## Keep it up to date

```bash
git fetch upstream
git log --oneline HEAD..upstream/main          # what is new; read docs/CHANGELOG.md
git switch -c update-from-upstream
git merge upstream/main                        # keep YOUR version of infra/backend.tf, infra/node-image.auto.tfvars and anything you edited
git push -u origin update-from-upstream        # open a pull request: read the plan comment, merge, then apply
```

Never merge a plan you have not read: an update can change resources. `docs/CHANGELOG.md` says when a change needs a manual step.

## Spending caps

- **Quotas** (`quota_statements` in `bootstrap/variables.tf`): the tenancy may use at most 2 Arm cores / 12 GB, 2 micro cores, 200 GB block storage and
  20 GB object storage; Oracle refuses the rest. OpenTofu also refuses a disk layout above 200 GB before creating anything (node and micro boot volumes share it; Oracle refuses a boot volume under 50 GB).
- **Budget** `always-free-guard`: an e-mail when Oracle forecasts a charge (1 % of the budget) and when it is reached. Oracle allows one budget per tenancy: if you already have one, the script keeps it.
- Keep `enable_quotas = true`. Object storage above 20 GB, with the quota off, is billed; with it on, writes fail instead (backups stop, so watch the buckets).

## Tear it down

None of this was run by the authors, so treat it as **verify**:

1. Stop CI first (disable the `tofu` workflow) so no run holds the lock.
2. `infra/` (cluster, VMs, network): from your laptop, `tofu -chdir=infra init && tofu -chdir=infra destroy` (the laptop needs the `oracle-tfstate` profile and a fresh `oci session`).
3. `bootstrap/` (compartment, buckets, vault, IAM): Oracle will not delete non-empty buckets and the state lives in one of them. Move the state back to local
   (remove `bootstrap/backend.tf`, `tofu -chdir=bootstrap init -migrate-state`), empty the buckets in the Console, then `tofu -chdir=bootstrap destroy`.
4. Delete the GitHub secrets and variables, and the Tailscale devices. Vaults and keys are scheduled for deletion (a waiting period applies).
5. The sure way to end all spending is to terminate the Oracle account from the Console.

## Troubleshooting (real problems from building this)

| What you see | Cause and fix |
|---|---|
| `Invalid value for variable` mentioning `github_repository`, `region`, `tenancy_ocid` or `alert_email` | A required value is missing or still a placeholder. Run `./scripts/preflight.sh <tenancy-ocid> <email> <owner/repo>`; every variable and its format is in docs/CONFIGURATION.md. |
| The `plan` job is skipped | The Actions variable `OCI_TENANCY_OCID` is empty (bootstrap not finished), or the pull request comes from a fork (fork pull requests never get a plan on purpose). |
| `No successful plan for <sha>` when you apply | Apply uses the plan saved by the `push` run of the same `main` commit: push to `main` (or re-run its workflow), wait for it to pass, then apply. Artifacts expire after 7 days. |
| `Out of host capacity` when applying the node pool or a micro VM | Oracle has no free Arm or micro machines in that region right now. Run the apply again later (hours or days); capacity comes and goes. Do not pay to get around it. |
| The `Oracle login` step fails in CI | Read Oracle's error in the log. In the Console check **Identity & Security -> Domains -> Default -> Integrated applications -> `github-<repo>`** is *Activated* and **Security -> Identity propagation trusts** has a trust of that name. GitHub's token subject may carry numeric ids (`repo:Owner@123/name@456`): `bootstrap.sh` reads the prefix from GitHub; if you rename the repository or its owner, run it again. |
| `QuotaExceeded ... standard-a1-core-regional-count` | A regional limit also applies to Arm nodes. The shipped quota statements already set both the plain and the `-regional-` names; keep both. |
| `oci_limits_quota` fails on a quota name | Re-run with the quotas off and read the error: `TF_VAR_enable_quotas=false ./scripts/bootstrap.sh <tenancy-ocid> <email>`; quota names are per service, list them with `oci limits definition list --service-name compute`. Then turn the quotas back on. |
| `tofu init`/`plan`/state migration fails with `PreconditionFailed`, `NotImplemented`, `If-None-Match` or `.tflock` | Oracle's S3 API may not honour OpenTofu's lock file. Run `STATE_LOCKFILE=false ./scripts/bootstrap.sh <tenancy-ocid> <email>` and commit both backend files. Locking is then only the workflow `concurrency` group: never apply `infra/` from your laptop while a CI run is going. |
| `no such host` for `...-management.kms...` a few minutes after creating the vault | The vault's address needs minutes to appear. Run the bootstrap again; it creates the key. |
| The state migration says `retrying in 30 s` | Normal: a brand-new access key and its policy take about a minute. It gives up after 5 minutes and leaves the state local (nothing lost): run the script again. |
| Wrong credentials in the s3 backend, or a strange `403` | An `AWS_ACCESS_KEY_ID` left in your shell (for example Cloudflare R2 keys from `cloudflare-free`). Use a fresh terminal; the scripts unset them, but your own `tofu` commands do not. |
| `LimitExceeded` for the budget | Oracle allows one budget per tenancy. The script keeps an existing one and prints `Keeping the budget you already have`. |
| Boot volume refused (`47 GB` and the like) | Oracle's minimum boot volume is 50 GB. With both micros on, nodes stay at 50 GB (2 x 50 + 2 x 50 = 200). |
| Node pool update returns `409` | The node pool's Kubernetes version must follow the version in the pinned node image name (`pool_k8s_version`); the control plane may float ahead. Change the pin through the node-image pull request. |
| `node_image is not pinned` warning in every plan | Expected until you run the `node-image` workflow once and merge its pull request (docs/NODE-IMAGE.md). Until then an apply takes the newest image. |
| Bastion session cannot reach a micro | The API subnet's security list needs the SSH egress rule to the public subnet (it is in `infra/network.tf`); recreate the session after fixing. |
| Change alerts never arrive | Open the confirmation e-mail from Oracle Notifications and click **Confirm subscription** (check spam; the link expires after 7 days). |
| AdGuard keeps restarting on `micro-edge` | Out of memory with too many blocklists. Keep at most three enabled (`stacks/micro-edge/adguard/apply.sh` refuses more). |
| Editing `stacks/` changes nothing on a running micro | cloud-init runs on first boot only and `user_data` is ignored afterwards: copy the changed files to the VM (see `docs/WHAT-YOU-DO.md`) or replace the VM. |
| The `node-image` workflow cannot open a pull request | Enable **Settings -> Actions -> General -> Allow GitHub Actions to create and approve pull requests**, or add a token as the secret `NODE_IMAGE_PR_TOKEN`. (Step 2 turned that setting off on purpose: choose the token.) |
| The cluster API is unreachable from your laptop | It has no public address on purpose. Use the Bastion before Tailscale is installed in the cluster (`flux-bootstrap.yml` opens a 30-minute session), and `tailscale configure kubeconfig oke-free` after. |

## Security notes

- **Secret:** the S3 key of the state bucket (GitHub secrets `OCI_STATE_*`, laptop profile `oracle-tfstate`), the OIDC client secret
  (`OCI_OIDC_CLIENT_SECRET`, useless without a GitHub token of your repository), everything in the vault, any `.env` on the VMs, `*.tfvars`
  files. **Not secret:** OCIDs, the region, repository variables, the node image pin, the Tailscale policy draft. Do not publish them anyway.
- **The OpenTofu state contains secrets** (the S3 keys of `bootstrap/` are in its state). The `tfstate` bucket is private
  (`NoPublicAccess`), versioned, and only the `s3-tfstate` user and your admin can read it. Never copy a state file around; never commit one
  (`*.tfstate*` is git-ignored).
- **Trust rules:** only tokens of YOUR repository are accepted (`repository` claim, exact match). Pull requests become the read-only user,
  `refs/heads/main` becomes the apply user (an exact `sub eq` rule, no wildcard). Anyone who can push to `main` can apply; anyone with write
  access can run a branch workflow as the read-only user. Fork pull requests get no secrets and no OIDC token.
- **Saved plans** (`tfplan-<sha>`, 7 days) and plan comments may contain sensitive values: another reason for a private repository.
- **Open ports:** the micros accept SSH only from inside the VCN (Bastion), plus UDP 41641 for Tailscale; the cluster API is private; nothing else.
  The Bastion accepts sessions from any address by default (`bastion_allowed_cidrs`) but each needs IAM permission and a one-time key.
- **Container images** float on `:latest` by default (`.env` variables let you pin tags); GitHub Actions are pinned to commit SHAs.
- `patch/` can send status to an ntfy topic you choose: a topic on the public ntfy.sh is readable and writable by anyone who guesses the name; use a
  self-hosted ntfy with a login for anything you care about.

Report a vulnerability: [SECURITY.md](SECURITY.md).

## CI safety: pull requests from forks

- The workflows never use `pull_request_target` or `workflow_run`.
- The `plan` job, the only job that logs in to Oracle on a pull request, is skipped unless the pull request's head repository is this repository
  (`.github/workflows/tofu.yml`). Fork pull requests only run formatting, validation, tflint, trivy and the offline tests, with no credentials.
- Apply and Flux install are manual `workflow_dispatch` runs that only work on `main`. Oracle's trust maps `...:pull_request` to a read-only user
  (it cannot read secret contents) and `...:ref:refs/heads/main` to the apply user, and only for your repository's token subject.
- `bootstrap/` (IAM, quotas, budget, buckets) is never applied by CI.

## Checks (the same run in CI)

```bash
tofu fmt -check -recursive
for d in bootstrap infra; do tofu -chdir=$d init -backend=false -lockfile=readonly && tofu -chdir=$d validate; done
tflint --init && tflint --recursive
trivy config .
shellcheck patch/*.sh scripts/*.sh stacks/*/*.sh && shellcheck -S warning stacks/*/*/*.sh
(cd patch && python3 -m unittest test_patch_agent)
python3 -m unittest scripts/test_node_image_bump.py tailscale/test_check.py
python3 tailscale/check.py tailscale/policy.hujson
gitleaks detect --redact --no-banner              # release binary from github.com/gitleaks/gitleaks
```

## Layout

```
bootstrap/   run once from your laptop (scripts/bootstrap.sh); never applied by CI
infra/       applied by CI: network, cluster, bastion, micro VMs
stacks/      Docker stacks of the micro VMs (installed by cloud-init)
scripts/     preflight.sh (read-only checks), bootstrap.sh, oci-login.sh (CI), tfstate-profile.sh, put-secret.sh, make-reader-key.sh, ...
patch/       OS patching agent of the micros (offline tests)
tailscale/   DRAFT tailnet policy + offline checker (not applied for you)
docs/        CONFIGURATION.md (every variable), WHAT-YOU-DO.md (every manual step in order), DESIGN.md (how it works), NODE-IMAGE.md, RECIPES.md, CHANGELOG.md
```

Some files mention a "ChatOps" assistant, a home server and a Gogs mirror: these are optional integrations of the original author's own setup
(see recipe 3); you can ignore or delete them.

## License and contributing

MIT, see [LICENSE](LICENSE). [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md).
