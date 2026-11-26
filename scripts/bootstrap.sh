#!/usr/bin/env bash
# One-time setup, run from your laptop with your own Oracle login.
#
#   oci session authenticate --region <your-home-region> --profile-name oracle-always-free-admin
#   ./scripts/bootstrap.sh <tenancy-ocid> <alert-email> [owner/repo]
#
# Settings (environment variables, all optional; docs/CONFIGURATION.md lists every variable of this repository):
#   OCI_PROFILE      the ~/.oci/config profile of your admin login        (default oracle-always-free-admin)
#   OCI_REGION       your HOME region, e.g. eu-frankfurt-1                (default: the region of that profile)
#   CLUSTER_REPO     owner/name of your k8s-free-gitops copy; sets the Actions variable CLUSTER_REPO that
#                    flux-bootstrap.yml needs (you can also set it later with `gh variable set`)
#   AUDIT_EMAIL, STATE_LOCKFILE: see below.
#
# First run (no bootstrap/backend.tf yet): applies bootstrap/ with local state,
# copies the state bucket's S3 key (user s3-tfstate) into the GitHub secrets
# OCI_STATE_ACCESS_KEY_ID / OCI_STATE_SECRET_ACCESS_KEY and into the laptop
# profile oracle-tfstate (~/.aws/credentials, mode 600), then moves the state
# into the tfstate bucket through the s3 backend. Later runs use that profile.
#
# Safe to re-run. Your session token lasts 1 hour; if it expires:
#   oci session refresh --profile oracle-always-free-admin
#
# AUDIT_EMAIL=you@example.com ./scripts/bootstrap.sh ... sends the change alerts
# (bootstrap/audit-events.tf) to another address; default is <alert-email>.
#
# STATE_LOCKFILE=false ./scripts/bootstrap.sh ... writes use_lockfile = false
# into both backend files (fallback if Oracle rejects the S3 lock file, README
# "State and locking").
set -euo pipefail

TENANCY=${1:?usage: $0 <tenancy-ocid> <alert-email> [owner/repo]}
EMAIL=${2:?usage: $0 <tenancy-ocid> <alert-email> [owner/repo]}
REPO=${3:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
LOCKFILE=${STATE_LOCKFILE:-true}
AUDIT_EMAIL=${AUDIT_EMAIL:-}
PROFILE=${OCI_PROFILE:-oracle-always-free-admin}
CLUSTER_REPO=${CLUSTER_REPO:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CREDS=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}

# The home region: OCI_REGION, else the region of the admin profile that `oci session authenticate` wrote.
REGION=${OCI_REGION:-$(awk -v p="[$PROFILE]" '/^[[:space:]]*\[/ { in_p = ($1 == p) } in_p && $0 ~ /^[[:space:]]*region[[:space:]]*=/ { sub(/^[[:space:]]*region[[:space:]]*=[[:space:]]*/, ""); print; exit }' "$HOME/.oci/config" 2>/dev/null || true)}

[[ $TENANCY =~ ^ocid1\.tenancy\.oc1\.\.[a-z0-9]{20,}$ ]] || { echo "<tenancy-ocid> must look like ocid1.tenancy.oc1..<letters and digits> (not a placeholder)" >&2; exit 1; }
[[ $EMAIL =~ ^[^@[:space:]\<\>]+@[^@[:space:]\<\>]+\.[^@[:space:]\<\>]+$ ]] || { echo "<alert-email> must be an e-mail address" >&2; exit 1; }
[[ $REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]] || { echo "the repository must look like owner/name, got '$REPO'" >&2; exit 1; }
[[ $REGION =~ ^[a-z]{2,3}-[a-z]+-[0-9]+$ ]] || { echo "home region unknown: set OCI_REGION=<region> (for example eu-frankfurt-1) or use a profile that has a region line" >&2; exit 1; }
[ -z "$CLUSTER_REPO" ] || [[ $CLUSTER_REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]] || { echo "CLUSTER_REPO must look like owner/name" >&2; exit 1; }

case $LOCKFILE in true | false) ;; *) echo "STATE_LOCKFILE must be true or false" >&2; exit 1 ;; esac
command -v tofu >/dev/null || { echo "tofu (OpenTofu) is required: docs/WHAT-YOU-DO.md step 0" >&2; exit 1; }
command -v oci >/dev/null || { echo "oci (OCI CLI) is required: docs/WHAT-YOU-DO.md step 0" >&2; exit 1; }

# The s3 backend must use the oracle-tfstate profile, not keys left in this
# shell from another repo (cloudflare-free exports R2 keys).
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

# Oracle allows one budget on the tenancy. Keep one made in the console
# instead of failing with LimitExceeded; ours is recognised by its name.
EXISTING_BUDGET=$(oci budgets budget budget list --compartment-id "$TENANCY" \
  --target-type ALL --all --profile "$PROFILE" --auth security_token \
  --region "$REGION" --raw-output \
  --query "data[?\"display-name\" != 'always-free-guard'] | [0].id")
case $EXISTING_BUDGET in
  ocid1.budget.*) echo "==> Keeping the budget you already have ($EXISTING_BUDGET)" ;;
  *) EXISTING_BUDGET= ;;
esac

