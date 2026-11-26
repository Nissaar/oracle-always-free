#!/usr/bin/env python3
"""Offline checker for tailscale/policy.hujson (standard library only).

What it does, in order:
  1. parses the HuJSON (comments and trailing commas stripped),
  2. validates the structure (known keys, every tag owned, every src/dst known, no any-to-any,
     servers never get "*" ports or a way to the owner's devices, a reason comment above every
     grant and test, Kubernetes impersonation limited to the expected groups),
  3. runs the policy's own "tests" and "sshTests" through a small evaluator (the same cases
     Tailscale runs when you press Save),
  4. checks coverage: every grant has an accept test, every tag has deny tests,
  5. compares the evaluator against an independent allow/deny table (INTENDED below) over every
     source x destination x port, so a grant that is too wide OR too narrow is reported.

It is NOT Tailscale: it implements only the subset of the policy language this file uses and
cannot know what Tailscale's parser accepts. Tailscale's own tests on Save are the second check.

Usage:  python3 tailscale/check.py [policy.hujson] [--final]
  --final  also fail while the placeholders (owner@example.com, 192.0.2.x) are still in the file;
           run it on the policy you are about to paste.
Exit code 0 = all good, 1 = at least one problem (printed), 2 = file unreadable.
"""
import ipaddress
import json
import re
import sys
from pathlib import Path

ALLOWED_TOP = {"groups", "hosts", "tagOwners", "grants", "ssh", "tests", "sshTests"}
REQUIRED_TOP = ["tagOwners", "grants", "ssh", "tests", "sshTests"]
ALLOWED_GRANT_KEYS = {"src", "dst", "ip", "app"}
K8S_CAP = "tailscale.com/cap/kubernetes"
PLACEHOLDERS = ("example.com", "example.net", "192.0.2.")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+$")


# ---------------------------------------------------------------- HuJSON

