# Recipes: using the free tiers together

Nine ways to combine what the four sibling repositories build. Each recipe says what you get, which repository and
file provides each piece, how to wire it, what it costs, and what is **not** included. Nothing here is a promise
about the providers' free tiers: limits change, so check each provider's current pricing page before you rely on one
(the repositories carry the limits as they were when written, with their sources in the docs).

The four repositories (all are OpenTofu or Flux code, all meant to be deployed from **your own private copy**):

| Short name | Repository | Provides |
|---|---|---|
| `oracle` | `oracle-always-free` | Oracle Cloud Always Free: network, OKE Basic cluster with 2 Arm nodes, 2 micro VMs, Vault, buckets, quotas, budget, keyless GitHub login |
| `gcp` | `gcp-always-free` | One Google Cloud e2-micro (IPv6 only), keyless GitHub login, budget alerts, billing kill switch, Cloud Build amd64 builds |
| `cloudflare` | `cloudflare-free` | Cloudflare Free plan: tunnel, DNS, Access (login in front of apps), R2 bucket, optional failover Worker |
| `k8s` | `k8s-free-gitops` | What Flux runs on the cluster: ingress, tunnel connector, Tailscale operator, External Secrets, policies, optional previews, monitoring and restore test |

Wording used below: **verified** means the repository's own tests or scripts check it; **not run** means it was
written against the provider's documentation but never applied to a real account by the authors of this
repository (the READMEs say `verify` on such steps). Anything not implemented says so under "Not included".

---

## 1. Arm Kubernetes behind a Cloudflare Tunnel: apps with no public IP and no open ports

**You get:** web apps on a Kubernetes cluster that has no load balancer, no public address and no inbound port. The
only way in from the internet is an outbound connection that the cluster opens to Cloudflare.

**Pieces**
- `oracle`: `infra/network.tf` (private API subnet, private worker subnet behind NAT), `infra/oke.tf` (Basic cluster,
  private API endpoint, 2 Arm nodes).
- `cloudflare`: `infra/tunnel.tf` creates the tunnel, a proxied DNS record `<name>.<your-domain>` for every entry of
  `cluster_hostnames`, and the tunnel's ingress: each name goes to `http://traefik.traefik.svc.cluster.local:80`, everything
  else gets `http_status:404`. `infra/access.tf` puts a one-time-PIN login in front of every private name.
- `k8s`: `infrastructure/controllers/traefik` (the ingress), `infrastructure/controllers/cloudflared` (two connector pods, token
  from the Vault secret `cloudflared-tunnel-token`), `apps/hello` (a sample app with its Ingress).

**Wire it**
1. Deploy `oracle` (cluster), then `cloudflare` (tunnel), following their READMEs.
2. Put the tunnel token into the Vault secret the connector reads. The command is in `cloudflare` `docs/WHAT-YOU-DO.md`
   step 9 (`tofu -chdir=infra output -raw tunnel_token | jq -R '{TUNNEL_TOKEN: .}' | <oracle repo>/scripts/put-secret.sh cloudflared-tunnel-token -`).
3. Add a name: one label in `cluster_hostnames` (`infra/variables.tf`) and an Ingress in `k8s` for `<label>.<your-domain>`
   (see `cloudflare` `docs/HOSTNAMES.md`). Universal SSL covers one level only: `app.example.com`, not `a.b.example.com`.
4. Check: `https://hello.<your-domain>` shows the Access login page; after the PIN it shows the sample app.

**Costs:** Cloudflare Tunnel, DNS and Access (up to 50 users) are free; OKE Basic has no control-plane fee; the nodes are
Always Free Arm. **Not included:** TCP/UDP services (the tunnel config here is HTTP only), a second cluster.

---

## 2. Keyless pipelines: GitHub's login token instead of stored cloud keys

**You get:** CI that never stores an Oracle or Google key. Each job asks GitHub for a signed identity token and swaps it
for a short-lived cloud credential; which credential depends on where the job runs.

**Pieces**
- `oracle`: `bootstrap/identity.tf` makes an identity domain OAuth app, an identity propagation trust, and two service
  users: `<repo>-plan` for `pull_request` runs (read only, cannot read secret contents) and `<repo>-apply` for runs on
  `refs/heads/main`. `scripts/oci-login.sh` swaps the token for a 60-minute session token and refreshes it every 20 minutes.
