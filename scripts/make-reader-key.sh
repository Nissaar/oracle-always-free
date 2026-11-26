#!/usr/bin/env bash
# Gives the cluster its key to OCI Vault, without the private key ever being
# in OpenTofu state or on disk in plain text:
#
#   ./scripts/make-reader-key.sh [path-to-cluster-repo]      (default ~/k8s-free-gitops)
#
# 1. makes an RSA 2048 API signing key pair in a private temp folder,
# 2. uploads the PUBLIC half to the IAM user cluster-secrets-reader
#    (bootstrap/secrets-reader.tf; read-only on vault freetier),
# 3. seals privateKey + fingerprint into the k8s-free-gitops repo's one SOPS secret
#    infrastructure/controllers/external-secrets/oci-vault-reader.sops.yaml
#    (k8s-free-gitops repo scripts/seal.sh; needs the age recipient in its .sops.yaml),
# 4. writes OCI_REGION, OCI_NAMESPACE, OCI_TENANCY_OCID, OCI_VAULT_OCID and OCI_VAULT_READER_OCID into
#    the k8s-free-gitops repo's clusters/oke/cluster-settings.yaml,
# 5. deletes the temp folder (shred).
#
# Run it again to rotate the key (a user can hold 3 API keys; it lists the
# old ones with the command to delete them). Commit in the k8s-free-gitops repo
# afterwards (docs/WHAT-YOU-DO.md step 15).
set -euo pipefail

die() { echo "make-reader-key.sh: $*" >&2; exit 1; }
CLUSTER=${1:-$HOME/k8s-free-gitops}
PROFILE=${OCI_PROFILE:-oracle-always-free-admin}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SEAL=$CLUSTER/scripts/seal.sh
EXAMPLE=$CLUSTER/infrastructure/controllers/external-secrets/oci-vault-reader.example.yaml
SETTINGS=$CLUSTER/clusters/oke/cluster-settings.yaml

for c in oci openssl kubectl sops tofu; do
  command -v "$c" > /dev/null || die "$c is not installed"
done
if [ ! -x "$SEAL" ] || [ ! -f "$EXAMPLE" ] || [ ! -f "$SETTINGS" ]; then
  die "$CLUSTER does not look like the k8s-free-gitops repo"
fi

# The state is read with the laptop profile oracle-tfstate; AWS_* keys exported
# for another repo (cloudflare-free R2) must not override it.
out() { env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE tofu -chdir="$ROOT/bootstrap" output -raw "$1"; }
READER=$(out cluster_secrets_reader_ocid) || die "bootstrap output cluster_secrets_reader_ocid missing: run tofu -chdir=bootstrap apply first"
TENANCY=$(out OCI_TENANCY_OCID)
VAULT=$(out OCI_VAULT_OCID)
REGION=$(out OCI_REGION)
NAMESPACE=$(out OCI_NAMESPACE)
oci_() { oci --auth security_token --profile "$PROFILE" "$@"; }

old=$(oci_ iam user api-key list --user-id "$READER" --query 'data[].fingerprint' --raw-output 2>/dev/null) \
  || die "cannot list the API keys of cluster-secrets-reader (Oracle session expired? oci session refresh --profile $PROFILE)"
[ -n "$old" ] && printf '%s' "$old" | jq -e 'type == "array"' > /dev/null 2>&1 || old='[]'
count=$(printf '%s' "$old" | jq 'length')
[ "$count" -lt 3 ] || die "cluster-secrets-reader already has 3 API keys; delete one first:
  oci --auth security_token --profile $PROFILE iam user api-key delete --user-id $READER --fingerprint <fingerprint> --force"

umask 077
tmp=$(mktemp -d)
cleanup() { find "$tmp" -type f -exec shred -u {} + 2> /dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" 2> /dev/null
openssl pkey -in "$tmp/key.pem" -pubout -out "$tmp/public.pem"
FP=$(openssl pkey -in "$tmp/key.pem" -pubout -outform DER | openssl md5 -c | awk '{print $NF}')

if oci_ iam user api-key upload --user-id "$READER" --key-file "$tmp/public.pem" > /dev/null; then
  echo "uploaded public key $FP to cluster-secrets-reader"
else
  # Fallback by hand (the public key is not secret).
  echo
  echo "The CLI upload failed (error above). Add the key in the console instead:"
  echo "  Identity & Security -> Domains -> Default -> Users -> cluster-secrets-reader"
  echo "  -> API keys -> Add API key -> Paste a public key -> paste the block below -> Add."
  echo "  The console must show fingerprint $FP."
  echo
  cat "$tmp/public.pem"
  echo
  read -r -p "Press Enter once the console shows the key (Ctrl-C to stop) " _
fi

kubectl create secret generic oci-vault-reader --namespace external-secrets \
  --from-file=privateKey="$tmp/key.pem" --from-literal=fingerprint="$FP" \
  --dry-run=client -o yaml > "$tmp/oci-vault-reader.yaml"
"$SEAL" "$tmp/oci-vault-reader.yaml" "$EXAMPLE" | grep -v '^now delete the plaintext'

sed -i -E \
  -e "s|^(  OCI_REGION: ).*|\1$REGION|" \
  -e "s|^(  OCI_NAMESPACE: ).*|\1$NAMESPACE|" \
  -e "s|^(  OCI_TENANCY_OCID: ).*|\1$TENANCY|" \
  -e "s|^(  OCI_VAULT_OCID: ).*|\1$VAULT|" \
  -e "s|^(  OCI_VAULT_READER_OCID: ).*|\1$READER|" \
  "$SETTINGS"
echo "filled OCI_REGION, OCI_NAMESPACE, OCI_TENANCY_OCID, OCI_VAULT_OCID, OCI_VAULT_READER_OCID in ${SETTINGS#"$CLUSTER"/}"

if [ "$count" -gt 0 ]; then
  echo
  echo "Older keys of cluster-secrets-reader (delete them once the cluster works with the new one):"
  printf '%s' "$old" | jq -r '.[]' | while read -r f; do
    echo "  oci --auth security_token --profile $PROFILE iam user api-key delete --user-id $READER --fingerprint $f --force"
  done
fi
echo
echo "Next, in $CLUSTER: git status --short, then add BY NAME:"
echo "  git add clusters/oke/cluster-settings.yaml infrastructure/controllers/external-secrets/oci-vault-reader.sops.yaml infrastructure/controllers/external-secrets/kustomization.yaml"
