# Changelog

Notable changes of this public copy, newest first. Changes that need a manual step from you are marked **ACTION**.

## 2026-11-25: audit for strangers, variables, preflight

### Security
- **Removed every default that pointed at the original owner or at one region**: `github_repository`, `region` and the node image pin
  have no default any more (required, validated). The keyless-login trust therefore binds to the repository YOU name, never to a default.
- `bootstrap/backend.tf` is no longer shipped (it is written by `scripts/bootstrap.sh` on the first run; a shipped copy made the script skip the
  first run). `infra/backend.tf` carries `<namespace>` / `<region>` placeholders that the script fills in.
- `flux-bootstrap.yml`: the cluster repository comes from the Actions variable `CLUSTER_REPO` (validated, no default); the job is skipped in an
  unconfigured copy; GitHub's SSH host keys come from `api.github.com/meta` over TLS instead of `ssh-keyscan`; the Flux operator chart
  (`FLUX_OPERATOR_CHART_VERSION`) and the OCI CLI (`OCI_CLI_VERSION`, also in `node-image.yml`) are pinned.
- Workflows: `persist-credentials: false` on every checkout that does not push, `timeout-minutes` on every job, `TF_VAR_region` from the variable `OCI_REGION`.
- `put-flux-secrets.sh` no longer defaults to a repository: pass yours; `FLUX_DEPLOY_KEY_WRITE=false` adds a read-only deploy key (for a `k8s-free-gitops` copy without image automation).
- `make-reader-key.sh` also fills `OCI_REGION` and `OCI_NAMESPACE` in the cluster settings.
- Input validation in `bootstrap.sh` (tenancy OCID, e-mail, repository, region, `CLUSTER_REPO`); `github_sub_prefix` refuses wildcards.

### Added
- `docs/CONFIGURATION.md`: every variable, where it is set, default, example.
- `scripts/preflight.sh`: read-only check of tools, variables, files, logins and repository settings.
- Variables: `bastion_allowed_cidrs`, `micro_ssh_public_key` validation, validation on all sizes and OCIDs, image variables for the micro stacks
  (`TAILSCALE_IMAGE`, `ADGUARD_IMAGE`, ...), `OCI_REGION` / `OCI_PROFILE` / `CLUSTER_REPO` for the scripts.
- README: how a stranger uses the repository, step by step.

### Changed
- `enable_micro_kuma` now defaults to `false` (it needs a git repository of monitor files that only the original author had). **ACTION** if you want it: set it to `true` and follow docs/WHAT-YOU-DO.md step 14.
- `infra/node-image.auto.tfvars` ships unpinned (an image id is valid in one region only); run the `node-image` workflow once to pin (docs/NODE-IMAGE.md).
- The shell check in CI now covers every script (`scripts/*.sh`, `stacks/*/*.sh`, `patch/*.sh`, and warnings-and-up for `stacks/*/*/*.sh`).
