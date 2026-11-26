"""Unit tests for check.py (offline, stdlib only). Run: python3 -m unittest -v tailscale/test_check.py"""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check  # noqa: E402

POLICY = Path(__file__).resolve().parent / "policy.hujson"
RAW, DATA = check.load_policy(POLICY)
OWNER = "owner@example.com"


def problems(mutate=None, raw=None, final=False):
    data = copy.deepcopy(DATA)
    if mutate:
        mutate(data)
    return check.validate(RAW if raw is None else raw, data, final)


def has(errs, text):
    return any(text in e for e in errs)


class HuJson(unittest.TestCase):
    def test_comments_and_trailing_commas(self):
        text = '{\n // line\n "a": [1, 2,], /* block\n over lines */ "b": {"c": 1,},\n}'
        self.assertEqual(json.loads(check.strip_hujson(text)), {"a": [1, 2], "b": {"c": 1}})

    def test_comment_markers_inside_strings_are_kept(self):
        text = '{"url": "https://x.example/a//b", "s": "/* not a comment */", "t": "a,]",}'
        self.assertEqual(json.loads(check.strip_hujson(text)),
                         {"url": "https://x.example/a//b", "s": "/* not a comment */", "t": "a,]"})

    def test_escaped_quote_in_string(self):
        self.assertEqual(json.loads(check.strip_hujson(r'{"a": "x\" // y",}')), {"a": 'x" // y'})

    def test_object_start_lines_and_comment_detection(self):
        raw = '{\n"grants": [\n// why\n{"a": 1},\n\n{"a": 2},\n],\n"x": [\n{"a": 3}\n]\n}'
        self.assertEqual(check.object_start_lines(raw, "grants"), [4, 6])
        self.assertEqual(check.uncommented(raw, "grants"), [6])


