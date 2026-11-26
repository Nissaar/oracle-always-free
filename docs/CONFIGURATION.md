# Configuration: every variable of this repository

Everything that is yours (accounts, region, e-mail, GitHub names) or a matter of taste (sizes, switches) is a variable.
Nothing of the original author is left in the defaults: **required** variables have no default and fail with a message
that says what is wrong. `./scripts/preflight.sh` checks them (read-only) before you start. Examples use placeholders only:
`<your-...>`, `you@example.com`.

Where a value is set:

| Where | How |
|---|---|
| **tfvars** | `bootstrap/terraform.tfvars` or `infra/terraform.tfvars` (git-ignored; `scripts/bootstrap.sh` writes the first one; `*.tfvars.example` shows the format) |
| **Actions variable / secret** | GitHub: repository **Settings -> Secrets and variables -> Actions**. `scripts/bootstrap.sh` sets most of them; CI passes them to OpenTofu as `TF_VAR_*` |
| **env** | exported in your shell for a script (`OCI_REGION=eu-frankfurt-1 ./scripts/bootstrap.sh ...`) |
| **code default** | the `default` in `variables.tf`; change it in a pull request, read the plan, merge, apply |

## 1. What you MUST set (nothing else is needed for a first plan)

| Name | Meaning | Set in | Example |
|---|---|---|---|
| tenancy OCID | your Oracle tenancy (Console: profile menu -> Tenancy -> OCID) | 1st argument of `scripts/bootstrap.sh`, then `tenancy_ocid` in tfvars and the Actions variable `OCI_TENANCY_OCID` | `ocid1.tenancy.oc1..<your-tenancy-ocid>` |
| home region | the HOME region of the tenancy (Always Free resources exist only there) | `OCI_REGION` env, or the region of your `oci session authenticate` profile; becomes `region` in tfvars and the variable `OCI_REGION` | `<your-home-region>` (for example `eu-frankfurt-1`) |
| alert e-mail | budget alerts; contact address of the S3 users | 2nd argument of `bootstrap.sh`, `alert_email` | `you@example.com` |
| GitHub repository | YOUR private copy of this repository (the OIDC trust accepts tokens of this repository only) | 3rd argument of `bootstrap.sh` (default: the repository of the current folder), `github_repository` | `<your-github-user>/<your-private-repo>` |

## 2. OpenTofu variables, `bootstrap/` (applied from your laptop, never by CI)

| Variable | Meaning | Default | Required | Validation |
|---|---|---|---|---|
| `tenancy_ocid` | tenancy OCID | none | yes | `ocid1.tenancy.oc1..<id>` |
| `region` | home region identifier | none | yes | `xx-name-N` |
| `oci_profile` | profile of `oci session authenticate` in `~/.oci/config` | `oracle-always-free-admin` | no | name characters only |
| `github_repository` | `owner/name` of your private copy | none | yes | `owner/name` |
| `github_sub_prefix` | start of GitHub's OIDC `sub` claim when your owner uses immutable subjects (`repo:Owner@123/name@456`); `bootstrap.sh` reads it from GitHub | empty (= `repo:<github_repository>`) | no | empty, or `repo:` and no wildcard |
| `alert_email` | budget alerts | none | yes | e-mail address |
| `audit_email` | change alerts (policies, users, identity providers); empty = `alert_email` | empty | no | empty or e-mail |
| `budget_amount` | alarm threshold per month in your billing currency (an alert, not a cut-off) | `1` | no | 1 to 100 |
| `existing_budget_id` | OCID of a budget you made by hand (Oracle allows one per tenancy); `bootstrap.sh` finds it | empty | no | |
| `enable_quotas` | cap the tenancy at the Always Free amounts (anything bigger is refused, not billed) | `true` | no | keep `true` |
| `quota_statements` | the quota policy statements | the Always Free caps (2 Arm cores, 12 GB, 200 GB block, 20 GB object, 2 micro cores) | no | |

## 3. OpenTofu variables, `infra/` (applied by CI)

CI sets the first four from the Actions variables (`TF_VAR_*`); on a laptop use `infra/terraform.tfvars`.

