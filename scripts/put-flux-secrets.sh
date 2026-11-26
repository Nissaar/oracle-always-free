#!/usr/bin/env bash
# Puts the two secrets Flux needs into OCI Vault, where flux-bootstrap.yml
# reads them. Values never touch OpenTofu state or GitHub.
#
#   ./scripts/put-flux-secrets.sh <path-to-age-key> <owner/your-k8s-free-gitops-copy>
#   (or export CLUSTER_REPO=owner/name instead of the second argument)
#   FLUX_DEPLOY_KEY_WRITE=false ./scripts/put-flux-secrets.sh ...   adds a READ-ONLY deploy key (use it when you turned image automation off
#   in k8s-free-gitops: LAYER_IMAGE_AUTOMATION=false); the default is a write key because image automation commits digests to main
#
# - age key: your SOPS key for the k8s-free-gitops repo (see your age/sops notes).
# - deploy key: generated here, added to the k8s-free-gitops repo with WRITE access
#   (Flux image automation commits new digests), private half -> Vault.
set -euo pipefail

AGE_KEY=${1:?usage: $0 <path-to-age-key> <owner/cluster-repo>}
CLUSTER_REPO=${2:-${CLUSTER_REPO:-}}
[[ $CLUSTER_REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]] \
  || { echo "give the repository of YOUR k8s-free-gitops copy as owner/name (argument 2 or CLUSTER_REPO)" >&2; exit 1; }
PROFILE=${OCI_PROFILE:-oracle-always-free-admin}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# The state is read with the laptop profile oracle-tfstate; AWS_* keys exported
# for another repo (cloudflare-free R2) must not override it.
out() { env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE tofu -chdir="$ROOT/bootstrap" output -raw "$1"; }
COMPARTMENT=$(out OCI_COMPARTMENT_OCID)
VAULT=$(out OCI_VAULT_OCID)
KEY=$(out OCI_VAULT_KEY_OCID)
oci_() { oci --auth security_token --profile "$PROFILE" "$@"; }

upsert() { # name, file
  local name=$1 file=$2 b64 id
  b64=$(base64 -w0 < "$file")
  id=$(oci_ vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$name" \
        --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)
  if [ -n "$id" ] && [ "$id" != "null" ]; then
    oci_ vault secret update-base64 --secret-id "$id" --secret-content-content "$b64" >/dev/null
    echo "updated $name"
  else
    oci_ vault secret create-base64 --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --key-id "$KEY" \
      --secret-name "$name" --secret-content-content "$b64" >/dev/null
    echo "created $name"
  fi
}

grep -q '^AGE-SECRET-KEY-' "$AGE_KEY" || { echo "$AGE_KEY is not an age private key" >&2; exit 1; }
upsert sops-age-key "$AGE_KEY"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t ed25519 -N '' -C "flux@oke-free" -f "$tmp/flux"
WRITE=${FLUX_DEPLOY_KEY_WRITE:-true}
case $WRITE in true | false) ;; *) echo "FLUX_DEPLOY_KEY_WRITE must be true or false" >&2; exit 1 ;; esac
if [ "$WRITE" = true ]; then
  gh repo deploy-key add "$tmp/flux.pub" --repo "$CLUSTER_REPO" --allow-write --title "flux oke-free $(date +%F)"
else
  gh repo deploy-key add "$tmp/flux.pub" --repo "$CLUSTER_REPO" --title "flux oke-free $(date +%F) (read-only)"
fi
upsert flux-deploy-key "$tmp/flux"
echo "Done. Old deploy keys can be removed in $CLUSTER_REPO -> Settings -> Deploy keys."