class IpRules(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(check.parse_ip_rule("tcp:443"), ({"tcp"}, 443, 443))
        self.assertEqual(check.parse_ip_rule("udp:10-20"), ({"udp"}, 10, 20))
        self.assertEqual(check.parse_ip_rule("*")[1:], (0, 65535))
        self.assertIsNone(check.parse_ip_rule("tcp:99999"))
        self.assertIsNone(check.parse_ip_rule("tcp:20-10"))
        self.assertIsNone(check.parse_ip_rule("nonsense"))

    def test_split_target(self):
        self.assertEqual(check.split_target("tag:chatops:443"), ("tag:chatops", 443))
        with self.assertRaises(ValueError):
            check.split_target("tag:chatops")


class Evaluator(unittest.TestCase):
    pol = check.Policy(DATA)

    def test_allowed_flows(self):
        a = self.pol.allowed
        self.assertTrue(a(OWNER, "tag:chatops", "tcp", 443))
        self.assertTrue(a(OWNER, "tag:edge", "udp", 53))
        self.assertTrue(a(OWNER, "vcn", "tcp", 22))
        self.assertTrue(a(OWNER, "internet", "tcp", 443))
        self.assertTrue(a("tag:chatops", "tag:k8s-operator", "tcp", 443))
        self.assertTrue(a("tag:k8s", "tag:chatops", "tcp", 443))
        self.assertTrue(a("tag:kuma", "tag:kuma-hub", "tcp", 443))
        self.assertTrue(a("tag:kuma", "tag:edge", "tcp", 5000))

    def test_denied_flows(self):
        a = self.pol.allowed
        self.assertFalse(a(OWNER, "vcn", "tcp", 443))
        self.assertFalse(a(OWNER, "vcn", "udp", 22))
        self.assertFalse(a("tag:chatops", "tag:k8s-operator", "tcp", 80))
        self.assertFalse(a("tag:chatops", "tag:k8s-operator", "udp", 443))
        self.assertFalse(a("tag:chatops", "tag:kuma", "tcp", 443))
        self.assertFalse(a("tag:kuma", "tag:edge", "tcp", 22))
        self.assertFalse(a("tag:kuma", "tag:kuma", "tcp", 443))
        self.assertFalse(a("tag:edge", OWNER, "tcp", 22))
        self.assertFalse(a("tag:kuma-hub", "tag:kuma", "tcp", 443))
        self.assertFalse(a("stranger@example.net", "tag:chatops", "tcp", 443))

    def test_ip_inside_host_range(self):
        # the placeholder range is 192.0.2.0/24: an address in it is "vcn", one outside is not
        self.assertTrue(self.pol.allowed(OWNER, "192.0.2.10", "tcp", 22))
        self.assertFalse(self.pol.allowed(OWNER, "198.51.100.10", "tcp", 22))

    def test_no_ssh_rules(self):
        self.assertFalse(self.pol.ssh_allowed(OWNER, "tag:edge", "root"))


class RealPolicy(unittest.TestCase):
    def test_shipped_policy_is_clean(self):
        self.assertEqual(problems(), [])

    def test_final_rejects_placeholders(self):
        errs = problems(final=True)
        self.assertTrue(has(errs, "example.com"))
        self.assertTrue(has(errs, "192.0.2."))

    def test_final_passes_with_real_values(self):
        raw = RAW.replace("example.com", "mydomain.test").replace("192.0.2.0/24", "203.0.113.0/24")
        data = json.loads(check.strip_hujson(raw))
        self.assertEqual(check.validate(raw, data, final=True), [])

    def test_main_exit_codes(self):
        self.assertEqual(check.main([str(POLICY)]), 0)
        self.assertEqual(check.main([str(POLICY), "--final"]), 1)
        with tempfile.TemporaryDirectory() as d:
            bad = Path(d) / "bad.hujson"
            bad.write_text("{ not json")
            self.assertEqual(check.main([str(bad)]), 2)
            self.assertEqual(check.main([str(Path(d) / "missing.hujson")]), 2)


class Mutations(unittest.TestCase):
    """Each edit below is a plausible mistake; the checker must object."""

    def test_server_gets_wildcard_ports(self):
        def m(d):
            d["grants"].append({"src": ["tag:kuma"], "dst": ["tag:k8s-operator"], "ip": ["*"]})
        errs = problems(m)
        self.assertTrue(has(errs, "explicit ports"))
        self.assertTrue(has(errs, "table: tag:kuma -> tag:k8s-operator"))

    def test_widened_port_range(self):
        def m(d):
            d["grants"][6]["ip"] = ["tcp:1-65535"]
        self.assertTrue(has(problems(m), "table: tag:kuma -> tag:kuma-hub tcp/22"))

    def test_removed_rule_is_noticed(self):
        def m(d):
            del d["grants"][6]  # kuma -> kuma-hub
        errs = problems(m)
        self.assertTrue(has(errs, "intended allow, policy denies"))
        self.assertTrue(has(errs, "should be ACCEPTED"))

    def test_any_to_any(self):
        def m(d):
            d["grants"].append({"src": ["*"], "dst": ["*"], "ip": ["*"]})
        errs = problems(m)
        self.assertTrue(has(errs, "src '*'"))
        self.assertTrue(has(errs, "dst '*'"))

    def test_server_to_owner_devices(self):
        def m(d):
            d["grants"].append({"src": ["tag:edge"], "dst": ["group:owner"], "ip": ["tcp:22"]})
        self.assertTrue(has(problems(m), "must not reach group:owner"))

    def test_server_to_internet(self):
        def m(d):
            d["grants"].append({"src": ["tag:kuma"], "dst": ["autogroup:internet"], "ip": ["tcp:443"]})
        self.assertTrue(has(problems(m), "must not reach autogroup:internet"))

    def test_unknown_tag_and_alias(self):
        def m(d):
            d["grants"].append({"src": ["tag:ghost"], "dst": ["tag:chatops"], "ip": ["tcp:443"]})
            d["grants"].append({"src": ["tag:kuma"], "dst": ["nowhere"], "ip": ["tcp:443"]})
        errs = problems(m)
        self.assertTrue(has(errs, "unknown src 'tag:ghost'"))
        self.assertTrue(has(errs, "unknown dst 'nowhere'"))

    def test_chatops_must_not_be_cluster_admin(self):
        def m(d):
            d["grants"][4]["app"][check.K8S_CAP][0]["impersonate"]["groups"] = ["system:masters"]
        self.assertTrue(has(problems(m), "may impersonate only ['chatops']"))

    def test_kuma_may_not_impersonate(self):
        def m(d):
            d["grants"][6]["app"] = {check.K8S_CAP: [{"impersonate": {"groups": ["chatops"]}}]}
        self.assertTrue(has(problems(m), "may not impersonate"))

    def test_tests_required(self):
        self.assertTrue(has(problems(lambda d: d.update(tests=[])), "no tests"))
        self.assertTrue(has(problems(lambda d: d.update(sshTests=[])), "no sshTests"))
        self.assertTrue(has(problems(lambda d: d.pop("tests")), "missing top-level key 'tests'"))

    def test_wrong_test_expectation(self):
        def m(d):
            d["tests"][3]["accept"].append("tag:kuma:443")  # chatops -> kuma is denied
        self.assertTrue(has(problems(m), "should be ACCEPTED"))

    def test_deny_test_that_is_allowed(self):
        def m(d):
            d["tests"][3]["deny"].append("tag:k8s-operator:443")
        self.assertTrue(has(problems(m), "should be DENIED"))

    def test_grant_without_accept_test(self):
        def m(d):
            d["grants"].append({"src": ["tag:k8s"], "dst": ["tag:kuma-hub"], "ip": ["tcp:443"]})
        errs = problems(m)
        self.assertTrue(has(errs, "has no accept test"))
        self.assertTrue(has(errs, "table: tag:k8s -> tag:kuma-hub"))

    def test_unused_tag(self):
        def m(d):
            d["tagOwners"]["tag:spare"] = ["autogroup:admin"]
        errs = problems(m)
        self.assertTrue(has(errs, "no grant uses it"))
        self.assertTrue(has(errs, "tags differ"))

    def test_tag_owner_unknown(self):
        def m(d):
            d["tagOwners"]["tag:kuma"] = ["group:nobody"]
        self.assertTrue(has(problems(m), "unknown owner"))

    def test_acls_not_supported(self):
        def m(d):
            d["acls"] = [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]
        self.assertTrue(has(problems(m), "use grants, not acls"))

    def test_tailscale_ssh_rule_is_caught_by_ssh_tests(self):
        def m(d):
            d["ssh"] = [{"action": "accept", "src": ["tag:chatops"], "dst": ["tag:edge"], "users": ["root"]}]
        self.assertTrue(has(problems(m), "should be denied but is allowed"))

    def test_comment_required_above_each_grant(self):
        marker = "    // OWNER -> ORACLE NETWORK, SSH only"
        self.assertIn(marker, RAW)
        i = RAW.index(marker)
        j = RAW.index("\n    {", i)
        raw = RAW[:i] + RAW[j + 1:]  # drop the whole comment block of that grant
        self.assertTrue(has(problems(raw=raw), "no comment line directly above"))

    def test_bad_ip_rule_and_bad_group(self):
        def m(d):
            d["grants"][0]["ip"] = ["tcp:99999"]
            d["groups"]["group:owner"] = ["not-an-email"]
        errs = problems(m)
        self.assertTrue(has(errs, "bad ip rule"))
        self.assertTrue(has(errs, "e-mail members"))


if __name__ == "__main__":
    unittest.main()