| Variable | Meaning | Default | Required | Validation / note |
|---|---|---|---|---|
| `tenancy_ocid` | tenancy OCID | none | yes | OCID shape |
| `compartment_ocid` | the `freetier` compartment made by `bootstrap/` | none | yes | OCID shape; output `OCI_COMPARTMENT_OCID` |
| `region` | home region | none | yes | `xx-name-N`; from the variable `OCI_REGION` |
| `oci_profile` | profile in `~/.oci/config` | `CI` (written by `scripts/oci-login.sh`) | no | on a laptop set your admin profile |
| `bastion_allowed_cidrs` | networks the OCI Bastion accepts sessions from (a session still needs IAM and a one-time key) | `["0.0.0.0/0"]` | no | IPv4 CIDRs; narrow it if you do not use `flux-bootstrap.yml` (GitHub runners have no fixed address) |
| `kubernetes_version` | OKE version, for example `v1.34.1` | empty (newest Oracle offers) | no | |
| `node_count` | Arm worker nodes | `2` | no | 1 to 4; the plan refuses more than 2 OCPU / 12 GB in total |
| `node_ocpus` | OCPUs per node | `1` | no | 1 to 4 |
| `node_memory_gb` | GB per node | `6` | no | 1 to 24 |
| `node_boot_volume_gb` | boot volume per node | `50` | no | at least 50; nodes + micros must fit 200 GB |
| `enable_micros` | create the micro VMs | `true` | no | |
| `enable_micro_kuma` | create `micro-kuma`, a second Uptime Kuma that needs a git repository of AutoKuma monitor files (step 14 of `docs/WHAT-YOU-DO.md`) | `false` | no | `micro-edge` does not depend on it |
| `micro_boot_volume_gb` | boot volume per micro | `50` | no | 50 to 100 |
| `micro_ssh_public_key` | PUBLIC SSH key for the `ubuntu` user of the micros (reached only through the Bastion); Actions variable `MICRO_SSH_PUBLIC_KEY` | empty (no SSH login) | no | OpenSSH public key, never a private key |
| `patch_reboot_mode` | what the micros do about a reboot an update needs: `alert`, `staggered` or `none` (read at creation only) | `alert` | no | one of the three |
| `node_image` | pin of the node image, `"<source name>\|<image OCID>"`; set by `infra/node-image.auto.tfvars` | empty (newest image; `plan` shows a warning) | no | image OCIDs are per region: the template ships none. Run the `node-image` workflow once to pin (docs/NODE-IMAGE.md) |

## 4. GitHub Actions variables and secrets

Set by `scripts/bootstrap.sh` unless a note says otherwise. Variables are not secret; secrets are.

| Name | Kind | Meaning | Set by | Required |
|---|---|---|---|---|
| `OCI_TENANCY_OCID` | variable | tenancy OCID; **while it is empty every credential job is skipped** (unconfigured template) | bootstrap.sh | yes |
| `OCI_REGION` | variable | home region | bootstrap.sh | yes |
| `OCI_COMPARTMENT_OCID` | variable | the `freetier` compartment | bootstrap.sh | yes |
| `OCI_NAMESPACE` | variable | Object Storage namespace | bootstrap.sh | yes |
| `OCI_OIDC_DOMAIN_URL` | variable | identity domain URL for the keyless login | bootstrap.sh | yes |
| `OCI_OIDC_CLIENT_ID` | variable | OAuth client of the GitHub trust | bootstrap.sh | yes |
| `OCI_VAULT_OCID`, `OCI_VAULT_KEY_OCID` | variable | the vault and its key | bootstrap.sh | yes |
| `OCI_OIDC_CLIENT_SECRET` | **secret** | secret of that OAuth client (useless without a GitHub token of your repository) | bootstrap.sh | yes |
| `OCI_STATE_ACCESS_KEY_ID`, `OCI_STATE_SECRET_ACCESS_KEY` | **secret** | S3 key of user `s3-tfstate`, limited to the `tfstate` bucket | bootstrap.sh | yes |
| `CLUSTER_REPO` | variable | `owner/name` of your `k8s-free-gitops` copy (only `flux-bootstrap.yml`) | `CLUSTER_REPO=... bootstrap.sh`, or `gh variable set CLUSTER_REPO` | for Flux |
| `MICRO_SSH_PUBLIC_KEY` | variable | public key for the micros | you | optional |
| `NODE_IMAGE_PR_TOKEN` | **secret** | fine-grained token (Contents + Pull requests: read and write on this repository only) so the plan also runs on the node-image pull request | you | optional |

## 5. Environment variables of the scripts

