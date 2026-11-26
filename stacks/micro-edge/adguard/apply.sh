#!/usr/bin/env bash
# Runs ON micro-edge (as root, from scripts/micro-edge-adguard.sh push): installs adguard/AdGuardHome.yaml as AdGuard's live config.
#   - keeps the admin password hash that is already in the live file (the template holds __PASSWORD_HASH__)
#   - refuses more than MAX_LISTS enabled blocklists (AdGuard is capped at 256 MB; nine lists killed it on 12 Nov)
#   - restarts only AdGuard, checks it stays up (no OOM kill) and really blocks, and puts the old config back if not
set -euo pipefail
STACK=${STACK:-/opt/stacks/micro-edge}
SRC=${1:-$STACK/adguard/AdGuardHome.yaml}
LIVE=$STACK/adguard/conf/AdGuardHome.yaml
MAX_LISTS=${MAX_LISTS:-3}
WAIT=${WAIT:-150}
die() { echo "apply: $*" >&2; exit 1; }
cd "$STACK"
[ -f "$SRC" ] || die "$SRC not found"
[ -f "$LIVE" ] || die "$LIVE not found: finish AdGuard's setup wizard first"
grep -q '__PASSWORD_HASH__' "$SRC" || die "the template must contain __PASSWORD_HASH__ in the users section"
n=$(awk '/^filters:/{f=1;next} f&&/^[a-z_]+:/{f=0} f&&/^  - enabled: true/{c++} END{print c+0}' "$SRC")
[ "$n" -le "$MAX_LISTS" ] || die "$n blocklists enabled, the limit is $MAX_LISTS (memory); disable some in the file or raise MAX_LISTS knowingly"
HASH=$(awk '/^users:/{u=1;next} u&&/^[a-z_]+:/{u=0} u&&/^    password:/{sub(/^    password: */,"");print;exit}' "$LIVE")
[ -n "$HASH" ] && [ "$HASH" != "__PASSWORD_HASH__" ] || die "no password hash found in the live config"
NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT
HASH="$HASH" SRC="$SRC" python3 -c 'import os,sys; sys.stdout.write(open(os.environ["SRC"]).read().replace("__PASSWORD_HASH__", os.environ["HASH"]))' > "$NEW"
BAK="$LIVE.bak.$(date +%s)"
cp -p "$LIVE" "$BAK"
ls -1t "$LIVE".bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f      # keep the last 5 backups
rollback() {
  echo "apply: FAILED ($1): putting the previous config back" >&2
  docker compose stop adguard >/dev/null 2>&1 || true
  cp -p "$BAK" "$LIVE"; docker compose up -d adguard >/dev/null
  exit 1
}
echo "apply: $n blocklist(s) enabled; restarting AdGuard (DNS on this micro is down for a few seconds)"
docker compose stop adguard >/dev/null
install -m "$(stat -c %a "$BAK")" "$NEW" "$LIVE"
docker compose up -d adguard >/dev/null
t=0; ok=0
while [ "$t" -lt "$WAIT" ]; do
  sleep 5; t=$((t+5))
  [ "$(docker inspect -f '{{.State.Running}}' edge_adguard 2>/dev/null)" = true ] || continue
  [ "$(docker inspect -f '{{.State.OOMKilled}}' edge_adguard)" = false ] || rollback "out of memory"
  out=$(docker compose exec -T tailscale nslookup doubleclick.net 127.0.0.1 2>/dev/null || true)
  if [ "$n" -eq 0 ]; then echo "$out" | grep -q 'Address' && { ok=1; break; }
  else echo "$out" | grep -q '0\.0\.0\.0' && { ok=1; break; }; fi
done
[ "$ok" -eq 1 ] || rollback "not answering or not blocking after ${WAIT}s"
[ "$(docker inspect -f '{{.State.OOMKilled}}' edge_adguard)" = false ] || rollback "out of memory"
echo "apply: OK, doubleclick.net is blocked. Memory:"
docker stats --no-stream --format '  {{.Name}} {{.MemUsage}} ({{.MemPerc}})' edge_adguard
echo "apply: previous config kept as $BAK"
