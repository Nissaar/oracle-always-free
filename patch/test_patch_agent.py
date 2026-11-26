"""Offline tests of patch-agent and apply-patching.sh: fake apt-get / docker / systemctl / tailscale binaries on PATH, a local HTTP server standing in
for ntfy and the Kuma push URL, every path under a temp PATCH_ROOT. Nothing here touches the network or the real machine.

Run: python3 -m unittest test_patch_agent        (from this folder)
Identical copy in <home-server-repo>/ops/patch, gcp-always-free/patch and oracle-always-free/patch.
"""
import datetime
import glob
import http.server
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.join(HERE, 'patch-agent')
APPLY = os.path.join(HERE, 'apply-patching.sh')

FAKES = {
    'apt-get': '#!/bin/sh\ncat "$FAKE_DIR/apt-out" 2>/dev/null\nexit 0\n',
    'systemctl': '#!/bin/sh\necho "systemctl $*" >> "$FAKE_DIR/calls"\ncase "$1" in is-active) [ -f "$FAKE_DIR/docker-down" ] && exit 3; echo active; exit 0;; esac\nexit 0\n',
    'which': '#!/bin/sh\nexit 1\n',
    'docker': '''#!/bin/sh
echo "docker $*" >> "$FAKE_DIR/calls"
case "$1" in
  ps) cat "$FAKE_DIR/docker-ps" 2>/dev/null ;;
  inspect)
    if [ "$2" = "-f" ] && echo "$3" | grep -q 'RestartPolicy'; then cat "$FAKE_DIR/docker-policy" 2>/dev/null; exit 0; fi
    name="$4"; line=$(grep "^$name " "$FAKE_DIR/docker-state" 2>/dev/null | head -1)
    [ -z "$line" ] && exit 1
    echo "${line#* }" ;;
  exec) [ -f "$FAKE_DIR/ts-down" ] && exit 1; echo "100.1.2.3 host"; exit 0 ;;
  logs) cat "$FAKE_DIR/docker-logs" 2>/dev/null ;;
esac
exit 0
''',
}


class Feed(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        self.server.log.append(('POST', self.path, dict(self.headers), self.rfile.read(n).decode()))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')

    def do_GET(self):
        self.server.log.append(('GET', self.path, dict(self.headers), ''))
        body = ''
        if '/json' in self.path: body = '\n'.join(self.server.poll_lines)
        self.send_response(200); self.end_headers(); self.wfile.write(body.encode())


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, 'root'); os.makedirs(self.root)
        self.fake = os.path.join(self.tmp, 'fake'); os.makedirs(self.fake)
        for name, body in FAKES.items():
            p = os.path.join(self.fake, name)
            with open(p, 'w') as f: f.write(body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        self.srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Feed)
        self.srv.log, self.srv.poll_lines = [], []
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.srv.server_address[1]}'
        for d in ('etc', 'var/run', 'var/lib/apt/periodic', 'var/log/unattended-upgrades', 'proc'):
            os.makedirs(os.path.join(self.root, d), exist_ok=True)
        self.write('/proc/uptime', '7200.5 100.0\n')
        self.conf()

    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close(); shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, path, text):
        os.makedirs(os.path.dirname(self.root + path), exist_ok=True)
        with open(self.root + path, 'w') as f: f.write(text)

    def fk(self, name, text):
        with open(os.path.join(self.fake, name), 'w') as f: f.write(text)

    def conf(self, **kw):
        c = {'PATCH_HOST': 'free-vm', 'PATCH_REBOOT_MODE': 'alert', 'PATCH_REBOOT_DAY': 'mon', 'PATCH_KUMA': 'yes', 'PATCH_CONTAINERS': '"kuma_app kuma_tailscale"',
             'PATCH_TS_CONTAINER': 'kuma_tailscale', 'PATCH_PUSH_CONTAINER': 'kuma_push'}
        c.update(kw)
        self.write('/etc/patch-agent.conf', ''.join(f'{k}={v}\n' for k, v in c.items()))
        self.write('/etc/patch-agent.env', f'PATCH_NTFY_URL={self.url}/status-topic\nPATCH_ALERT_URL={self.url}/alert-topic\nPATCH_HEARTBEAT_URL={self.url}/api/push/tok\n')

    def run_agent(self, *args, **env):
        e = {**os.environ, 'PATH': self.fake + os.pathsep + os.environ['PATH'], 'PATCH_ROOT': self.root, 'FAKE_DIR': self.fake, **env}
        return subprocess.run([sys.executable, '-I', AGENT, *args], capture_output=True, text=True, env=e, timeout=60)

    def calls(self):
        try:
            with open(os.path.join(self.fake, 'calls')) as f: return f.read()
        except OSError:
            return ''

    def posts(self, topic=None):
        return [(p, h, b) for m, p, h, b in self.srv.log if m == 'POST' and (topic is None or p == '/' + topic)]


