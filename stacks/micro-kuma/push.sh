#!/bin/sh
# Heartbeat for the Home Kuma: calls KUMA_PUSH_URL (its push monitor for this location) every
# PUSH_PERIOD seconds over the tailnet, but only while the local Kuma answers. If this VM, its Kuma or
# the tailnet is down, the Home push monitor goes DOWN.
# The URL holds a token: it is handed to curl on stdin, never on the command line or in the log.
set -u
PERIOD="${PUSH_PERIOD:-60}"
LOCAL="${KUMA_LOCAL_URL:-http://10.253.0.10:3001}"

if [ -z "${KUMA_PUSH_URL:-}" ]; then
  echo "push: KUMA_PUSH_URL is empty, no heartbeat (set it in .env, then ./up.sh)"
  while :; do sleep 3600; done
fi

while :; do
  if curl -fsS -m 5 -o /dev/null "$LOCAL/api/entry-page"; then
    printf 'url = "%s"\n' "$KUMA_PUSH_URL" | curl -fsS -m 20 -o /dev/null -K - ||
      echo "push: the Home Kuma did not answer"
  else
    echo "push: local Kuma does not answer, heartbeat skipped"
  fi
  sleep "$PERIOD"
done
