#!/usr/bin/env bash
# Apply the patching setup to THIS machine (Debian / Ubuntu). Safe to run again any time: every file is rewritten only when it changed.
#   sudo ./apply-patching.sh --host free-vm --day wed [--mode alert|staggered|none] [--time 00:00] [--kuma yes|no]
#                            [--containers "kuma_tailscale kuma_app"] [--ts-container kuma_tailscale] [--push-container kuma_push]
#                            [--installer unattended|osconfig] [--no-approvals] [--dry-run]
# Identical copy in <home-server-repo>/ops/patch, gcp-always-free/patch and oracle-always-free/patch (change all three).
# Needs patch-agent (the file next to this one). The startup script (Google VM), cloud-init (Oracle micros) and you (Home, and machines that
# already exist) all run THIS script, so the settings cannot drift.
#
# What it sets up
#   unattended-upgrades   security updates every day, Automatic-Reboot "false" (reasons: README of this folder)
#                         --installer osconfig: Google VM Manager installs the updates instead (Patch deployment in gcp-always-free/infra, free
#                         for 100 VMs); unattended-upgrades then stays off and this agent only reports, reminds and reboots
#   patch-report.timer    daily 12:00 UTC: status to the feed, heartbeat to Kuma, reminders, failure alerts
#   patch-approve.timer   every 10 min: is there a reboot approval for this machine on the feed (ChatOps `reboot <machine> <code>`)
#   patch-reboot.timer    only with --mode staggered: reboot when needed, on --day at --time (UTC; 00:00 UTC = 04:00 local time)
#   patch-postboot.service  after EVERY boot: Docker, Tailscale, the containers and the push heartbeat are back? ntfy alert if not
# Secrets are never written here: /etc/patch-agent.env gets empty placeholders (PATCH_NTFY_URL, PATCH_ALERT_URL, PATCH_HEARTBEAT_URL), you fill them in.
# Tests: PATCH_ROOT=<dir> puts every path under <dir>; PATCH_NO_SYSTEMD=1 skips apt and systemctl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PATCH_ROOT:-}"
HOST="$(hostname)"; DAY="mon"; MODE="alert"; TIME="00:00"; KUMA="no"; CONTAINERS=""; TSC=""; PUSHC=""; APPROVALS="yes"; DRY=0; INSTALLER="unattended"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host needs a name}"; shift 2 ;;
    --day) DAY="${2:?--day needs mon..sun}"; shift 2 ;;
    --mode) MODE="${2:?--mode needs alert|staggered|none}"; shift 2 ;;
    --time) TIME="${2:?--time needs HH:MM (UTC)}"; shift 2 ;;
    --kuma) KUMA="${2:?--kuma needs yes|no}"; shift 2 ;;
    --containers) CONTAINERS="${2:-}"; shift 2 ;;
    --ts-container) TSC="${2:-}"; shift 2 ;;
    --push-container) PUSHC="${2:-}"; shift 2 ;;
    --installer) INSTALLER="${2:?--installer needs unattended|osconfig}"; shift 2 ;;
    --no-approvals) APPROVALS="no"; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