APT = ('Inst libc6 [2.41-1] (2.41-2 Debian-Security:13/stable-security [amd64])\nInst vim [9.1-1] (9.1-2 Debian:13/stable [amd64])\n'
       'Inst openssl [3.5.0-1] (3.5.1-1 Debian-Security:13/stable-security [amd64])\nConf libc6 (2.41-2 Debian-Security:13/stable-security [amd64])\n')


class TestStatusAndReport(Base):
    def test_status_counts_reboot_and_last_run(self):
        self.fk('apt-out', APT)
        self.write('/var/run/reboot-required', '*** System restart required ***\n')
        self.write('/var/run/reboot-required.pkgs', 'linux-image-6.12\nlibc6\n')
        self.write('/var/lib/apt/periodic/unattended-upgrades-stamp', '')
        self.write('/var/log/unattended-upgrades/unattended-upgrades.log', '2026-11-19 03:00:01 INFO Starting\n2026-11-19 03:00:30 INFO All upgrades installed\n')
        r = self.run_agent('status', '--json')
        self.assertEqual(r.returncode, 0, r.stderr)
        s = json.loads(r.stdout)
        self.assertEqual((s['pending'], s['security'], s['reboot'], s['last_result']), (3, 2, True, 'ok'))
        self.assertEqual(s['reboot_pkgs'], ['linux-image-6.12', 'libc6'])
        self.assertEqual(s['host'], 'free-vm'); self.assertEqual(s['uptime_h'], 2.0); self.assertTrue(s['last_run'].endswith('Z'))

    def test_vm_manager_installer_reads_the_last_run_from_apt_history(self):
        self.conf(PATCH_INSTALLER='osconfig')
        self.write('/var/log/apt/history.log', 'Start-Date: 2026-11-10  22:00:01\nCommandline: apt-get upgrade\nUpgrade: vim:amd64 (1, 2)\nEnd-Date: 2026-11-10  22:00:40\n\n'
                   'Start-Date: 2026-11-17  22:00:05\nCommandline: apt-get upgrade\nUpgrade: libc6:amd64 (1, 2)\nEnd-Date: 2026-11-17  22:01:10\n\n'
                   'Start-Date: 2026-11-18  09:00:00\nCommandline: apt-get -s upgrade\nEnd-Date: 2026-11-18  09:00:01\n')
        s = json.loads(self.run_agent('status', '--json').stdout)
        self.assertEqual(s['last_result'], 'ok'); self.assertTrue(s['last_run'].startswith('2026-11-17'), s['last_run'])
        self.write('/var/log/apt/history.log', 'Start-Date: 2026-11-19  22:00:05\nCommandline: apt-get upgrade\nUpgrade: libc6:amd64 (1, 2)\nError: Sub-process /usr/bin/dpkg returned an error code (1)\nEnd-Date: 2026-11-19  22:01:10\n')
        self.assertEqual(json.loads(self.run_agent('status', '--json').stdout)['last_result'], 'failed')
        os.remove(self.root + '/var/log/apt/history.log')
        self.assertEqual(json.loads(self.run_agent('status', '--json').stdout)['last_result'], 'unknown')

    def test_failed_run_detected_from_the_log(self):
        self.write('/var/log/unattended-upgrades/unattended-upgrades.log', '2026-11-19 03:00:01 INFO Starting\n2026-11-19 03:00:30 ERROR Installing the upgrades failed!\n')
        self.assertEqual(json.loads(self.run_agent('status', '--json').stdout)['last_result'], 'failed')

    def test_report_publishes_the_feed_and_the_heartbeat(self):
        self.fk('apt-out', APT)
        self.write('/var/lib/apt/periodic/unattended-upgrades-stamp', '')
        self.write('/var/log/unattended-upgrades/unattended-upgrades.log', 'x INFO All upgrades installed\n')
        r = self.run_agent('report'); self.assertEqual(r.returncode, 0, r.stderr)
        feed = self.posts('status-topic'); self.assertEqual(len(feed), 1)
        doc = json.loads(feed[0][2]); self.assertEqual((doc['host'], doc['pending'], doc['event']), ('free-vm', 3, 'status'))
        self.assertEqual(feed[0][1]['Title'], 'patchstatus free-vm'); self.assertEqual(feed[0][1]['Priority'], '1')
        hb = [p for m, p, h, b in self.srv.log if m == 'GET' and p.startswith('/api/push/tok')]
        self.assertTrue(hb and 'status=up' in hb[0], hb)
        self.assertEqual(self.posts('alert-topic'), [], 'a healthy report must not alert')

    def test_failed_run_alerts_once_a_day_and_the_heartbeat_goes_down(self):
        self.write('/var/log/unattended-upgrades/unattended-upgrades.log', 'x ERROR Installing the upgrades failed!\n')
        self.run_agent('report'); self.run_agent('report')
        al = self.posts('alert-topic'); self.assertEqual(len(al), 1, 'one alert per day')
        self.assertIn('free-vm', al[0][1]['Title']); self.assertIn('failed', al[0][2])
        self.assertTrue(any('status=down' in p for m, p, h, b in self.srv.log if m == 'GET'))

    def test_alert_mode_reminds_about_a_waiting_reboot_every_three_days(self):
        self.write('/var/run/reboot-required', 'x\n')
        self.run_agent('report'); self.run_agent('report')
        al = self.posts('alert-topic'); self.assertEqual(len(al), 1)
        self.assertIn('reboot free-vm', al[0][2]); self.assertIn('ChatOps', al[0][2])
        stamp = self.root + '/var/lib/patch-agent/reminded-reboot'
        old = time.time() - 2 * 86400; os.utime(stamp, (old, old))
        self.run_agent('report'); self.assertEqual(len(self.posts('alert-topic')), 1, 'two days later: still quiet')
        old = time.time() - (3 * 86400 - 600); os.utime(stamp, (old, old))
        self.run_agent('report'); self.assertEqual(len(self.posts('alert-topic')), 2, 'three days later (the daily run may be 10 minutes early): reminds again')
        self.run_agent('report'); self.assertEqual(len(self.posts('alert-topic')), 2, 'and not twice')

    def test_a_reboot_clears_the_reminder_so_the_next_one_alerts_at_once(self):
        self.write('/var/run/reboot-required', 'x\n')
        self.run_agent('report'); self.assertEqual(len(self.posts('alert-topic')), 1)
        os.remove(self.root + '/var/run/reboot-required')
        self.run_agent('report')
        self.write('/var/run/reboot-required', 'x\n')
        self.run_agent('report'); self.assertEqual(len(self.posts('alert-topic')), 2)

    def test_staggered_mode_does_not_remind(self):
        self.conf(PATCH_REBOOT_MODE='staggered'); self.write('/var/run/reboot-required', 'x\n')
        self.run_agent('report'); self.assertEqual(self.posts('alert-topic'), [])

    def test_no_urls_means_no_crash(self):
        self.write('/etc/patch-agent.env', '')
        r = self.run_agent('report'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.srv.log, [])

    def test_no_restart_policy_listed(self):
        self.fk('docker-ps', 'kuma_app\nkuma_push\n'); self.fk('docker-policy', '/kuma_app unless-stopped\n/kuma_push no\n')
        s = json.loads(self.run_agent('status', '--json').stdout); self.assertEqual(s['no_restart'], ['kuma_push'])
        self.assertEqual(self.run_agent('check-restart').returncode, 1)
        self.conf(PATCH_RESTART_EXEMPT='kuma_push'); self.assertEqual(self.run_agent('check-restart').returncode, 0)


