"""Offline tests of scripts/node-image-bump.sh: a fake `oci` prints canned JSON (the shapes of `oci ce ...` output; NOT yet checked against the real CLI).
Run: python3 -m unittest scripts/test_node_image_bump.py     (from the repo root)"""
import json
import os
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, 'node-image-bump.sh')
NAMES = {
    'old': 'Oracle-Linux-8.10-aarch64-2026.09.30-0-OKE-1.34.1-1111', 'mid': 'Oracle-Linux-8.10-aarch64-2026.10.31-0-OKE-1.34.1-2222',
    'new': 'Oracle-Linux-8.10-aarch64-2026.11.15-0-OKE-1.34.1-3333',
}
SOURCES = [
    {'source-name': NAMES['mid'], 'image-id': 'ocid1.image.oc1.af-johannesburg-1.mid', 'source-type': 'IMAGE'},
    {'source-name': NAMES['new'], 'image-id': 'ocid1.image.oc1.af-johannesburg-1.new', 'source-type': 'IMAGE'},
    {'source-name': NAMES['old'], 'image-id': 'ocid1.image.oc1.af-johannesburg-1.old', 'source-type': 'IMAGE'},
    {'source-name': 'Oracle-Linux-8.10-aarch64-GPU-2026.11.20-0-OKE-1.34.1-4444', 'image-id': 'ocid1.image.oc1.af-johannesburg-1.gpu', 'source-type': 'IMAGE'},
    {'source-name': 'Oracle-Linux-8.10-x86_64-2026.11.20-0-OKE-1.34.1-5555', 'image-id': 'ocid1.image.oc1.af-johannesburg-1.x86', 'source-type': 'IMAGE'},
    {'source-name': 'Oracle-Linux-8.10-aarch64-2026.11.20-0-OKE-1.35.0-6666', 'image-id': 'ocid1.image.oc1.af-johannesburg-1.k135', 'source-type': 'IMAGE'},
]
FAKE = '''#!/bin/sh
echo "oci $*" >> "$FAKE_DIR/calls"
case "$1 $2" in
  "ce cluster") cat "$FAKE_DIR/cluster.json";;
  "ce node-pool") cat "$FAKE_DIR/pool.json";;
  "ce node-pool-options") cat "$FAKE_DIR/options.json";;
  *) echo "unexpected: $*" >&2; exit 9;;
esac
'''


class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        p = os.path.join(self.d, 'oci')
        with open(p, 'w') as f: f.write(FAKE)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        self.file = os.path.join(self.d, 'node-image.auto.tfvars')
        self.out = os.path.join(self.d, 'gh-output')
        self.world()

    def world(self, live='old', version='v1.34.1', clusters=True):
        self.put('cluster.json', {'data': [{'id': 'ocid1.cluster.x', 'kubernetes-version': version}] if clusters else []})
        self.put('pool.json', {'data': [{'id': 'ocid1.nodepool.x', 'name': 'arm', 'node-source': {'image-id': f'ocid1.image.oc1.af-johannesburg-1.{live}', 'source-name': NAMES.get(live, 'x')}}]})
        self.put('options.json', {'data': {'sources': SOURCES}})

    def put(self, name, doc):
        with open(os.path.join(self.d, name), 'w') as f: json.dump(doc, f)

    def run_script(self, *args):
        env = {**os.environ, 'PATH': self.d + os.pathsep + os.environ['PATH'], 'FAKE_DIR': self.d, 'OCI_COMPARTMENT_OCID': 'ocid1.compartment.x', 'NODE_IMAGE_FILE': self.file, 'GITHUB_OUTPUT': self.out}
        return subprocess.run(['bash', SCRIPT, *args], capture_output=True, text=True, env=env, timeout=60)

    def outputs(self):
        with open(self.out) as f: return dict(l.rstrip('\n').split('=', 1) for l in f if '=' in l)

    def test_no_pin_yet_pins_what_the_pool_runs_now_and_changes_nothing_else(self):
        r = self.run_script(); self.assertEqual(r.returncode, 0, r.stderr)
        text = open(self.file).read(); self.assertIn(f'node_image = "{NAMES["old"]}|ocid1.image.oc1.af-johannesburg-1.old"', text)    # the LIVE image, not the newest
        self.assertEqual(self.outputs()['result'], 'pin'); self.assertIn('pin the OKE node image', self.outputs()['title'])
        self.assertIn('node-image/Oracle-Linux-8.10-aarch64-2026.09.30-0-OKE-1.34.1-1111', self.outputs()['branch'])

    def test_a_newer_image_is_proposed_only_for_this_kubernetes_version_arm_and_not_gpu(self):
        with open(self.file, 'w') as f: f.write(f'node_image = "{NAMES["mid"]}|ocid1.image.oc1.af-johannesburg-1.mid"\n')
        r = self.run_script(); self.assertEqual(r.returncode, 0, r.stderr); self.assertEqual(self.outputs()['result'], 'bump')
        self.assertIn(f'{NAMES["new"]}|ocid1.image.oc1.af-johannesburg-1.new', open(self.file).read())                                 # not gpu, not x86, not 1.35
        self.assertEqual(self.outputs()['image'], NAMES['new']); self.assertEqual(self.outputs()['previous'], NAMES['mid'])

    def test_already_the_newest_changes_nothing(self):
        line = f'node_image = "{NAMES["new"]}|ocid1.image.oc1.af-johannesburg-1.new"\n'
        with open(self.file, 'w') as f: f.write('# old comment\n' + line)
        r = self.run_script(); self.assertEqual(r.returncode, 0); self.assertEqual(self.outputs()['result'], 'none')
        self.assertEqual(open(self.file).read(), '# old comment\n' + line)

    def test_dry_run_writes_no_file(self):
        r = self.run_script('--dry-run'); self.assertEqual(r.returncode, 0); self.assertIn('result: pin', r.stdout); self.assertFalse(os.path.exists(self.file))

    def test_only_read_calls_are_made(self):
        self.run_script()
        with open(os.path.join(self.d, 'calls')) as f: calls = f.read()
        import re
        for line in calls.splitlines(): self.assertRegex(line, r'^oci ce (cluster list|node-pool list|node-pool-options get) ', line)     # list / get only
        self.assertIn('oci ce node-pool-options get', calls)

    def test_no_cluster_or_no_compartment_stops_with_a_clear_message(self):
        self.world(clusters=False); r = self.run_script(); self.assertNotEqual(r.returncode, 0); self.assertIn('no ACTIVE cluster', r.stderr)
        env = {k: v for k, v in os.environ.items() if k != 'OCI_COMPARTMENT_OCID'}
        r = subprocess.run(['bash', SCRIPT], capture_output=True, text=True, env=env); self.assertNotEqual(r.returncode, 0); self.assertIn('OCI_COMPARTMENT_OCID', r.stderr)


if __name__ == '__main__':
    unittest.main()
