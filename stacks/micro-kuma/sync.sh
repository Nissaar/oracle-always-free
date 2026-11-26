#!/bin/sh
# Keeps the `monitors` volume (read by AutoKuma) equal to $MONITOR_DIR of the self-hosted repo,
# plus one generated file: the webhook notification to the alert-details Worker.
# Runs in the Tailscale container's network namespace, so GIT_URL can be a tailnet address.
# The token never appears in a URL or on a command line: git asks the credential helper below,
# which reads it from the environment.
set -u

: "${GIT_URL:?}" "${MONITOR_DIR:?}" "${KUMA_LOCATION:?}"
BRANCH="${GIT_BRANCH:-main}"
PERIOD="${SYNC_PERIOD:-600}"
NOTIFY="${KUMA_NOTIFICATION_NAME:-worker}"
REPO="${SYNC_REPO_DIR:-/repo/checkout}"
OUT="${SYNC_OUT_DIR:-/monitors}"

export GIT_TERMINAL_PROMPT=0
# shellcheck disable=SC2016 # expanded later by git's shell, from the environment
git config --global credential.helper \
  '!f() { test "$1" = get || exit 0; echo "username=${GIT_USERNAME:-git}"; echo "password=${GIT_TOKEN:-}"; }; f'
git config --global safe.directory '*'

log() { echo "sync: $*"; }

write_notification() {
  if [ -z "${KUMA_WORKER_URL:-}" ] || [ -z "${KUMA_TOKEN:-}" ]; then
    log "KUMA_WORKER_URL or KUMA_TOKEN is empty: no webhook notification, monitors alert nobody"
    rm -f "$OUT/$NOTIFY.json"
    return
  fi
  case "$KUMA_WORKER_URL$KUMA_TOKEN$KUMA_LOCATION" in
    *\"*|*\\*|*' '*) log "quote, backslash or space in KUMA_WORKER_URL/KUMA_TOKEN/KUMA_LOCATION: refused"; return ;;
  esac
  url="${KUMA_WORKER_URL%/}/kuma/$KUMA_LOCATION"
  ( umask 022 # readable by AutoKuma whatever its user; the volume itself is root-only on the host
    cat > "$OUT/.$NOTIFY.tmp" <<EOF
{
  "type": "notification",
  "name": "$NOTIFY",
  "active": true,
  "isDefault": true,
  "applyExisting": true,
  "config": {
    "type": "webhook",
    "webhookURL": "$url",
    "webhookContentType": "json",
    "webhookAdditionalHeaders": "{\"Authorization\": \"Bearer $KUMA_TOKEN\"}"
  }
}
EOF
  )
  if cmp -s "$OUT/.$NOTIFY.tmp" "$OUT/$NOTIFY.json"; then
    rm -f "$OUT/.$NOTIFY.tmp"
  else
    mv -f "$OUT/.$NOTIFY.tmp" "$OUT/$NOTIFY.json"
    log "notification $NOTIFY -> $url"
  fi
}

fetch() {
  if [ -d "$REPO/.git" ]; then
    git -C "$REPO" fetch --quiet --depth 1 origin "$BRANCH" &&
      git -C "$REPO" reset --quiet --hard FETCH_HEAD
  else
    rm -rf "$REPO"
    git clone --quiet --depth 1 --branch "$BRANCH" --filter=blob:none --sparse "$GIT_URL" "$REPO" &&
      git -C "$REPO" sparse-checkout set "$MONITOR_DIR"
  fi
}

copy() {
  src="$REPO/$MONITOR_DIR"
  [ -d "$src" ] || { log "$MONITOR_DIR is not in the repo (yet)"; return 1; }
  changed=0
  for f in "$src"/*.json "$src"/*.toml; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = "$NOTIFY.json" ] && continue
    if ! cmp -s "$f" "$OUT/$b"; then
      cp "$f" "$OUT/.$b.tmp" && mv -f "$OUT/.$b.tmp" "$OUT/$b" && changed=$((changed + 1))
    fi
  done
  for f in "$OUT"/*.json "$OUT"/*.toml; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = "$NOTIFY.json" ] && continue
    if [ ! -e "$src/$b" ]; then
      rm -f "$f" && changed=$((changed + 1))
    fi
  done
  [ "$changed" -eq 0 ] || log "$changed file(s) updated from commit $(git -C "$REPO" rev-parse --short HEAD)"
}

write_notification
while :; do
  if fetch; then
    copy || true
  else
    log "git fetch failed (tailnet down or GIT_URL/token wrong); AutoKuma keeps the last copy"
  fi
  sleep "$PERIOD"
done