DAY="$(printf '%s' "$DAY" | tr '[:upper:]' '[:lower:]' | cut -c1-3)"
case "$DAY" in mon|tue|wed|thu|fri|sat|sun) ;; *) echo "--day must be mon..sun" >&2; exit 2 ;; esac
case "$MODE" in alert|staggered|none) ;; *) echo "--mode must be alert, staggered or none" >&2; exit 2 ;; esac
case "$INSTALLER" in unattended|osconfig) ;; *) echo "--installer must be unattended or osconfig" >&2; exit 2 ;; esac
case "$KUMA" in yes|no) ;; *) echo "--kuma must be yes or no" >&2; exit 2 ;; esac
[[ "$TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "--time must be HH:MM" >&2; exit 2; }
[[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--host may only hold letters, digits, . _ -" >&2; exit 2; }
for v in "$CONTAINERS" "$TSC" "$PUSHC"; do [[ "$v" =~ ^[A-Za-z0-9._\ -]*$ ]] || { echo "container names may only hold letters, digits, . _ - and spaces" >&2; exit 2; }; done
[ -f "$HERE/patch-agent" ] || { echo "patch-agent must be in the same folder as this script" >&2; exit 1; }
if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi

CHANGED=0
# put <mode> <target> <source file>: writes only when the content differs
put() {
  local mode="$1" target="$ROOT$2" src="$3"
  if [ -f "$target" ] && cmp -s "$src" "$target"; then return 0; fi
  CHANGED=1
  if [ "$DRY" = 1 ]; then echo "would write $2"; return 0; fi
  mkdir -p "$(dirname "$target")"
  install -m "$mode" "$src" "$target"
  echo "wrote $2"
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
write() { # write <mode> <target> <<content
  local mode="$1" target="$2"; cat > "$TMP/f"; put "$mode" "$target" "$TMP/f"
}
remove() {
  if [ -f "$ROOT$1" ]; then CHANGED=1; [ "$DRY" = 1 ] && { echo "would remove $1"; return 0; }; rm -f "$ROOT$1"; echo "removed $1"; fi
}
sysctl_() { [ -n "${PATCH_NO_SYSTEMD:-}" ] || [ "$DRY" = 1 ] || systemctl "$@"; }

# 1. unattended-upgrades itself (Debian and Ubuntu both ship it; the GCP startup script and the micros' cloud-init install it too)
if [ -z "${PATCH_NO_SYSTEMD:-}" ] && [ "$DRY" != 1 ] && ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
  apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -yq unattended-upgrades
fi

# 2. the agent and its settings (no secrets)
put 0755 /usr/local/sbin/patch-agent "$HERE/patch-agent"
write 0644 /etc/patch-agent.conf <<EOF
# Written by apply-patching.sh: safe to overwrite, holds no secrets (those go in /etc/patch-agent.env).
PATCH_HOST=$HOST
PATCH_REBOOT_MODE=$MODE
PATCH_REBOOT_DAY=$DAY
PATCH_REBOOT_TIME=$TIME
PATCH_KUMA=$KUMA
PATCH_CONTAINERS="$CONTAINERS"
PATCH_TS_CONTAINER=$TSC
PATCH_PUSH_CONTAINER=$PUSHC
PATCH_POLL_APPROVALS=$APPROVALS
PATCH_INSTALLER=$INSTALLER
EOF
if [ ! -f "$ROOT/etc/patch-agent.env" ] && [ "$DRY" != 1 ]; then
  ( umask 077; mkdir -p "$ROOT/etc"; cat > "$ROOT/etc/patch-agent.env" <<'EOF'
# Secrets of the patch agent. Mode 600, root only. Never commit this file.
# PATCH_NTFY_URL: the status feed, a private-looking topic on ntfy.sh, e.g. https://ntfy.sh/<long random name>
# PATCH_ALERT_URL: where alerts go (the topic your phone subscribes to); empty = the same topic as the feed
# PATCH_HEARTBEAT_URL: this machine's push URL on the Home Kuma (monitor "Patch <machine>"), public form https://<kuma host>/api/push/<token>
PATCH_NTFY_URL=
PATCH_ALERT_URL=
PATCH_HEARTBEAT_URL=
EOF
  ); echo "created /etc/patch-agent.env (empty: fill in the three names)"
fi

# 3. unattended-upgrades: security updates daily, NEVER an automatic reboot from apt itself (the reboot is the agent's job: it can pick a weekday)
#    With --installer osconfig the package lists are still refreshed daily (the pending count needs them) but nothing is installed by apt's own timer.
UU=1; [ "$INSTALLER" = osconfig ] && UU=0
write 0644 /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "$UU";
EOF
write 0644 /etc/apt/apt.conf.d/52patching <<'EOF'
// Managed by patch-agent (apply-patching.sh). The allowed origins stay the distribution's own (security only).
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF

# 4. systemd units
write 0644 /etc/systemd/system/patch-report.service <<'EOF'
[Unit]
Description=Patch status to the feed and the Kuma heartbeat
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/patch-agent report
EOF
write 0644 /etc/systemd/system/patch-report.timer <<'EOF'
[Unit]
Description=Daily patch status

[Timer]
OnCalendar=*-*-* 12:00:00 UTC
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF
write 0644 /etc/systemd/system/patch-postboot.service <<'EOF'
[Unit]
Description=After a boot: are Docker, Tailscale, the containers and the heartbeat back?
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/patch-agent postboot
TimeoutStartSec=1500

[Install]
WantedBy=multi-user.target
EOF
if [ "$APPROVALS" = "yes" ]; then
  write 0644 /etc/systemd/system/patch-approve.service <<'EOF'
[Unit]
Description=Look for a reboot approval from ChatOps
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/patch-agent approve-poll
EOF
  write 0644 /etc/systemd/system/patch-approve.timer <<'EOF'
[Unit]
Description=Reboot approval check every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
else
  sysctl_ disable --now patch-approve.timer 2>/dev/null || true
  remove /etc/systemd/system/patch-approve.timer; remove /etc/systemd/system/patch-approve.service
fi
if [ "$MODE" = "staggered" ]; then
  DAYCAP="$(printf '%s' "$DAY" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$DAY" | cut -c2-)"
  write 0644 /etc/systemd/system/patch-reboot.service <<'EOF'
[Unit]
Description=Reboot when a package update needs it (only on this machine's night)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/patch-agent reboot-if-needed
EOF
  write 0644 /etc/systemd/system/patch-reboot.timer <<EOF
[Unit]
Description=Weekly reboot night of this machine

[Timer]
OnCalendar=$DAYCAP *-*-* $TIME:00 UTC
Persistent=false

[Install]
WantedBy=timers.target
EOF
else
  sysctl_ disable --now patch-reboot.timer 2>/dev/null || true
  remove /etc/systemd/system/patch-reboot.timer; remove /etc/systemd/system/patch-reboot.service
fi

# 5. switch it on (only when something changed, so a second run does nothing)
if [ "$CHANGED" = 1 ] && [ "$DRY" != 1 ]; then
  sysctl_ daemon-reload
  sysctl_ enable --now patch-report.timer
  sysctl_ enable patch-postboot.service
  [ "$APPROVALS" = "yes" ] && sysctl_ enable --now patch-approve.timer
  [ "$MODE" = "staggered" ] && sysctl_ enable --now patch-reboot.timer
  sysctl_ enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true      # what actually drives unattended-upgrades (on by default; made sure here)
fi

echo "patching on $HOST: installer $INSTALLER, mode $MODE$([ "$MODE" = staggered ] && echo ", reboot night $DAY $TIME UTC"), $([ "$CHANGED" = 1 ] && echo 'changes applied' || echo 'already up to date')"
if [ -z "$ROOT" ] && grep -q '^PATCH_NTFY_URL=$' /etc/patch-agent.env 2>/dev/null; then
  echo "NEXT: put the three secret values in /etc/patch-agent.env (names in the file), then: sudo patch-agent report"
fi