- `gcp`: `bootstrap/main.tf` makes a Workload Identity pool whose condition accepts only tokens of your repository
  (by numeric repository id), a `tf-plan` service account for any ref of the repo and a `tf-apply` service account that
  only a `workflow_dispatch` run on `refs/heads/main` may use. `.github/workflows/tofu.yml` uses `google-github-actions/auth`.
- Both: the apply is a manual run (`workflow_dispatch`, type `apply`) that applies exactly the plan saved for the current
  `main` commit. The `bootstrap/` stacks (IAM, quotas, budget, buckets) are applied only from your laptop, never by CI.

**Wire it:** `./scripts/bootstrap.sh ...` in each repository creates the trust and sets the GitHub variables for you.

**Limits you should know:** the Oracle OpenTofu state is reached with an S3 key (OpenTofu has no `oci` backend), and
`cloudflare` uses one API token plus R2 keys (Cloudflare has no keyless CI login). So "no stored keys" holds for the
cloud provider logins of `oracle` and `gcp`, not for the state and not for Cloudflare. That is why every deployed copy must be
a **private** repository (see SECURITY.md).

---

## 3. Three-place monitoring with a 2-of-3 rule

**You get:** Uptime Kuma instances in three places, so "the site is down" means two places agree, not one flaky network.

**Pieces included**
- `oracle` `stacks/micro-kuma/` (location `oracle`) and `gcp` `stacks/kuma/` (location `gcp`; identical files, only `.env.example`
  differs). Each stack runs Tailscale (its own tailnet device, UI on the tailnet only), Uptime Kuma 2, AutoKuma (creates
  monitors from JSON files), `sync` (a git checkout of your monitor files over the tailnet, every 10 minutes, which also
  writes a webhook notification named `worker`), and `push` (a heartbeat to your home Kuma every 60 s).
- Kuma's own checks leave through the normal Docker network, never through the tailnet or an exit node, so each location
  really measures from where it runs. On the GCP VM they leave over IPv6 (see the egress budget in the `gcp` design notes).
- The webhook contract: `POST <worker url>/kuma/<location>` with `Authorization: Bearer <KUMA_TOKEN>`.

