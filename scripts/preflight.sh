#!/usr/bin/env bash
# preflight.sh: READ-ONLY check of everything you need before ./scripts/bootstrap.sh and the first plan.
# It changes nothing: no file is written, no cloud call that creates or changes anything, no GitHub setting is touched.
#
#   ./scripts/preflight.sh                                   tools, logins, repository state; reads bootstrap/terraform.tfvars if it exists
#   ./scripts/preflight.sh <tenancy-ocid> <alert-email> [owner/repo]    also checks the three arguments you will give bootstrap.sh
#   ./scripts/preflight.sh --offline                         skip every check that needs the network (Oracle, GitHub)
#
# Settings it understands (all optional, same names as bootstrap.sh): OCI_PROFILE, OCI_REGION, CLUSTER_REPO.
# Exit code 0 = nothing to fix (warnings are advice), 1 = at least one FAIL, with what to do about it.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OFFLINE=false
ARGS=()
for a in "$@"; do
  case $a in
    --offline) OFFLINE=true ;;
    -h | --help) sed -n 2,11p "$0"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
TENANCY=${ARGS[0]:-}
EMAIL=${ARGS[1]:-}
REPO=${ARGS[2]:-}
PROFILE=${OCI_PROFILE:-oracle-always-free-admin}

fails=0
warns=0
ok() { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n%s\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }
# version_ge A B: A >= B for dotted numbers
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

section "1. Tools on this machine"
for t in git jq python3 curl openssl ssh-keygen; do
  if have "$t"; then ok "$t"; else fail "$t is not installed (sudo apt install $t)"; fi
done
if have tofu; then
  v=$(tofu version 2> /dev/null | sed -n '1s/[^0-9.]*\([0-9][0-9.]*\).*/\1/p')
  if [ -n "$v" ] && version_ge "$v" 1.12.0; then ok "tofu (OpenTofu) $v"; else fail "OpenTofu 1.12.0 or newer is required, found '${v:-none}' (docs/WHAT-YOU-DO.md step 0b). Terraform is not supported: use tofu"; fi
else
  fail "tofu (OpenTofu) is not installed (docs/WHAT-YOU-DO.md step 0b)"
fi
if have oci; then ok "oci $(oci --version 2> /dev/null | head -n1)"; else fail "the OCI CLI (oci) is not installed (docs/WHAT-YOU-DO.md step 0a)"; fi
if have gh; then ok "gh $(gh --version 2> /dev/null | head -n1 | cut -d' ' -f3)"; else fail "the GitHub CLI (gh) is not installed: https://cli.github.com/"; fi
for t in shellcheck sops age kubectl; do
  if have "$t"; then ok "$t (optional)"; else warn "$t not installed: only needed for the checks in the README or for the cluster steps after the first apply"; fi
done

section "2. Variables you must set"
if [ -n "$TENANCY" ]; then
  if [[ $TENANCY =~ ^ocid1\.tenancy\.oc1\.\.[a-z0-9]{20,}$ ]]; then ok "tenancy OCID has the right shape"; else fail "tenancy OCID '$TENANCY' is not an OCID (Console: profile menu -> Tenancy -> OCID -> Copy)"; fi
fi
if [ -n "$EMAIL" ]; then
  if [[ $EMAIL =~ ^[^@[:space:]\<\>]+@[^@[:space:]\<\>]+\.[^@[:space:]\<\>]+$ ]] && [[ $EMAIL != *@example.com ]]; then ok "alert e-mail looks real"; else fail "alert e-mail '$EMAIL' is a placeholder or not an address"; fi
fi
if [ -n "$REPO" ]; then
  if [[ $REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]]; then ok "repository $REPO"; else fail "repository '$REPO' must look like owner/name"; fi
