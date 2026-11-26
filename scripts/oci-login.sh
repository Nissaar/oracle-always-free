#!/usr/bin/env bash
# GitHub Actions -> Oracle without stored keys.
#
# Swaps the job's GitHub OIDC token for a 60-minute Oracle session token
# (UPST) at the identity domain, writes profile CI to ~/.oci/config, and keeps
# refreshing the token every 20 minutes in the background so long applies
# (an OKE cluster takes ~10 min) never run on an expired token.
#
# Needs: job permission `id-token: write`, and env OCI_OIDC_DOMAIN_URL,
# OCI_OIDC_CLIENT_ID, OCI_OIDC_CLIENT_SECRET, OCI_TENANCY_OCID, OCI_REGION.
# Same request as Oracle's token exchange docs and falcosecurity/test-infra.
set -euo pipefail
umask 077

: "${OCI_OIDC_DOMAIN_URL:?}" "${OCI_OIDC_CLIENT_ID:?}" "${OCI_OIDC_CLIENT_SECRET:?}"
: "${OCI_TENANCY_OCID:?}" "${OCI_REGION:?}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?job needs permissions: id-token: write}" "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?}"

dir="$HOME/.oci"
mkdir -p "$dir"
key="$dir/ci-key.pem"
token="$dir/ci-session-token"

if [ ! -f "$key" ]; then
  openssl genrsa -out "$key" 2048 2>/dev/null
fi
pub_b64=$(openssl rsa -in "$key" -pubout -outform DER 2>/dev/null | openssl base64 -A)
fingerprint=$(printf '%s' "$pub_b64" | openssl base64 -d -A | openssl dgst -md5 -c | awk '{print $NF}')

cat > "$dir/config" <<CFG
[CI]
tenancy=$OCI_TENANCY_OCID
region=$OCI_REGION
fingerprint=$fingerprint
key_file=$key
security_token_file=$token
CFG

# The sub claim of a JWT (not secret), for error messages.
jwt_sub() {
  local p
  p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  while [ $((${#p} % 4)) -ne 0 ]; do p="$p="; done
  base64 -d <<<"$p" 2>/dev/null | jq -r '.sub // "?"' 2>/dev/null || echo "?"
}

exchange() {
  local gh_jwt resp code
  gh_jwt=$(curl -fsS --retry 3 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https%3A%2F%2Fcloud.oracle.com" | jq -er .value)
  resp=$(curl -sS --retry 3 --proto '=https' -w '\n%{http_code}' \
    -u "$OCI_OIDC_CLIENT_ID:$OCI_OIDC_CLIENT_SECRET" \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    --data-urlencode 'requested_token_type=urn:oci:token-type:oci-upst' \
    --data-urlencode 'subject_token_type=jwt' \
    --data-urlencode "subject_token=$gh_jwt" \
    --data-urlencode "public_key=$pub_b64" \
    "$OCI_OIDC_DOMAIN_URL/oauth2/v1/token")
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  if [ "$code" != 200 ]; then
    # Oracle's error and the token's sub are not secret; the sub must match a
    # rule of the identity propagation trust (bootstrap/identity.tf).
    echo "Oracle refused the token exchange (HTTP $code): $(jq -r '[.error, .error_description] | map(select(.)) | join(": ")' <<<"$resp" 2>/dev/null)" >&2
    echo "GitHub token sub: $(jwt_sub "$gh_jwt")" >&2
    return 1
  fi
  # -j: no trailing newline. The Go SDK puts the file as-is into the
  # Authorization header, and a newline there is rejected.
  jq -jer '.token' <<<"$resp" > "$token.next"
  mv "$token.next" "$token"
}

exchange
echo "Oracle session token ready (profile CI)."

if [ "${1:-}" != "--no-refresh" ]; then
  # Detached so it outlives this step; GitHub kills it when the job ends.
  export -f exchange jwt_sub
  export pub_b64 token
  nohup setsid bash -c 'while sleep 1200; do exchange || echo "token refresh failed" >&2; done' \
    >/dev/null 2>&1 &
fi
