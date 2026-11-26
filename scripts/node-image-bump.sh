#!/usr/bin/env bash
# Propose the worker-node image for the OKE pool as a FILE CHANGE (a pull request), never as an in-place patch.
#   scripts/node-image-bump.sh [--dry-run]
# Needs: the OCI CLI logged in (scripts/oci-login.sh in CI), jq, and OCI_COMPARTMENT_OCID. Optional: CLUSTER_NAME (default oke-free),
# NODE_IMAGE_FILE (default infra/node-image.auto.tfvars), GITHUB_OUTPUT (the workflow reads result/title/branch from it).
# What it does (read-only calls to Oracle, then one local file):
#   1. finds the ACTIVE cluster and its Kubernetes version, and the image the node pool RUNS now;
#   2. lists the aarch64 OKE images Oracle offers for that Kubernetes version (the same filter as infra/oke.tf: no GPU) and takes the newest;
#   3. result=pin   no pin file yet: writes the image the pool runs NOW (changes nothing in the cluster, only freezes today's state)
#      result=bump  the newest offered image differs from the pin: writes it (the apply then replaces the nodes one at a time: docs/NODE-IMAGE.md)
#      result=none  the pin is the newest image
# The file line is: node_image = "<source name>|<image OCID>"  (variable node_image, infra/variables.tf).
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
CLUSTER="${CLUSTER_NAME:-oke-free}"
FILE="${NODE_IMAGE_FILE:-infra/node-image.auto.tfvars}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
command -v oci >/dev/null || { echo "the OCI CLI (oci) is not installed" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is not installed" >&2; exit 2; }

cluster_json="$(oci ce cluster list --compartment-id "$OCI_COMPARTMENT_OCID" --name "$CLUSTER" --lifecycle-state ACTIVE --all)"
cluster_id="$(jq -r '.data[0].id // empty' <<<"$cluster_json")"
version="$(jq -r '.data[0]."kubernetes-version" // empty' <<<"$cluster_json")"
if [ -z "$cluster_id" ] || [ -z "$version" ]; then echo "no ACTIVE cluster named $CLUSTER in the compartment" >&2; exit 1; fi

pool_json="$(oci ce node-pool list --compartment-id "$OCI_COMPARTMENT_OCID" --cluster-id "$cluster_id" --all)"
live_id="$(jq -r '.data[0]."node-source"."image-id" // .data[0]."node-source-details"."image-id" // empty' <<<"$pool_json")"
if [ -z "$live_id" ]; then echo "the node pool has no image id (is there a pool yet?)" >&2; exit 1; fi

options_json="$(oci ce node-pool-options get --node-pool-option-id all --compartment-id "$OCI_COMPARTMENT_OCID")"
# newest first by name (the name carries the build date, exactly how infra/oke.tf sorts it)
sources="$(jq -c --arg v "OKE-${version#v}-" '[.data.sources[]
    | select(."source-name" | contains("aarch64") and contains($v) and (contains("GPU") | not))
    | {name: ."source-name", id: ."image-id"}] | sort_by(.name) | reverse' <<<"$options_json")"
newest_name="$(jq -r '.[0].name // empty' <<<"$sources")"
newest_id="$(jq -r '.[0].id // empty' <<<"$sources")"
live_name="$(jq -r --arg id "$live_id" '[.[] | select(.id == $id)][0].name // "running-image"' <<<"$sources")"

pinned=""
if [ -f "$FILE" ]; then
  pinned="$(sed -nE 's/^[[:space:]]*node_image[[:space:]]*=[[:space:]]*"([^"]*)".*$/\1/p' "$FILE" | head -n1)"
fi
pinned_id="${pinned##*|}"

result="none"; name=""; id=""
if [ -z "$pinned" ]; then
  result="pin"; name="$live_name"; id="$live_id"
elif [ -n "$newest_id" ] && [ "$newest_id" != "$pinned_id" ]; then
  result="bump"; name="$newest_name"; id="$newest_id"
fi

echo "cluster $CLUSTER ($version), pool runs: $live_name"
echo "newest offered: ${newest_name:-none offered}"
echo "pinned: ${pinned:-nothing}"
echo "result: $result"

if [ "$result" != "none" ] && [ "$DRY" != 1 ]; then
  {
    echo "# Written by scripts/node-image-bump.sh (workflow node-image). Changing this line replaces the worker nodes one at a time on the next apply:"
    echo "# review the plan and read docs/NODE-IMAGE.md first. $(date -u +%Y-%m-%d)"
    echo "node_image = \"$name|$id\""
  } > "$FILE"
  echo "wrote $FILE"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "result=$result"
    echo "image=$name"
    echo "previous=${pinned%%|*}"
    echo "branch=node-image/$(printf '%s' "${name:-none}" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-80)"
    case "$result" in
      pin) echo "title=chore(infra): pin the OKE node image to the one the pool runs now" ;;
      bump) echo "title=chore(infra): OKE node image ${name}" ;;
    esac
  } >> "$GITHUB_OUTPUT"
fi