fi
TFV=$ROOT/bootstrap/terraform.tfvars
if [ -f "$TFV" ]; then
  ok "bootstrap/terraform.tfvars exists (git-ignored)"
  for k in tenancy_ocid region alert_email github_repository; do
    val=$(sed -n -E "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TFV" | head -n1)
    if [ -z "$val" ]; then fail "bootstrap/terraform.tfvars: $k is not set"
    elif [[ $val == *"<your-"* || $val == *"<"*">"* || $val == *"aaaa..."* || $val == *@example.com ]]; then fail "bootstrap/terraform.tfvars: $k still holds a placeholder"
    else ok "bootstrap/terraform.tfvars: $k is set"; fi
  done
else
  if [ -z "$TENANCY$EMAIL" ]; then
    fail "nothing to check yet: there is no bootstrap/terraform.tfvars and you gave no arguments. Run  ./scripts/preflight.sh <tenancy-ocid> <alert-email> <owner/repo>  (the same arguments you will give bootstrap.sh)"
  fi
fi
REGION=${OCI_REGION:-$(awk -v p="[$PROFILE]" '/^[[:space:]]*\[/ { in_p = ($1 == p) } in_p && $0 ~ /^[[:space:]]*region[[:space:]]*=/ { sub(/^[[:space:]]*region[[:space:]]*=[[:space:]]*/, ""); print; exit }' "$HOME/.oci/config" 2> /dev/null || true)}
if [[ $REGION =~ ^[a-z]{2,3}-[a-z]+-[0-9]+$ ]]; then ok "home region $REGION (OCI_REGION or the region of profile $PROFILE)"
else fail "home region unknown: run  oci session authenticate --region <your-home-region> --profile-name $PROFILE  or export OCI_REGION=<region>"; fi
if [ -n "${CLUSTER_REPO:-}" ]; then
  if [[ $CLUSTER_REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]]; then ok "CLUSTER_REPO $CLUSTER_REPO"; else fail "CLUSTER_REPO must look like owner/name"; fi
else
  warn "CLUSTER_REPO is not exported: only flux-bootstrap.yml needs it (gh variable set CLUSTER_REPO --body owner/name, any time before step 8 of docs/WHAT-YOU-DO.md)"
fi
if [ -n "${MICRO_SSH_PUBLIC_KEY:-}" ] && [[ $MICRO_SSH_PUBLIC_KEY == *"PRIVATE KEY"* ]]; then fail "MICRO_SSH_PUBLIC_KEY holds a PRIVATE key: stop, use the .pub file"; fi

section "3. Files of this repository"
# Placeholders that must not be left in files you commit. backend.tf holds <namespace> and <region> until bootstrap.sh runs: expected.
left=$(cd "$ROOT" && grep -rIn -E '<your-[a-z-]+>' --include='*.tf' --include='*.tfvars' --include='*.auto.tfvars' --include='*.yml' --include='*.yaml' --include='*.hujson' . 2> /dev/null | grep -v -E '^\./(docs|\.git)/|\.example|\.env|^[^:]+:[0-9]+:[[:space:]]*(#|//)' | head -n 5)
if [ -z "$left" ]; then ok "no <your-...> placeholder in the code files"; else fail "placeholders left in files you would commit:"; printf '%s\n' "$left" | sed 's/^/           /'; fi
if grep -q '<namespace>' "$ROOT/infra/backend.tf" 2> /dev/null; then
  warn "infra/backend.tf still has <namespace>/<region>: scripts/bootstrap.sh writes them; commit the file afterwards"
else
  ok "infra/backend.tf has been written for your tenancy"
fi
if [ -f "$ROOT/bootstrap/backend.tf" ]; then ok "bootstrap/backend.tf exists (bootstrap already ran once)"; else ok "no bootstrap/backend.tf yet (the first bootstrap writes it)"; fi
if [ -n "$(cd "$ROOT" && git ls-files '*.tfvars' '*.tfstate' '*.pem' '.env' 2> /dev/null | grep -v -E '\.example$|node-image\.auto\.tfvars$')" ]; then fail "a tfvars, state, key or .env file is tracked by git: git rm --cached it (it may hold secrets)"; else ok "no tfvars, state, key or .env file is tracked by git"; fi
if (cd "$ROOT" && tofu fmt -check -recursive > /dev/null 2>&1); then ok "tofu fmt -check"; else warn "tofu fmt -check reports unformatted files: tofu fmt -recursive"; fi
if [ -n "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_PROFILE:-}" ]; then warn "AWS_* variables are set in this shell (for example Cloudflare R2 keys): they override the oracle-tfstate profile of your own tofu commands. Use a fresh terminal (bootstrap.sh unsets them itself)"; else ok "no AWS_* variables in this shell"; fi

