#!/usr/bin/env bash
# AdGuard Home on micro-edge, managed from git.
#   ./scripts/micro-edge-adguard.sh push   copy stacks/micro-edge/adguard/AdGuardHome.yaml to the micro and apply it (restarts AdGuard, rolls back on failure)
#   ./scripts/micro-edge-adguard.sh pull   read the live config from the micro into the repo file (password hash replaced), to commit what you changed in the UI
# Needs the laptop on the tailnet with `tailscale set --accept-routes` (ssh to the micro's private address). Override with MICRO_EDGE_SSH / MICRO_EDGE_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${MICRO_EDGE_SSH:?set MICRO_EDGE_SSH, e.g. ubuntu@<micro-edge-private-ip>}
KEY=${MICRO_EDGE_KEY:-$HOME/.ssh/id_rsa}
DIR=stacks/micro-edge/adguard
REMOTE=/opt/stacks/micro-edge/adguard
SSH=(ssh -o ConnectTimeout=10 -i "$KEY"); SCP=(scp -q -o ConnectTimeout=10 -i "$KEY")
case "${1:-}" in
  push)
    grep -q '__PASSWORD_HASH__' "$DIR/AdGuardHome.yaml" || { echo "template has no __PASSWORD_HASH__" >&2; exit 1; }
    "${SCP[@]}" "$DIR/AdGuardHome.yaml" "$DIR/apply.sh" "$HOST:/tmp/"
    "${SSH[@]}" "$HOST" "sudo install -D -m 0644 /tmp/AdGuardHome.yaml $REMOTE/AdGuardHome.yaml && sudo install -m 0755 /tmp/apply.sh $REMOTE/apply.sh && rm -f /tmp/AdGuardHome.yaml /tmp/apply.sh && sudo $REMOTE/apply.sh"
    ;;
  pull)
    "${SSH[@]}" "$HOST" "sudo cat $REMOTE/conf/AdGuardHome.yaml" | sed -E 's/^(    password:).*/\1 __PASSWORD_HASH__/' > "$DIR/AdGuardHome.yaml.new"
    grep -q '__PASSWORD_HASH__' "$DIR/AdGuardHome.yaml.new" || { rm -f "$DIR/AdGuardHome.yaml.new"; echo "no users section read: nothing changed" >&2; exit 1; }
    # keep the explanatory header comment of the repo copy (AdGuard drops comments)
    { sed -n '1,/^[^#]/{/^#/p}' "$DIR/AdGuardHome.yaml"; cat "$DIR/AdGuardHome.yaml.new"; } > "$DIR/AdGuardHome.yaml.tmp"
    mv "$DIR/AdGuardHome.yaml.tmp" "$DIR/AdGuardHome.yaml"; rm -f "$DIR/AdGuardHome.yaml.new"
    echo "pulled into $DIR/AdGuardHome.yaml: review with git diff (the password hash is not stored)"
    ;;
  *) sed -n '2,5p' "$0"; exit 2 ;;
esac