# The sub claim the trust rules must match. With GitHub's immutable subjects
# it holds IDs (repo:Owner@123/name@456), not just owner/name.
SUB_PREFIX=$(gh api "repos/$REPO/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')
SUB_PREFIX=${SUB_PREFIX:-repo:$REPO}

cat > "$ROOT/bootstrap/terraform.tfvars" <<VARS
tenancy_ocid       = "$TENANCY"
region             = "$REGION"
oci_profile        = "$PROFILE"
alert_email        = "$EMAIL"
github_repository  = "$REPO"
github_sub_prefix  = "$SUB_PREFIX"
existing_budget_id = "$EXISTING_BUDGET"
audit_email        = "$AUDIT_EMAIL"
VARS

cd "$ROOT/bootstrap"

# Points both backend files at this tenancy's namespace, your region and the lock setting
# (a backend block cannot use variables, so the values are written into the files).
set_backend() {
  local f
  for f in "$ROOT/bootstrap/backend.tf" "$ROOT/infra/backend.tf"; do
    [ -f "$f" ] || continue
    sed -i -E \
      -e "s#https://[^./\"]+\.compat\.objectstorage\.[^./\"]+\.oraclecloud\.com#https://$1.compat.objectstorage.$REGION.oraclecloud.com#" \
      -e "s#^(\s*region\s*=\s*).*#\1\"$REGION\"#" \
      -e "s#^(\s*use_lockfile\s*=\s*).*#\1$LOCKFILE#" "$f"
  done
}

FIRST_RUN=false
if [ -f backend.tf ]; then
  if ! grep -q '^\[oracle-tfstate\]' "$CREDS" 2>/dev/null; then
    echo "Profile [oracle-tfstate] is missing in $CREDS." >&2
    echo "Restore it first: ./scripts/tfstate-profile.sh --from-state (docs/WHAT-YOU-DO.md step 4.6)." >&2
    exit 1
  fi
  set_backend "$(sed -n -E 's#.*https://([^.]+)\.compat\.objectstorage.*#\1#p' backend.tf)"
  # -reconfigure: same bucket and key, only settings like use_lockfile may differ.
  tofu init -input=false -reconfigure
else
  FIRST_RUN=true
  if [ -f terraform.tfstate ] && [ -d .terraform ]; then
    echo "==> Local state found: continuing an interrupted first run"
  fi
  tofu init -input=false
fi
tofu apply -input=false

NAMESPACE=$(tofu output -raw OCI_NAMESPACE)

echo "==> State key (user s3-tfstate) -> GitHub secrets and laptop profile oracle-tfstate"
tofu output -raw tfstate_access_key_id | gh secret set OCI_STATE_ACCESS_KEY_ID --repo "$REPO"
tofu output -raw tfstate_secret_key | gh secret set OCI_STATE_SECRET_ACCESS_KEY --repo "$REPO"
(
  OCI_STATE_ACCESS_KEY_ID=$(tofu output -raw tfstate_access_key_id)
  OCI_STATE_SECRET_ACCESS_KEY=$(tofu output -raw tfstate_secret_key)
  export OCI_STATE_ACCESS_KEY_ID OCI_STATE_SECRET_ACCESS_KEY
  "$ROOT/scripts/tfstate-profile.sh"
)

# First run: move the bootstrap state from this laptop into the bucket.
if [ "$FIRST_RUN" = true ]; then
  cat > backend.tf <<TF
# Written by scripts/bootstrap.sh. Same settings as infra/backend.tf (read the
# comments there), only the key differs.
terraform {
  backend "s3" {
    bucket  = "tfstate"
    key     = "bootstrap/terraform.tfstate"
    region  = "$REGION"
    profile = "oracle-tfstate"
    endpoints = {
      s3 = "https://$NAMESPACE.compat.objectstorage.$REGION.oraclecloud.com"
    }

    use_path_style              = true
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    use_lockfile = $LOCKFILE
  }
}
TF
  # A new customer secret key and its policy can take a minute to work.
  migrated=false
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if tofu init -input=false -migrate-state -force-copy; then
      migrated=true
      break
    fi
    echo "==> State migration failed (attempt $attempt of 10), retrying in 30 s"
    sleep 30
  done
  if [ "$migrated" != true ]; then
    # Back to plain local state: drop the backend file and tofu's record of it.
    rm -f backend.tf .terraform/terraform.tfstate
    cat >&2 <<'MSG'
The state is still local (bootstrap/terraform.tfstate); nothing is lost and
backend.tf was removed again. Re-run this script once the error above is
fixed. If the error is about the lock file (PreconditionFailed, NotImplemented,
If-None-Match), re-run with STATE_LOCKFILE=false (README "State and locking").
MSG
    exit 1
  fi
  rm -f terraform.tfstate terraform.tfstate.backup
fi

set_backend "$NAMESPACE"

echo "==> GitHub Actions variables and secret on $REPO"
for name in OCI_TENANCY_OCID OCI_REGION OCI_COMPARTMENT_OCID OCI_NAMESPACE OCI_OIDC_DOMAIN_URL OCI_OIDC_CLIENT_ID OCI_VAULT_OCID OCI_VAULT_KEY_OCID; do
  gh variable set "$name" --repo "$REPO" --body "$(tofu output -raw "$name")"
done
tofu output -raw oidc_client_secret | gh secret set OCI_OIDC_CLIENT_SECRET --repo "$REPO"
if [ -n "$CLUSTER_REPO" ]; then
  gh variable set CLUSTER_REPO --repo "$REPO" --body "$CLUSTER_REPO"
else
  echo "Not set: the Actions variable CLUSTER_REPO (needed only by flux-bootstrap.yml)."
  echo "  gh variable set CLUSTER_REPO --repo $REPO --body <owner>/<your-k8s-free-gitops-copy>"
fi

echo
echo "Done. Commit bootstrap/backend.tf and infra/backend.tf, then push."
echo "S3 keys for backups and Zot: see docs/WHAT-YOU-DO.md step 6 (never paste them into chat)."