section "4. Logins and repository settings (network)"
if [ "$OFFLINE" = true ]; then
  warn "--offline: Oracle and GitHub were not asked"
else
  if have gh; then
    if gh auth status > /dev/null 2>&1; then ok "gh is logged in"; else fail "gh is not logged in: gh auth login"; fi
  fi
  if have oci; then
    if oci iam region list --auth security_token --profile "$PROFILE" > /dev/null 2>&1; then ok "Oracle session for profile $PROFILE is valid"
    else fail "no valid Oracle session for profile $PROFILE: oci session authenticate --region <your-home-region> --profile-name $PROFILE   (or: oci session refresh --profile $PROFILE)"; fi
  fi
  if have gh && gh auth status > /dev/null 2>&1; then
    slug=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null || true)}
    if [ -z "$slug" ]; then
      warn "no GitHub repository found for this folder yet: create YOUR private copy first (README, step 1)"
    else
      priv=$(gh repo view "$slug" --json isPrivate,isFork --jq '"\(.isPrivate) \(.isFork)"' 2> /dev/null || true)
      case $priv in
        "true false") ok "$slug is private and is not a fork" ;;
        "true true") warn "$slug is a private fork: prefer 'Use this template' (a fork of a public repository cannot be made independent of it)" ;;
        "false"*) fail "$slug is PUBLIC: the plan output and the CI trust belong in a PRIVATE repository (gh repo edit $slug --visibility private --accept-visibility-change-consequences)" ;;
        *) warn "could not read the visibility of $slug (no access? wrong name?)" ;;
      esac
      # verify: these endpoints exist for repositories you administer; a 404 or 403 only means we could not read the setting
      pol=$(gh api "repos/$slug/actions/permissions/workflow" --jq .default_workflow_permissions 2> /dev/null || true)
      case $pol in
        read) ok "Actions default token permission is read" ;;
        write) fail "Actions default token permission is write: Settings -> Actions -> General -> Workflow permissions -> Read repository contents" ;;
        *) warn "could not read the Actions workflow permissions (verify in Settings -> Actions -> General)" ;;
      esac
      fpr=$(gh api "repos/$slug/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2> /dev/null || true)
      if [ -n "$fpr" ]; then
        if [ "$fpr" = all_external_contributors ]; then ok "fork pull requests need approval from you"; else warn "fork pull request approval is '$fpr': set Settings -> Actions -> General -> Fork pull request workflows -> Require approval for all external contributors"; fi
      else
        warn "could not read the fork pull request approval setting (verify in Settings -> Actions -> General)"
      fi
      ss=$(gh api "repos/$slug" --jq '.security_and_analysis.secret_scanning.status // empty' 2> /dev/null || true)
      if [ "$ss" = enabled ]; then ok "secret scanning is enabled"; else warn "secret scanning is not enabled or not readable: Settings -> Code security (verify; it can need GitHub Team or Enterprise on a private repository)"; fi
      br=$(gh api "repos/$slug/branches/main/protection" --jq .url 2> /dev/null || true)
      if [ -n "$br" ]; then ok "branch main is protected"; else warn "branch main has no protection (or the plan does not offer it on private repositories): do not give write access to anybody you do not trust; the apply identity trusts the main branch (README, security notes)"; fi
    fi
  fi
fi

section "Result"
if [ "$fails" -eq 0 ]; then
  printf '  Nothing to fix (%d warning(s)). Next: ./scripts/bootstrap.sh <tenancy-ocid> <alert-email>  (README, step 3)\n' "$warns"
  exit 0
fi
printf '  %d thing(s) to fix (the [FAIL] lines above), %d warning(s). Nothing was changed by this script.\n' "$fails" "$warns"
exit 1
