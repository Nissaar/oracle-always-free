#!/bin/sh
# Start or update the Kuma stack: pulls the newest images (floating tags), Tailscale first,
# because on the GCP VM the AutoKuma image comes over the tailnet (profile ghcr-mirror in .env).
# Safe to run again any time. Run it with sudo from this folder or anywhere.
set -eu
cd "$(dirname "$0")"

[ -f .env ] || { echo "no .env here: cp .env.example .env, fill it in (docs/WHAT-YOU-DO.md), then run me again" >&2; exit 1; }
chmod 600 .env
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi

$DC config -q
$DC pull tailscale
$DC up -d tailscale

i=0
until docker exec kuma_tailscale tailscale status >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "Tailscale is not logged in. Open the link from: $DC logs tailscale | grep login.tailscale.com" >&2
    echo "then run ./up.sh again." >&2
    exit 1
  fi
  sleep 2
done

if grep -Eq '^COMPOSE_PROFILES=.*ghcr-mirror' .env; then
  $DC pull ghcr-forward
  $DC up -d ghcr-forward
  sleep 2
fi

$DC pull
$DC up -d --remove-orphans
$DC ps