| Variable | Used by | Meaning | Default |
|---|---|---|---|
| `OCI_PROFILE` | `bootstrap.sh`, `put-secret.sh`, `put-flux-secrets.sh`, `make-reader-key.sh`, `tfstate-profile.sh` | admin profile | `oracle-always-free-admin` |
| `OCI_REGION` | `bootstrap.sh`, `preflight.sh` | home region | the region of that profile |
| `CLUSTER_REPO` | `bootstrap.sh`, `put-flux-secrets.sh`, `preflight.sh` | your `k8s-free-gitops` copy (`owner/name`) | none |
| `FLUX_DEPLOY_KEY_WRITE` | `put-flux-secrets.sh` | `true`: the Flux deploy key gets WRITE access to your `k8s-free-gitops` copy (image automation commits digests to `main`); `false`: read-only (use it with `LAYER_IMAGE_AUTOMATION=false`) | `true` |
| `AUDIT_EMAIL` | `bootstrap.sh` | change-alert address | `alert_email` |
| `STATE_LOCKFILE` | `bootstrap.sh` | `false` if Oracle's S3 API rejects the lock file | `true` |
| `AWS_SHARED_CREDENTIALS_FILE` | `bootstrap.sh`, `tfstate-profile.sh` | where profile `oracle-tfstate` is written (mode 600) | `~/.aws/credentials` |
| `OCI_COMPARTMENT_OCID`, `OCI_VAULT_OCID`, `OCI_VAULT_KEY_OCID` | `put-secret.sh` | override the bootstrap outputs | read from the state |
| `CLUSTER_NAME`, `NODE_IMAGE_FILE` | `node-image-bump.sh` | cluster and pin file | `oke-free`, `infra/node-image.auto.tfvars` |
| `MICRO_EDGE_SSH`, `MICRO_EDGE_KEY` | `micro-edge-adguard.sh` | `ubuntu@<private IP>` and key | none, `~/.ssh/id_rsa` |
| `MAX_LISTS`, `WAIT`, `STACK` | `stacks/micro-edge/adguard/apply.sh` (on the VM) | blocklist cap, wait seconds, stack folder | `3`, `150`, `/opt/stacks/micro-edge` |

Internal hooks, not settings: `SUB_PREFIX`, `ACTIONS_ID_TOKEN_REQUEST_*` and `GITHUB_OUTPUT` (set by GitHub Actions or by `bootstrap.sh` itself), `PATCH_ROOT`, `PATCH_NO_SYSTEMD`, `KUMA_LOCAL_URL`, `SYNC_REPO_DIR`, `SYNC_OUT_DIR` (the offline tests).

## 6. Pinned versions in the workflows (change on purpose, Renovate proposes bumps)

`TOFU_VERSION`, `TRIVY_VERSION`, `TFLINT_VERSION` (`tofu.yml`), `FLUX_OPERATOR_CHART_VERSION` and `OCI_CLI_VERSION`
(`flux-bootstrap.yml`, `node-image.yml`), `GITLEAKS_VERSION` + `GITLEAKS_SHA256` (`gitleaks.yml`: change both together, the
checksum comes from the release's checksums file). Actions are pinned to commit SHAs.

## 7. Settings of the micro VMs (`.env` on the VM, never in git)

| Stack | Variable | Meaning | Default |
|---|---|---|---|
| micro-edge | `TS_HOSTNAME`, `TS_AUTHKEY` | tailnet device name; optional auth key (empty: log in with the link in the logs) | `micro-edge`, empty |
| micro-edge | `TAILSCALE_IMAGE`, `ADGUARD_IMAGE`, `REGISTRY_IMAGE` | container images; put a version tag to pin | newest |
| micro-kuma | `TS_HOSTNAME`, `TS_AUTHKEY`, `KUMA_LOCATION`, `MONITOR_DIR` | device name, location label, folder of the monitors in the git repository | `kuma-oracle`, `oracle`, `uptime-kuma/remote-monitors/oracle` |
| micro-kuma | `KUMA_ADMIN_USER`, `KUMA_ADMIN_PASSWORD` | the Kuma admin you create on the first visit (AutoKuma logs in with it) | none: you choose |
| micro-kuma | `GIT_URL`, `GIT_BRANCH`, `GIT_USERNAME`, `GIT_TOKEN`, `SYNC_PERIOD` | git source of the monitors (read-only token) | none, `main`, empty, empty, `600` |
| micro-kuma | `KUMA_WORKER_URL`, `KUMA_TOKEN`, `KUMA_NOTIFICATION_NAME`, `KUMA_PUSH_URL`, `PUSH_PERIOD` | optional alert webhook and heartbeat | empty |
| micro-kuma | `GHCR_MIRROR`, `COMPOSE_PROFILES` | optional ghcr.io pull-through cache address and compose profile (`micro-edge:5000`; leave off on Oracle, which has IPv4) | `micro-edge:5000`, empty |
| micro-kuma | `AUTOKUMA_IMAGE`, `KUMA_IMAGE`, `GIT_IMAGE`, `CURL_IMAGE`, `SOCAT_IMAGE`, `TAILSCALE_IMAGE` | container images | see `.env.example` |
| both (patching) | `PATCH_NTFY_URL`, `PATCH_ALERT_URL`, `PATCH_HEARTBEAT_URL` in `/etc/patch-agent.env` | where patch status goes (empty = nowhere); see `patch/README.md` | empty |

## 8. Fixed on purpose (not variables)

Names other pieces depend on: compartment `freetier`, cluster `oke-free`, vault `freetier`, buckets `tfstate`, `backups`, `zot`,
`openbao-snapshots`, budget `always-free-guard`, VCN `10.0.0.0/16` and its subnets. The sibling repository `k8s-free-gitops`
refers to `oke-free` and to the vault by name. If you rename one, rename it in all four repositories.