class TestReboot(Base):
    def today(self): return ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'][datetime.datetime.now(datetime.timezone.utc).weekday()]
    def other_day(self): return 'mon' if self.today() != 'mon' else 'tue'

    def test_alert_mode_never_reboots_by_itself(self):
        self.write('/var/run/reboot-required', 'x\n')
        self.run_agent('reboot-if-needed'); self.assertNotIn('reboot', self.calls())

    def test_staggered_reboots_only_on_its_night_and_only_when_needed(self):
        self.conf(PATCH_REBOOT_MODE='staggered', PATCH_REBOOT_DAY=self.other_day()); self.write('/var/run/reboot-required', 'x\n')
        self.run_agent('reboot-if-needed'); self.assertNotIn('systemctl reboot', self.calls(), 'wrong night')
        self.conf(PATCH_REBOOT_MODE='staggered', PATCH_REBOOT_DAY=self.today()); os.remove(self.root + '/var/run/reboot-required')
        self.run_agent('reboot-if-needed'); self.assertNotIn('systemctl reboot', self.calls(), 'nothing needs a reboot')
        self.write('/var/run/reboot-required', 'x\n')
        r = self.run_agent('reboot-if-needed'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('systemctl reboot', self.calls())
        ev = [json.loads(b) for p, h, b in self.posts('status-topic')]; self.assertEqual(ev[-1]['event'], 'rebooting')
        self.assertTrue(os.path.exists(self.root + '/var/lib/patch-agent/expect-reboot'))

    def test_a_running_container_without_restart_policy_is_flagged_before_the_reboot(self):
        self.conf(PATCH_REBOOT_MODE='staggered', PATCH_REBOOT_DAY=self.today()); self.write('/var/run/reboot-required', 'x\n')
        self.fk('docker-ps', 'oneoff\n'); self.fk('docker-policy', '/oneoff no\n')
        self.run_agent('reboot-if-needed')
        al = self.posts('alert-topic'); self.assertEqual(len(al), 1); self.assertIn('oneoff', al[0][2])

    def test_approval_from_chatops_reboots_once(self):
        self.write('/var/run/reboot-required', 'x\n')
        msg = {'id': 'abc1', 'time': int(time.time()), 'event': 'message', 'tags': ['patch-approve'], 'message': 'free-vm'}
        self.srv.poll_lines = [json.dumps(msg)]
        self.run_agent('approve-poll'); self.assertEqual(self.calls().count('systemctl reboot'), 1)
        self.run_agent('approve-poll'); self.assertEqual(self.calls().count('systemctl reboot'), 1, 'the same approval is used once')

    def test_approval_for_another_machine_or_stale_is_ignored(self):
        self.write('/var/run/reboot-required', 'x\n')
        other = {'id': 'x1', 'time': int(time.time()), 'event': 'message', 'tags': ['patch-approve'], 'message': 'micro-edge'}
        stale = {'id': 'x2', 'time': int(time.time()) - 3600, 'event': 'message', 'tags': ['patch-approve'], 'message': 'free-vm'}
        untagged = {'id': 'x3', 'time': int(time.time()), 'event': 'message', 'tags': ['other'], 'message': 'free-vm'}
        self.srv.poll_lines = [json.dumps(m) for m in (other, stale, untagged)]
        self.run_agent('approve-poll'); self.assertNotIn('systemctl reboot', self.calls())

    def test_approval_without_a_waiting_reboot_only_says_so(self):
        msg = {'id': 'abc2', 'time': int(time.time()), 'event': 'message', 'tags': ['patch-approve'], 'message': 'free-vm'}
        self.srv.poll_lines = [json.dumps(msg)]
        self.run_agent('approve-poll'); self.assertNotIn('systemctl reboot', self.calls())
        self.assertEqual(json.loads(self.posts('status-topic')[-1][2])['event'], 'noreboot')

    def test_approval_polling_can_be_switched_off(self):
        self.conf(PATCH_POLL_APPROVALS='no'); self.run_agent('approve-poll'); self.assertEqual(self.srv.log, [])


class TestPostBoot(Base):
    def state(self, **kw):
        rows = {'kuma_app': 'true none', 'kuma_tailscale': 'true healthy', 'kuma_push': 'true none'}; rows.update(kw)
        self.fk('docker-state', ''.join(f'{k} {v}\n' for k, v in rows.items()))

    def test_everything_back_sends_a_quiet_back_event(self):
        self.state(); self.write('/var/lib/patch-agent/expect-reboot', '{}')
        r = self.run_agent('postboot', '--no-wait'); self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc = json.loads(self.posts('status-topic')[-1][2]); self.assertEqual((doc['event'], doc['expected'], doc['problems']), ('back', True, []))
        self.assertEqual(self.posts('alert-topic'), []); self.assertFalse(os.path.exists(self.root + '/var/lib/patch-agent/expect-reboot'))

    def test_a_missing_container_alerts_with_the_machine_name(self):
        self.state(kuma_app='false none')
        r = self.run_agent('postboot', '--no-wait'); self.assertEqual(r.returncode, 1)
        al = self.posts('alert-topic'); self.assertEqual(len(al), 1)
        self.assertIn('free-vm', al[0][1]['Title']); self.assertIn('kuma_app: not running', al[0][2]); self.assertEqual(al[0][1]['Priority'], '5')
        self.assertIn('not planned', al[0][2], 'no expect-reboot stamp: the reboot was not ours')
        self.assertEqual(json.loads(self.posts('status-topic')[-1][2])['event'], 'broken')

    def test_unhealthy_container_docker_down_and_tailscale_down(self):
        self.state(kuma_tailscale='true unhealthy')
        self.assertIn('kuma_tailscale: unhealthy', json.loads(self.run_agent('postboot', '--no-wait').stdout.splitlines()[-1])['problems'])
        self.state(); open(os.path.join(self.fake, 'ts-down'), 'w').close()
        self.assertIn('tailscale (kuma_tailscale) is not connected', json.loads(self.run_agent('postboot', '--no-wait').stdout.splitlines()[-1])['problems'])
        os.remove(os.path.join(self.fake, 'ts-down')); open(os.path.join(self.fake, 'docker-down'), 'w').close()
        self.assertEqual(json.loads(self.run_agent('postboot', '--no-wait').stdout.splitlines()[-1])['problems'], ['docker is not running'])

    def test_a_failing_heartbeat_sender_is_reported(self):
        self.state(); self.fk('docker-logs', 'push: the Home Kuma did not answer\n')
        self.assertTrue(any('heartbeat' in p for p in json.loads(self.run_agent('postboot', '--no-wait').stdout.splitlines()[-1])['problems']))
        self.fk('docker-logs', 'push: the Home Kuma did not answer\n')


class TestApply(Base):
    def apply(self, *args):
        e = {**os.environ, 'PATCH_ROOT': self.root, 'PATCH_NO_SYSTEMD': '1'}
        return subprocess.run(['bash', APPLY, *args], capture_output=True, text=True, env=e, timeout=60)

    def test_idempotent_and_staggered_timer_follows_the_mode(self):
        a = ['--host', 'micro-edge', '--day', 'fri', '--mode', 'staggered']
        r = self.apply(*a); self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('changes applied', r.stdout)
        timer = open(self.root + '/etc/systemd/system/patch-reboot.timer').read()
        self.assertIn('OnCalendar=Fri *-*-* 00:00:00 UTC', timer)
        self.assertIn('Automatic-Reboot "false"', open(self.root + '/etc/apt/apt.conf.d/52patching').read())
        r = self.apply(*a); self.assertIn('already up to date', r.stdout); self.assertNotIn('wrote', r.stdout)
        r = self.apply('--host', 'micro-edge', '--day', 'fri', '--mode', 'alert')
        self.assertFalse(os.path.exists(self.root + '/etc/systemd/system/patch-reboot.timer'), 'alert mode has no reboot timer')
        self.assertTrue(os.path.exists(self.root + '/etc/systemd/system/patch-report.timer'))
        self.assertTrue(os.path.exists(self.root + '/usr/local/sbin/patch-agent'))
        self.assertIn('PATCH_REBOOT_MODE=alert', open(self.root + '/etc/patch-agent.conf').read())

    def test_vm_manager_installer_turns_apt_installs_off_but_keeps_the_lists_fresh(self):
        r = self.apply('--host', 'free-vm', '--day', 'wed', '--installer', 'osconfig'); self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('installer osconfig', r.stdout)
        a = open(self.root + '/etc/apt/apt.conf.d/20auto-upgrades').read()
        self.assertIn('Update-Package-Lists "1"', a); self.assertIn('Unattended-Upgrade "0"', a)
        self.assertIn('PATCH_INSTALLER=osconfig', open(self.root + '/etc/patch-agent.conf').read())
        self.apply('--host', 'free-vm', '--day', 'wed')
        self.assertIn('Unattended-Upgrade "1"', open(self.root + '/etc/apt/apt.conf.d/20auto-upgrades').read())
        self.assertNotEqual(self.apply('--installer', 'yum').returncode, 0)

    def test_secrets_file_is_private_empty_and_never_overwritten(self):
        shutil.rmtree(self.root + '/etc'); os.makedirs(self.root + '/etc')
        self.apply('--host', 'x', '--day', 'mon')
        p = self.root + '/etc/patch-agent.env'
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)
        text = open(p).read(); self.assertIn('PATCH_NTFY_URL=\n', text); self.assertNotIn('http', text.replace('https://ntfy.sh/<long random name>', '').replace('https://<kuma host>/api/push/<token>', ''))
        with open(p, 'a') as f: f.write('PATCH_NTFY_URL=https://ntfy.sh/mine\n')
        self.apply('--host', 'x', '--day', 'mon'); self.assertIn('https://ntfy.sh/mine', open(p).read())
        for f in glob.glob(self.root + '/etc/**/*', recursive=True):
            if os.path.isfile(f) and not f.endswith('patch-agent.env'):
                with open(f) as fh: self.assertNotIn('ntfy.sh/', fh.read(), f)

    def test_bad_arguments_are_refused(self):
        for bad in (['--day', 'someday'], ['--mode', 'always'], ['--time', '25:00'], ['--host', 'a b'], ['--containers', 'x;rm -rf /'], ['--bogus']):
            self.assertNotEqual(self.apply(*bad).returncode, 0, bad)

    def test_dry_run_writes_nothing(self):
        r = self.apply('--host', 'x', '--day', 'mon', '--dry-run'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.root + '/etc/systemd/system/patch-report.timer'))

    def test_the_unit_files_are_valid_for_systemd(self):
        if not shutil.which('systemd-analyze'): self.skipTest('systemd-analyze not installed')
        self.apply('--host', 'x', '--day', 'wed', '--mode', 'staggered')
        for t in glob.glob(self.root + '/etc/systemd/system/*.timer'):
            with open(t) as f: cal = [l.strip().split('=', 1)[1] for l in f if l.startswith('OnCalendar=')]
            if not cal: continue
            r = subprocess.run(['systemd-analyze', 'calendar', *cal], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, t + r.stderr)


