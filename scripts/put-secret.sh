#!/usr/bin/env bash
# Create or update ONE secret in OCI Vault "freetier" from a JSON file, so
# you never paste a value into the console. The cluster reads these through
# External Secrets (ClusterSecretStore oci-vault): the Vault secret
# <namespace>-<secret> becomes the Kubernetes Secret <secret> in <namespace>,
# one key per JSON field.
#
#   ./scripts/put-secret.sh <name> <file.json>
#   jq -n --arg t "$TOKEN" '{TUNNEL_TOKEN: $t}' | ./scripts/put-secret.sh cloudflared-tunnel-token -
#
# - The file must be a JSON object whose values are all strings.
# - It is stored as compact JSON with sorted keys. If the Vault already holds
#   the same content, nothing is written (each update is a new secret version
#   and Oracle keeps at most 40 versions per secret; Always Free = 150 secrets).
# - Nothing secret is printed: only the name and the key names.
# - Login: your admin session (oci session authenticate ... oracle-always-free-admin);
#   OCIDs come from the bootstrap outputs. Override with OCI_PROFILE,
#   OCI_COMPARTMENT_OCID, OCI_VAULT_OCID, OCI_VAULT_KEY_OCID.
# - Delete the input file afterwards (shred -u <file.json>).
set -euo pipefail

die() { echo "put-secret.sh: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <name> <file.json|->"
NAME=$1
FILE=$2
PROFILE=${OCI_PROFILE:-oracle-always-free-admin}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,254}$ ]] \
  || die "name must be letters, digits, '-' or '_' (cluster convention: <namespace>-<secret>)"
command -v jq > /dev/null || die "jq is not installed"

if [ "$FILE" = "-" ]; then
  json=$(cat)
else
  [ -f "$FILE" ] || die "$FILE not found"
  json=$(cat "$FILE")
fi
printf '%s' "$json" | jq -e 'type == "object" and length > 0 and all(.[]; type == "string")' > /dev/null 2>&1 \
  || die "input must be a JSON object of string values, e.g. {\"KEY\": \"value\"} (numbers and nested objects: quote them as strings)"
canon=$(printf '%s' "$json" | jq -S -c .)
keys=$(printf '%s' "$canon" | jq -r 'keys | join(", ")')
unset json
command -v oci > /dev/null || die "oci CLI is not installed (docs/WHAT-YOU-DO.md step 0)"

# The state is read with the laptop profile oracle-tfstate; AWS_* keys exported
# for another repo (cloudflare-free R2) must not override it.
out() { env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE tofu -chdir="$ROOT/bootstrap" output -raw "$1"; }
COMPARTMENT=${OCI_COMPARTMENT_OCID:-$(out OCI_COMPARTMENT_OCID)}
VAULT=${OCI_VAULT_OCID:-$(out OCI_VAULT_OCID)}
KEY=${OCI_VAULT_KEY_OCID:-$(out OCI_VAULT_KEY_OCID)}
oci_() { oci --auth security_token --profile "$PROFILE" "$@"; }

oci_ iam region list --query 'data[0].name' --raw-output > /dev/null 2>&1 \
  || die "no valid Oracle session for profile $PROFILE: run  oci session authenticate --region <your-region> --profile-name $PROFILE  (or oci session refresh --profile $PROFILE)"

id=$(oci_ vault secret list --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --name "$NAME" \
      --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)
b64=$(printf '%s' "$canon" | base64 -w0)

if [ -n "$id" ] && [ "$id" != "null" ]; then
  current=$(oci_ secrets secret-bundle get --secret-id "$id" --stage CURRENT \
             --query 'data."secret-bundle-content".content' --raw-output 2>/dev/null \
            | base64 -d 2>/dev/null | jq -S -c . 2>/dev/null || true)
  if [ "$current" = "$canon" ]; then
    echo "unchanged $NAME (keys: $keys)"
    exit 0
  fi
  unset current
  oci_ vault secret update-base64 --secret-id "$id" --secret-content-content "$b64" > /dev/null
  echo "updated $NAME (keys: $keys)"
else
  if ! oci_ vault secret create-base64 --compartment-id "$COMPARTMENT" --vault-id "$VAULT" --key-id "$KEY" \
        --secret-name "$NAME" --description "cluster secret (External Secrets): JSON, keys $keys" \
        --secret-content-content "$b64" > /dev/null; then
    die "create failed. If $NAME was deleted recently it is still 'pending deletion': OCI console -> Identity & Security -> Vault -> freetier -> Secrets -> $NAME -> Cancel deletion, then run this again"
  fi
  echo "created $NAME (keys: $keys)"
fi
echo "The cluster picks it up within 1 hour; at once: kubectl -n <namespace> annotate externalsecret <secret> force-sync=\$(date +%s) --overwrite"