def _scan(text):
    """Yield (index, char, kind) with kind in code / string / comment. Newlines inside comments
    are reported as code so line numbers stay right."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            for k in range(i, min(j + 1, n)):
                yield k, text[k], "string"
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                yield k, text[k], "comment"
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                yield k, text[k], "code" if text[k] == "\n" else "comment"
            i = j
        else:
            yield i, c, "code"
            i += 1


def strip_hujson(text):
    """HuJSON -> plain JSON text: drop comments, drop trailing commas before } or ]."""
    out = []
    for _, c, kind in _scan(text):
        if kind == "comment":
            continue
        if kind == "code" and c in "}]":
            k = len(out) - 1
            while k >= 0 and out[k].isspace():
                k -= 1
            if k >= 0 and out[k] == ",":
                del out[k]
        out.append(c)
    return "".join(out)


def load_policy(path):
    raw = Path(path).read_text(encoding="utf-8")
    return raw, json.loads(strip_hujson(raw))


def object_start_lines(raw, key):
    """1-based line numbers of the objects that are direct children of the top-level array `key`."""
    stack, last_str, pending, buf, lines = [], None, None, [], []
    line = 1
    for idx, c, kind in _scan(raw):
        if c == "\n":
            line += 1
        if kind == "string":
            buf.append((idx, c))
            continue
        if buf:
            s = "".join(ch for _, ch in buf)
            last_str = s[1:-1] if len(s) >= 2 else s
            buf = []
        if kind != "code":
            continue
        if c == ":":
            pending = last_str
        elif c in "{[":
            if c == "{" and len(stack) == 2 and stack[-1] == ("[", key):
                lines.append(line)
            stack.append((c, pending if c == "[" else None))
            pending = None
        elif c in "}]":
            if stack:
                stack.pop()
        elif c == ",":
            pending = None
    return lines


def uncommented(raw, key):
    """Line numbers of entries of array `key` with no comment line directly above."""
    src = raw.splitlines()
    bad = []
    for ln in object_start_lines(raw, key):
        k = ln - 2
        while k >= 0 and not src[k].strip():
            k -= 1
        prev = src[k].strip() if k >= 0 else ""
        if not (prev.startswith("//") or prev.endswith("*/")):
            bad.append(ln)
    return bad


# ------------------------------------------------------------- evaluator

def parse_ip_rule(rule):
    """'*' | 'tcp:443' | 'udp:1-1024' | 'tcp' | '443' -> (protos, lo, hi) or None if malformed."""
    if rule == "*":
        return ({"tcp", "udp", "icmp"}, 0, 65535)
    m = re.fullmatch(r"(?:(tcp|udp|icmp|sctp):)?(\*|\d+(?:-\d+)?)?", rule)
    if not m or not (m.group(1) or m.group(2)):
        return None
    protos = {m.group(1)} if m.group(1) else {"tcp", "udp"}
    spec = m.group(2)
    if spec is None or spec == "*":
        return (protos, 0, 65535)
    lo, _, hi = spec.partition("-")
    lo, hi = int(lo), int(hi or lo)
    if not (0 <= lo <= hi <= 65535):
        return None
    return (protos, lo, hi)


class Policy:
    def __init__(self, data):
        self.d = data
        self.groups = data.get("groups", {})
        self.hosts = data.get("hosts", {})
        self.tags = list(data.get("tagOwners", {}))
        self.grants = data.get("grants", [])

    # alias helpers
    def host_net(self, name):
        try:
            return ipaddress.ip_network(self.hosts[name], strict=False)
        except (KeyError, ValueError):
            return None

    def src_matches(self, alias, principal):
        if alias == principal:
            return True
        if alias.startswith("group:"):
            return principal in self.groups.get(alias, [])
        return False

    def dst_matches(self, alias, target):
        if alias == target:
            return True
        if alias == "autogroup:internet":
            if target == "internet":
                return True
            try:
                return ipaddress.ip_address(target).is_global
            except ValueError:
                return False
        if alias.startswith("group:"):
            return target in self.groups.get(alias, [])
        # network aliases: a host alias, a CIDR or an IP, against a host alias or an IP
        a_net = self.host_net(alias) if alias in self.hosts else _net(alias)
        if a_net is None:
            return False
        t_net = self.host_net(target) if target in self.hosts else _net(target)
        return t_net is not None and t_net.version == a_net.version and t_net.subnet_of(a_net)

    def allowed(self, src, dst, proto, port):
        for g in self.grants:
            if not any(self.src_matches(a, src) for a in g["src"]):
                continue
            if not any(self.dst_matches(a, dst) for a in g["dst"]):
                continue
            for r in g.get("ip", []):
                p = parse_ip_rule(r)
                if p and proto in p[0] and p[1] <= port <= p[2]:
                    return True
        return False

    def matching_grants(self, src, dst, proto, port):
        """Indexes of the grants that on their own allow this flow."""
        return [i for i, g in enumerate(self.grants)
                if Policy({"groups": self.groups, "hosts": self.hosts, "grants": [g]})
                .allowed(src, dst, proto, port)]

    def ssh_allowed(self, src, dst, user):
        for r in self.d.get("ssh", []):
            if not any(self.src_matches(a, src) for a in r.get("src", [])):
                continue
            if not any(self.dst_matches(a, dst) for a in r.get("dst", [])):
                continue
            users = r.get("users", [])
            if user in users or ("autogroup:nonroot" in users and user != "root"):
                return True
        return False


def _net(s):
    try:
        return ipaddress.ip_network(s, strict=False)
    except ValueError:
        return None


def split_target(s):
    """'tag:chatops:443' -> ('tag:chatops', 443)."""
    host, _, port = s.rpartition(":")
    if not host or not port.isdigit() or not 0 <= int(port) <= 65535:
        raise ValueError(f"bad destination {s!r} (want target:port)")
    return host, int(port)


# ------------------------------------------------------------ the table
# Independent statement of the intended flows (written from the repos' docs, not from the policy).
# Sources: the owner's devices, a stranger (another Tailscale user), and every tag.
# Everything not returned True here must be denied.

STRANGER = "stranger@example.net"
EXPECTED_TAGS = {"tag:k8s-operator", "tag:k8s", "tag:chatops", "tag:kuma-hub", "tag:kuma", "tag:edge"}
TABLE_PORTS = [("tcp", p) for p in (22, 53, 80, 443, 1055, 3000, 3001, 5000, 6443, 8080)] + \
              [("udp", p) for p in (53, 443, 41641)]


def intended(src, dst, proto, port, owner):
    if src == owner:
        if dst in EXPECTED_TAGS:
            return True                                   # administer every server, any port
        if dst == "vcn":
            return proto == "tcp" and port == 22          # ssh to the micros via the subnet route
        return dst == "internet"                          # exit nodes
    if src == "tag:chatops":                              # kubectl through the API server proxy
        return dst == "tag:k8s-operator" and proto == "tcp" and port == 443
    if src == "tag:k8s":                                  # egress proxy -> private ntfy
        return dst == "tag:chatops" and proto == "tcp" and port == 443
    if src == "tag:kuma":                                 # git sync + push, ghcr cache
        return proto == "tcp" and ((dst == "tag:kuma-hub" and port == 443)
                                   or (dst == "tag:edge" and port == 5000))
    return False                                          # stranger, operator, kuma-hub, edge: nothing


# Kubernetes groups each source may impersonate through the operator's API proxy.
EXPECTED_K8S = {"group:owner": {"system:masters"}, "tag:chatops": {"chatops"}}


# ------------------------------------------------------------ validation

def validate(raw, data, final=False):
    errs = []
    add = errs.append
    for k in data:
        if k not in ALLOWED_TOP:
            add(f"unknown or unsupported top-level key {k!r}"
                + (" (use grants, not acls)" if k == "acls" else ""))
    for k in REQUIRED_TOP:
        if k not in data:
            add(f"missing top-level key {k!r}")
    if errs:
        return errs

    pol = Policy(data)
    owners = data["tagOwners"]
    groups = data.get("groups", {})
    hosts = data.get("hosts", {})

    for g, members in groups.items():
        if not g.startswith("group:") or not members or not all(EMAIL.match(m) for m in members):
            add(f"group {g!r} must be group:<name> with e-mail members")
    for h, v in hosts.items():
        if _net(v) is None:
            add(f"host {h!r} is not an address or range")
    for t, own in owners.items():
        if not t.startswith("tag:"):
            add(f"tagOwners key {t!r} is not a tag")
        if not own:
            add(f"{t} has no owner")
        for o in own:
            if t == o:
                add(f"{t} owns itself")
            elif not (o == "autogroup:admin" or o in groups or o in owners):
                add(f"{t}: unknown owner {o!r}")

    def known_dst(a):
        return a in owners or a in groups or a in hosts or a == "autogroup:internet" or bool(EMAIL.match(a))

    def known_src(a):
        return a in owners or a in groups or bool(EMAIL.match(a))

    used = set()
    for i, g in enumerate(data["grants"], 1):
        where = f"grant #{i}"
        for k in g:
            if k not in ALLOWED_GRANT_KEYS:
                add(f"{where}: unsupported key {k!r}")
        for k in ("src", "dst", "ip"):
            if not isinstance(g.get(k), list) or not g.get(k):
                add(f"{where}: {k} must be a non-empty list")
        if any(k not in g or not isinstance(g[k], list) for k in ("src", "dst", "ip")):
            continue
        for a in g["src"]:
            if a == "*":
                add(f"{where}: src '*' (any source) is not allowed")
            elif not known_src(a):
                add(f"{where}: unknown src {a!r}")
        for a in g["dst"]:
            if a == "*":
                add(f"{where}: dst '*' (any destination) is not allowed")
            elif not known_dst(a):
                add(f"{where}: unknown dst {a!r}")
        for r in g["ip"]:
            if parse_ip_rule(r) is None:
                add(f"{where}: bad ip rule {r!r}")
        used.update(a for a in g["src"] + g["dst"] if a.startswith("tag:"))
        src_tags = [a for a in g["src"] if a.startswith("tag:")]
        if "autogroup:internet" in g["src"]:
            add(f"{where}: autogroup:internet cannot be a source")
        if src_tags:
            if "*" in g["ip"]:
                add(f"{where}: a server ({', '.join(src_tags)}) must get explicit ports, not '*'")
            for a in g["dst"]:
                if a in groups or EMAIL.match(a) or a == "autogroup:internet":
                    add(f"{where}: a server ({', '.join(src_tags)}) must not reach {a}")
        cap = (g.get("app") or {})
        for name, val in cap.items():
            if name != K8S_CAP:
                add(f"{where}: unsupported app capability {name!r}")
                continue
            got = set()
            for entry in val:
                got.update(entry.get("impersonate", {}).get("groups", []))
            for a in g["src"]:
                allowed = EXPECTED_K8S.get(a)
                if allowed is None:
                    add(f"{where}: {a} may not impersonate Kubernetes groups")
                elif not got <= allowed:
                    add(f"{where}: {a} may impersonate only {sorted(allowed)}, not {sorted(got - allowed)}")

    for t in owners:
        if t not in used:
            add(f"{t} is in tagOwners but no grant uses it (remove it, or write the rule)")
    if set(owners) != EXPECTED_TAGS:
        add(f"tags differ from the checker's table: extra {sorted(set(owners) - EXPECTED_TAGS)}, "
            f"missing {sorted(EXPECTED_TAGS - set(owners))} (update EXPECTED_TAGS and intended())")

    # comments: a reason above every grant / test / sshTest
    for key in ("grants", "tests", "sshTests"):
        for ln in uncommented(raw, key):
            add(f"{key}: the entry at line {ln} has no comment line directly above it")

    # ssh and tests
    for r in data["ssh"]:
        if r.get("action") not in ("accept", "check") or not r.get("src") or not r.get("dst") \
                or not r.get("users"):
            add(f"ssh rule needs action accept|check, src, dst and users: {r}")
    tests, ssh_tests = data["tests"], data["sshTests"]
    if not tests:
        add("no tests: a policy without tests must not go live")
    if not ssh_tests:
        add("no sshTests: say explicitly who may NOT use Tailscale SSH")

    accepted_by = set()
    deny_src = set()
    for n, t in enumerate(tests, 1):
        where = f"test #{n}"
        src = t.get("src", "")
        if not known_src(src):
            add(f"{where}: unknown src {src!r}")
            continue
        if not t.get("accept") and not t.get("deny"):
            add(f"{where}: needs accept or deny")
        proto = t.get("proto", "tcp")
        if proto not in ("tcp", "udp"):
            add(f"{where}: proto {proto!r} not supported by the checker")
            continue
        if t.get("deny"):
            deny_src.add(src)
        for verdict in ("accept", "deny"):
            for d in t.get(verdict, []):
                try:
                    dst, port = split_target(d)
                except ValueError as e:
                    add(f"{where}: {e}")
                    continue
                if not known_dst(dst):
                    add(f"{where}: unknown destination {dst!r}")
                    continue
                got = pol.allowed(src, dst, proto, port)
                if verdict == "accept" and not got:
                    add(f"{where}: {src} -> {d} should be ACCEPTED but the grants deny it")
                if verdict == "deny" and got:
                    add(f"{where}: {src} -> {d} should be DENIED but a grant allows it")
                if verdict == "accept":
                    accepted_by.update(pol.matching_grants(src, dst, proto, port))
    for n, t in enumerate(ssh_tests, 1):
        for key in ("src", "dst"):
            if not t.get(key):
                add(f"sshTest #{n}: missing {key}")
        for verdict in ("accept", "deny"):
            for user in t.get(verdict, []):
                for d in t.get("dst", []):
                    got = pol.ssh_allowed(t.get("src", ""), d, user)
                    if verdict == "accept" and not got:
                        add(f"sshTest #{n}: {t['src']} -> {d} as {user} should be accepted but is not")
                    if verdict == "deny" and got:
                        add(f"sshTest #{n}: {t['src']} -> {d} as {user} should be denied but is allowed")

    # coverage
    for i, g in enumerate(data["grants"]):
        if g.get("dst") == ["autogroup:internet"]:
            continue  # cannot be a Tailscale test target; covered by the table below
        if i not in accepted_by:
            add(f"grant #{i + 1} has no accept test that it allows")
    for t in owners:
        if t not in deny_src:
            add(f"no deny test with {t} as source")

    # the independent table
    owner = (groups.get("group:owner") or [None])[0]
    if owner is None:
        add("group:owner is missing or empty")
    else:
        dsts = sorted(EXPECTED_TAGS) + [owner, STRANGER, "vcn", "internet"]
        for src in [owner, STRANGER] + sorted(EXPECTED_TAGS):
            for dst in dsts:
                if dst == src:
                    continue
                for proto, port in TABLE_PORTS:
                    want = intended(src, dst, proto, port, owner)
                    got = pol.allowed(src, dst, proto, port)
                    if want != got:
                        add(f"table: {src} -> {dst} {proto}/{port}: intended "
                            f"{'allow' if want else 'deny'}, policy {'allows' if got else 'denies'}")

    if final:
        for ph in PLACEHOLDERS:
            if ph in raw:
                add(f"--final: placeholder {ph!r} is still in the policy")
    return errs


def table_size():
    n = len(EXPECTED_TAGS)
    return len(TABLE_PORTS) * ((n + 2) * (n + 4) - (n + 2))


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    final = "--final" in argv
    path = args[0] if args else str(Path(__file__).with_name("policy.hujson"))
    try:
        raw, data = load_policy(path)
    except (OSError, ValueError) as e:
        print(f"cannot read {path}: {e}")
        return 2
    errs = validate(raw, data, final)
    if errs:
        print(f"{len(errs)} problem(s) in {path}:")
        for e in errs:
            print("  - " + e)
        return 1
    print(f"OK {path}: {len(data['grants'])} grants, {len(data['tests'])} tests, "
          f"{len(data['sshTests'])} sshTests, allow/deny table ({table_size()} cases) matches"
          + (" (final: no placeholders)" if final else " (placeholders still present: run with --final before pasting)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