class TestCompose(unittest.TestCase):
    """Every container must come back by itself after a reboot: restart: unless-stopped (or always) on every service of every compose file in the
    repo. One-shot jobs that are meant to exit are listed below WITH the reason."""
    EXEMPT = {('dependency-track/docker-compose.yml', 'sbom'): 'profile tools: a one-shot SBOM generator',
              ('affine/docker-compose.yml', 'migration'): 'one-shot database migration (restart: no)'}

    def test_every_service_restarts_unless_stopped(self):
        try: import yaml
        except ImportError: self.skipTest('PyYAML not installed')
        root = HERE
        while root != '/' and not os.path.isdir(os.path.join(root, '.git')) and not os.path.isfile(os.path.join(root, '.git')): root = os.path.dirname(root)
        files = [f for pat in ('docker-compose*.y*ml', 'compose.y*ml') for f in glob.glob(os.path.join(root, '**', pat), recursive=True) if '/node_modules/' not in f]
        if not files: self.skipTest('no compose files in this repo')
        bad = []
        for f in files:
            rel = os.path.relpath(f, root)
            with open(f) as fh: doc = yaml.safe_load(fh) or {}
            for name, svc in (doc.get('services') or {}).items():
                if (svc or {}).get('restart') not in ('unless-stopped', 'always') and (rel, name) not in self.EXEMPT: bad.append(f'{rel}: {name}')
        self.assertEqual(bad, [], 'services without restart: unless-stopped (add it, or list a one-shot job in EXEMPT with its reason)')


if __name__ == '__main__':
    unittest.main()
