#!/usr/bin/env bash
# Writes the S3 key of the state bucket into the AWS-style credentials file,
# profile oracle-tfstate (mode 600). The s3 backend of bootstrap/ and infra/
# reads it from there. Never prints the key.
#
#   CI / bootstrap.sh:
#     OCI_STATE_ACCESS_KEY_ID=... OCI_STATE_SECRET_ACCESS_KEY=... ./scripts/tfstate-profile.sh
#   New laptop (profile lost): read the key from the bootstrap state with your
#   own Oracle login (oci session authenticate ... --profile-name oracle-always-free-admin):
#     ./scripts/tfstate-profile.sh --from-state
#
# File: $AWS_SHARED_CREDENTIALS_FILE or ~/.aws/credentials. Other profiles in
# it are kept; an older [oracle-tfstate] section is replaced.
set -euo pipefail
umask 077

PROFILE=oracle-tfstate
FILE=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}

if [ "${1:-}" = "--from-state" ]; then
  command -v oci >/dev/null || { echo "oci CLI missing (docs/WHAT-YOU-DO.md step 0)" >&2; exit 1; }
  command -v jq >/dev/null || { echo "jq missing (sudo apt install jq)" >&2; exit 1; }
  oci_() { oci --auth security_token --profile "${OCI_PROFILE:-oracle-always-free-admin}" "$@"; }
  ns=$(oci_ os ns get --query data --raw-output)
  state=$(oci_ os object get --namespace "$ns" --bucket-name tfstate \
    --name bootstrap/terraform.tfstate --file -)
  OCI_STATE_ACCESS_KEY_ID=$(jq -er '.outputs.tfstate_access_key_id.value' <<<"$state")
  OCI_STATE_SECRET_ACCESS_KEY=$(jq -er '.outputs.tfstate_secret_key.value' <<<"$state")
  unset state
elif [ $# -gt 0 ]; then
  echo "usage: $0 [--from-state]" >&2
  exit 1
fi

: "${OCI_STATE_ACCESS_KEY_ID:?set OCI_STATE_ACCESS_KEY_ID (or use --from-state)}"
: "${OCI_STATE_SECRET_ACCESS_KEY:?set OCI_STATE_SECRET_ACCESS_KEY (or use --from-state)}"

mkdir -p "$(dirname "$FILE")"
touch "$FILE"
chmod 600 "$FILE"
tmp=$(mktemp "$FILE.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# Everything except an existing [oracle-tfstate] section, then the new one.
# printf is a shell builtin: the key never shows up in the process list.
awk -v p="[$PROFILE]" '/^[[:space:]]*\[/ { skip = ($1 == p) } !skip { print }' "$FILE" > "$tmp"
sep=""
if [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ]; then sep=$'\n'; fi
{
  printf '%s' "$sep"
  printf '[%s]\n' "$PROFILE"
  printf 'aws_access_key_id = %s\n' "$OCI_STATE_ACCESS_KEY_ID"
  printf 'aws_secret_access_key = %s\n' "$OCI_STATE_SECRET_ACCESS_KEY"
} >> "$tmp"
mv "$tmp" "$FILE"
trap - EXIT
chmod 600 "$FILE"
echo "State key written to $FILE, profile [$PROFILE] (mode 600)."