**Not included:** the third Kuma (at home), the monitor JSON files, a self-hosted ntfy, and the Worker that applies the
2-of-3 rule (it receives each location's up/down event and pages only when two locations agree). Build those yourself:
a Kuma on any home machine, a repository of monitor files, an ntfy server, and a small Cloudflare Worker that stores the
last state per location and sends one notification when two of three disagree with "up". The stacks work without the
Worker (set `KUMA_WORKER_URL` empty: monitors then alert nobody) and the Kuma UI can send to any notification target.

**Costs:** inside the free tiers. The GCP VM has a 1 GB/month egress allowance: do not lower monitor intervals below 600 s
there (`gcp` design notes show the arithmetic). **Status:** the stacks pass `docker compose config` and shellcheck, and `sync.sh` was run against a local git repo.
Treat the full chain (tailnet, git mirror, webhook, heartbeat) as **verify** until you have seen it work on your own account.

---

## 4. A free build farm: amd64 on Google Cloud Build, arm64 on the Arm nodes

**You get:** a Google Cloud Build trigger that builds a `linux/amd64` image for every push to `main` and every tag of repositories
you list, into Artifact Registry (kept under the 0.5 GB free storage by a cleanup policy).

**Pieces included**
- `gcp` `bootstrap/cloudbuild.tf` (APIs, the `images` registry and cleanup policy, build and pull service accounts, an empty
  secret for the GitHub token), `infra/cloudbuild.tf` + `infra/cloudbuild-settings.tf` (2nd-gen GitHub connection, linked
  repositories, two triggers per repository; off while `github_app_installation_id = 0`), `cloudbuild/amd64.yaml`.
- `gcp` `docs/BUILD-FARM.md`: the flow, free limits with their sources, and what was not tested.
- `oracle` `bootstrap/identity.tf` also creates an S3 user and bucket (`zot`) meant for an OCI registry such as Zot.

**Not included (honest status):** the arm64 half. The original design had a CronJob on the Arm nodes build the arm64 image
with BuildKit, push it to a Zot registry stored in Oracle Object Storage and join both images into one multi-architecture tag.
That part was **removed** from `k8s` before publication (the author moved arm64 builds to GitHub Actions and ghcr.io), so the
manifests are not in this repository and `docs/BUILD-FARM.md` describes it as history. If you want one multi-arch tag today,
the simplest way is `docker buildx` in GitHub Actions for both platforms, or to use the Cloud Build half for amd64 only.

**Costs:** Cloud Build 2,500 free build-minutes a month and 0.5 GiB of Artifact Registry storage at the time of writing; the one real cost
is egress when something outside Google pulls images. The billing kill switch (recipe 6) counts it.

---

## 5. Backups that cost nothing: restic to Cloudflare R2 and Oracle, with a restore test

**You get:** two independent places for encrypted backups, inside the free allowances, and a job that proves the backups restore.

**Pieces**
- `cloudflare` `infra/r2.tf`: bucket `backups` (R2 free: 10 GB). `oracle` `bootstrap/main.tf` + `identity.tf`: bucket `backups` and an
  S3 user `s3-backup` limited to it (Always Free object storage: 20 GB for all buckets together, quota-enforced).
- `k8s` `infrastructure/configs/restore-test/` (an **optional** layer, commented out in `infrastructure/configs/kustomization.yaml`):
  a weekly CronJob restores the newest snapshot of one restic repository on R2 into a throwaway Postgres and checks that the data
  looks fresh; a monthly "DR drill" does it the way a real recovery runs and measures the time. Results go to ntfy and, if you set them,
  to healthchecks.io. The credentials come from the Vault secret `restore-test-restore-test`.

**Wire it:** create the bucket keys (`cloudflare` `docs/WHAT-YOU-DO.md` step 11, `oracle` step 6), run restic from your own machine or server against
`s3:<endpoint>/backups/restic/<host>`, then adapt the restore scripts and enable the layer.

**Not included:** the restic backup job itself (it ran on the author's own server). The restore scripts are **specific**: they expect one
database dump at a fixed path inside the snapshot and a table with timestamps. Treat them as a worked example and change
`scripts.yaml` and `dr-drill-scripts.yaml` to your data before you switch the layer on.

**Costs:** free below 10 GB (R2) and 20 GB (Oracle). Above that, R2 bills storage; on Oracle the quota refuses the writes instead
of billing (and your backups then stop: watch the bucket sizes).

---

## 6. Spending guards: quotas, budgets, a billing kill switch

**You get:** three layers that make an accidental bill unlikely, each in code you can read.

- **Oracle, a hard cap by refusal.** `oracle` `bootstrap/variables.tf` (`quota_statements`) zeroes every compute core quota, then sets back
  only the Always Free amounts: 2 Arm cores and 12 GB, 2 micro cores, 200 GB block storage, 20 GB object storage. Anything bigger is refused
  by Oracle, not billed. A budget of 1 (your billing currency) mails you when a charge is forecast at 1 % of it or reached 100 %. Oracle allows one budget per tenancy:
  the bootstrap keeps an existing one.
- **Google, alerts and a kill switch.** `gcp` `bootstrap/main.tf` makes two budgets (spend the free tier does not cover, and use of the
  trial credit) that email you. `bootstrap/killswitch.tf` publishes the "beyond free tier" budget to Pub/Sub; a small Cloud Run function
  (`bootstrap/killswitch/main.py`, with unit tests) unlinks the billing account from the project when spend passes the budget. Everything paid
  then stops, the VM included, until you re-link billing. It is live by default; `kill_switch_dry_run = true` only logs.
- **Cloudflare:** the Free plan has no overage billing for what this repository uses; the failover Worker is limited by the plan's daily request quota.

**What can still cost money:** object storage on Oracle if you remove the quota; Oracle outbound data beyond the free monthly amount; a public IPv4 on
the Google VM (about USD 3.65 a month, which would trip the kill switch: the VM is IPv6 only on purpose); Google egress beyond 1 GB a month; Cloud Build beyond its free minutes;
R2 beyond 10 GB. Budgets are not instantaneous: billing data lags by hours.

**Status:** the quota statement names were corrected against real errors (a regional limit also applies to Arm nodes); the kill switch function has unit tests and was built in a real project once. Treat both caps as a second line of defence, not the first: look at the billing page.

---

## 7. Free observability: Grafana Cloud and New Relic fed from the cluster

**You get:** metrics and logs from the Arm cluster in two hosted free tiers, with the dashboards and alert UI living outside the cluster.

**Pieces (`k8s` `infrastructure/monitoring`, a Flux layer that is **suspended by default**)**
- `kube-prometheus-stack`, slim: Prometheus (3 days, emptyDir), Alertmanager, node-exporter, kube-state-metrics. No Grafana.
- `otel-gateway` (OpenTelemetry Collector): reads a fixed subset of metrics from Prometheus' federation endpoint plus OTLP from apps,
  receives pod logs from `otel-logs` (a DaemonSet), and exports each signal once to Grafana Cloud (OTLP gateway) and once to New Relic.
- Credentials come from the Vault secret `monitoring-otel-credentials` (keys `GRAFANA_CLOUD_OTLP_ENDPOINT`, `GRAFANA_CLOUD_INSTANCE_ID`,
  `GRAFANA_CLOUD_TOKEN`, `NEW_RELIC_OTLP_ENDPOINT`, `NEW_RELIC_LICENSE_KEY`); `docs/WHAT-YOU-DO.md` step 20 says where to find each.

**Wire it:** create the two accounts, write the secret with `put-secret.sh monitoring-otel-credentials`, edit the Alertmanager receiver in
`kube-prometheus-stack.yaml` (the shipped one points at the author's own ntfy and must be replaced), then set `suspend: false` on the
`infra-monitoring` Kustomization in `clusters/oke/infrastructure.yaml`.

**Costs:** free tiers only, with ingest caps of the vendors; keep the label set small. The layer requests about 0.9 GB of memory on the nodes.
**Not run:** the exporters were configured against the vendors' documentation; check ingestion in both consoles after the first sync.

---

## 8. Preview environments from pull requests

**You get:** a labelled pull request in an app repository gets its own namespace, a hostname `pr-<n>-<app>.<your-domain>` behind Access,
a smoke test, and everything is deleted when the pull request closes or loses its label.

**Pieces**
- `k8s` `infrastructure/configs/previews/` (an **optional** layer, commented out in `infrastructure/configs/kustomization.yaml`): a
  `ResourceSetInputProvider` per app repository lists open pull requests with the label `preview` every 5 minutes; a Flux `ResourceSet`
  turns each into the namespace `pr-<n>`, a Deployment (`<image>:pr-<n>`), a Service, an Ingress, and a smoke-test Job per commit that calls `/`
  and the health path with a Cloudflare Access service token. `docs/examples/preview-provider.yaml` is the opt-in template,
  `scripts/testdata/preview-inputs.yaml` the mock input that `scripts/validate.sh` renders.
- `cloudflare`: `enable_preview_dns = true` adds a wildcard CNAME and tunnel rule; the Access app `pr-*` and the service token `ci-smoke-tests`
  are in `infra/access.tf`.

**Wire it:** `k8s` `docs/WHAT-YOU-DO.md` section 16. Your app's CI must push an arm64 image tagged `pr-<number>` for every pull-request push.

**Costs:** CPU and memory of the two Arm nodes (a preview is a normal Deployment: keep limits small); no extra service. **Not run:** the generated
manifests are rendered and schema-checked by CI with mock pull requests, but no live preview has been created by the authors.

---

## 9. A tiny private DNS and ad-blocking node on a micro, with Tailscale as exit node and subnet router

**You get:** one micro VM that blocks ads and trackers for every device on your tailnet, can be your exit node, and lets your laptop reach the
private subnet of the cloud network without a Bastion.

**Pieces (`oracle` `stacks/micro-edge/`, started by cloud-init, no secret needed)**
- Tailscale in kernel mode in its own network namespace: exit node and subnet router for the VCN range (`10.0.0.0/16`).
- AdGuard Home inside that namespace, so it answers on tailnet addresses only. Its full configuration (blocklists included) is in git
  (`adguard/AdGuardHome.yaml`); `scripts/micro-edge-adguard.sh push` applies it, restarts only AdGuard, and rolls back if it was killed for memory.
- A read-only pull-through cache of ghcr.io on port 5000 (it exists so the IPv6-only Google VM can pull from ghcr.io).
- `tailscale/policy.hujson` is a **draft** tailnet policy with tags and a reason above every rule, with an offline checker (`tailscale/check.py`, run by CI).
  It is not applied for you: `tailscale/README.md` has the steps and the rollback.

**Wire it:** `oracle` `docs/WHAT-YOU-DO.md` steps 10 to 12 (create the micros, reach one through the Bastion, log in to Tailscale, approve the route and exit
node in the Tailscale admin console, disable key expiry, finish AdGuard's setup wizard).

**Lessons from the real run:** AdGuard was killed for memory 21 times with nine blocklists (about 2 million rules) on a 256 MB cap; two lists
(about 400 000 rules) fit, so `apply.sh` refuses more than three enabled lists. The micros have no swap, so every container has a memory cap.
**Costs:** two AMD micro VMs are Always Free; capacity is the limit ("Out of host capacity" is common: try again later).
