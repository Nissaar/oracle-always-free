# Tailscale access rules: tag the machines and restrict

Status: **DRAFT, not applied to any tailnet.** Written on 25 Nov 2026 (owner
decision "tags"). It was checked only by the offline checker in this folder
and by Tailscale's own policy tests, which run when you press Save. Nothing
was tried on the real tailnet. Flows I could not confirm from the repos' docs
are listed under "Verify first" at the end.

Files:
- `policy.hujson`: the policy (tags, grants, tests). A reason is written above
  every rule.
- `check.py`: offline checker (Python standard library only).
- `test_check.py`: unit tests of the checker.

## What the policy does

Your phone and laptop stay untagged (they are yours). Every server becomes a
tagged device and can only do what one rule below says.

Tags (device names as in the repos' docs):
- `tag:k8s-operator`: `oke-free`, the cluster's Tailscale operator
- `tag:k8s`: proxies the operator creates (the egress to ChatOps' ntfy)
- `tag:chatops`: `chatops`, the ChatOps sidecar on the Home server
- `tag:kuma-hub`: `kuma-home`, the Home Kuma's tailnet door
- `tag:kuma`: `kuma-oracle` and `kuma-gcp`, the two remote Kumas
- `tag:edge`: `micro-edge` and `exit-vps`, the exit nodes

Rules (everything else is denied):
1. You (owner) to every tag, all ports.
2. You to the Oracle network, port 22 only (ssh to the micros through
   micro-edge's subnet route).
3. You to the internet through an exit node (micro-edge, exit-vps).
4. You to the cluster API proxy, as Kubernetes admin (`system:masters`).
5. ChatOps to the cluster API proxy, port 443 only, as Kubernetes group
   `chatops`.
6. The cluster's proxies (tag:k8s) to ChatOps' ntfy, port 443 only.
7. Remote Kumas to the Home Kuma, port 443 only (git sync and push).
8. Remote Kumas to micro-edge's ghcr.io cache, port 5000 only.

No rule lets a server reach your phone or laptop, and no rule lets servers
reach each other beyond the lines above. Tailscale SSH is off for everyone
(`"ssh": []`): ssh to the micros is plain sshd through rule 2, the Google VM
goes through Google's IAP, the Home server through its own sshd.

## Steps (in this order)

Do steps 1 to 6 on a laptop if you can: editing JSON on a phone is slow. The
tests protect you either way.

### 1. Keep an escape hatch and save the old policy

- Open the admin console in a normal browser tab and keep it open:
  https://login.tailscale.com/admin/acls . It works without Tailscale, so no
  policy can lock you out of it.
- On the Access controls page copy the whole current text and save it in your
  password manager as "tailnet policy before tags".

### 2. Fill in the two placeholders (on a copy, never in git)

- Your login: admin console -> **Users** -> copy your login exactly. It is
  the one and only value that decides who is "owner": a typo here is not
  caught by any test (the tests use the same text).
- The Oracle network range: admin console -> **Machines** -> `micro-edge` ->
  **...** -> **Edit route settings**: the approved subnet shown there (same
  range as the VCN in `infra/network.tf`).
- On the laptop, from the repo folder:
  ```
  cp tailscale/policy.hujson ~/tailnet-policy.hujson
  ```
  Edit the copy: replace every `owner@example.com` with your login (it is in
  `groups` and in the tests) and `192.0.2.0/24` with the range.
- Check the copy: `python3 tailscale/check.py ~/tailnet-policy.hujson --final`.
  It must print `OK ... (final: no placeholders)`.

### 3. Merge the tag owners into your current policy first

The console only offers a tag in "Edit ACL tags" if the policy defines it.
Open Access controls, add the six lines of the `tagOwners` block of your copy
to the existing `tagOwners` (keep what is there; the cluster docs may already
have `tag:k8s-operator`, `tag:k8s`, `tag:chatops`), and Save.

### 4. Tag each device

Admin console -> **Machines** -> the device -> **...** -> **Edit ACL tags**
-> pick the tag -> Save.
- `chatops` -> `tag:chatops`
- `kuma-home` -> `tag:kuma-hub`
- `kuma-oracle` -> `tag:kuma`
- `kuma-gcp` -> `tag:kuma`
- `micro-edge` -> `tag:edge`
- `exit-vps` -> `tag:edge`
- `oke-free` and the proxy device the operator made for ChatOps' ntfy: no
  console step. The operator tags them itself (k8s-free-gitops repo,
  `tailscale-operator` values: `defaultTags`). Just confirm the Tags column
  shows `tag:k8s-operator` and `tag:k8s`.
- Phone and laptop: leave untagged.

Notes:
- A device name with a `-1` suffix is a stale duplicate: remove the old one.
- Tagging is one way. Going back to a user-owned device needs a new login of
  that device (`tailscale up --force-reauth`, or a fresh login link).
- Tagged devices do not expire their keys, so "Disable key expiry" is no
  longer needed for them.
- If your current policy is not "allow all", tagged devices stop matching its
  old member-based rules at once: do step 5 right after.
- Check `micro-edge` still shows its subnet route and exit node as approved.
  If not: **...** -> **Edit route settings** -> tick them again -> Save.

### 5. Put the new policy in

Access controls -> JSON editor -> select all -> paste the whole text of
`~/tailnet-policy.hujson` -> **Save**. Tailscale runs the `tests` and
`sshTests` sections: **Save only if they pass.** Never delete tests to get a
green Save; if one line is refused see "If Save refuses" below.

If your old policy had other sections that this file does not (for example
`nodeAttrs`, `autoApprovers`, a `hosts` entry like `chatops-device`, or the
cluster docs' step 4 grants), the new policy replaces them: carry over
anything you still need, then re-run the checker.

### 6. Check each flow

On the phone:
1. ChatOps ntfy app: send `status` in the `server` topic. An answer means the
   phone still reaches `chatops`.
2. In the `cluster` topic send `nodes`, then `pods` (and `flux`). Answers mean
   rule 5 works.
3. Open the AdGuard page `http://micro-edge` and a Kuma page
   (`kuma-oracle` / `kuma-gcp`, https). That is rule 1.
4. Optional: choose `micro-edge` as exit node and open a web page (rule 3).

On the laptop:
1. `kubectl get nodes` (rule 4; after `tailscale configure kubeconfig oke-free`).
2. ssh to a micro with the command of `docs/WHAT-YOU-DO.md` step 11 (rule 2).

Remote Kuma git sync and push (rules 7 and 8):
1. On the micro-kuma VM (ssh as above): `cd /opt/stacks/micro-kuma` then
   `sudo docker compose logs --tail 20 sync`. Expect "updated from commit" or
   "up to date", no "git fetch failed".
2. In the Home Kuma the push monitors "Kuma oracle" and "Kuma gcp" are green
   within 2 minutes.
3. For the Google VM use the IAP ssh command from the gcp-always-free README and
   the same `docker compose logs` line in its stack folder.
4. Cache (rule 8): on the Google VM `curl -s http://localhost:5000/v2/` prints `{}`.

Cluster to ChatOps ntfy (rule 6): the next weekly restore test or an Alertmanager
test alert (cluster `docs/WHAT-YOU-DO.md`, monitoring step 5) lands in the
ChatOps `cluster` topic.

Things that must now FAIL (one is enough to see the policy bites): on micro-kuma
`sudo docker exec kuma_tailscale wget -T 5 -qO- http://micro-edge:3000` times out
(AdGuard's page is not open to the Kumas), while the same with `:5000/v2/`
prints `{}`.

### 7. Rollback

- Fast: Access controls -> select all -> paste "tailnet policy before tags"
  from step 1 -> Save. The console's version history of the policy (on the same
  page; the name of the tab may differ) can restore an older version too.
- Tags can stay: they do nothing without rules, and the old policy is back in
  charge of anything that still matches.
- Locked out of the servers: nothing here can lock you out of the admin
  console. Open https://login.tailscale.com/admin/acls in a browser that is
  not using the tailnet and fix or revert the policy there. Servers keep
  their tags; your untagged phone and laptop are unaffected by tag rules.

### If Save refuses

Tailscale prints which test or line it refused. Typical causes in this draft
(see "Verify first", item 7): a test field it does not know, or the `vcn` alias
as a test destination. Fix only that line (for the alias use an address inside
your range, for example the micro's own), run the checker again, Save. If a
**grant** test fails, a rule is wrong: do not save; fix the rule, not the test.

## Run the checker and the tests

From the repo root (needs only Python 3):
```
python3 -m unittest -v tailscale/test_check.py
python3 tailscale/check.py
python3 tailscale/check.py ~/tailnet-policy.hujson --final
```
CI runs the first two on every change under `tailscale/`
(`.github/workflows/tailscale-policy.yml`). The checker parses the HuJSON,
validates it (every tag owned, every source and destination known, no
any-to-any, servers never get `*` ports or a way to your devices, a comment
above every rule, Kubernetes impersonation limited to the expected groups), runs the
policy's own tests, and compares the policy with an independent allow/deny
table over every source, destination and port. It is not Tailscale: it knows
only the part of the language used here.

When you add a machine: tag it, add the rule and a test in `policy.hujson`,
and the line in `intended()` in `check.py`; the checker fails until all agree.

## Verify first (not confirmed from the docs, nothing tried live)

1. DNS: `micro-edge` (AdGuard) is set by hand as the tailnet nameserver. Your
   own devices reach it (rule 1). Tagged devices do not get port 53 on
   `micro-edge`: the Kumas resolve tailnet names locally, so it should not
   matter. If a tagged device fails to resolve a public name, add a grant
   from that tag to `tag:edge` on `udp:53` and `tcp:53` (with a test).
2. The API proxy port: the cluster docs say `tcp:443` on `oke-free`; the
   operator, ChatOps and `kubectl` have never been run live (untested live).
3. Exit nodes: that rule 3 (`autogroup:internet`) is what the apps need, and
   that micro-edge's subnet route and exit node stay approved after tagging.
4. The Home server itself: the docs list no tailnet device for it, so no
   tag or rule exists. If it is on the tailnet (SETUP-GUIDE mentions ssh on
   `tailscale0`), tag it and add a rule for your ssh.
5. Cluster to ChatOps' ntfy (rule 6): the egress goes through Tailscale serve
   with SNI routing, flagged untested in the cluster docs. The restore test and
   previews use the same path.
6. Phone to laptop (and back) has no rule: the docs never need it. Your own
   devices are not allowed to reach each other under this draft; add a grant
   from `group:owner` to `autogroup:self` if you use that. Taildrop may work
   regardless.
7. Tailscale's test syntax: the `proto` field, a host alias (`vcn`) and a tag
   as a test source or destination, and `sshTests` with an empty `ssh` list
   are written from Tailscale's documentation, not tried. Save shows the exact
   complaint if one is wrong; nothing goes live then.
8. Tag `tag:edge` covers `exit-vps` too, so the Kumas are allowed port 5000 on
   it as well (nothing listens there). Remote Kuma `kuma-oracle` also gets
   port 5000 on `micro-edge` though only `kuma-gcp` uses it.
9. Other devices or other users on the tailnet: anything not named here gets no
   rule at all. Look at the Machines list before step 5 for devices you forgot.
10. Whether the cluster docs' own `chatops` Kubernetes group mapping (RBAC in
    the k8s-free-gitops repo) is already live: this policy only forwards the group
    name.
