# The OKE node image: bumped by pull request, never patched in place

The two worker nodes run an Oracle Linux image that Oracle builds for OKE. They are **not** patched with `dnf`/`yum`
(no OS Management Hub, no unattended updates, no SSH): a newer OS state arrives as a **newer image**, and a pull request
decides when. Everything below is offline-tested only (`scripts/test_node_image_bump.py`, `tofu validate`); the first real
run of the workflow, the real `oci` JSON shapes and a real node replacement have not happened yet.

## How a bump arrives

1. **Pinned image.** `infra/node-image.auto.tfvars` holds `node_image = "<source name>|<image OCID>"` (variable `node_image`).
   `infra/oke.tf` uses it for the node pool. Without the file the code behaves as before (newest image at every apply) and
   `tofu plan` prints a warning (`check "node_image_pinned"`): that is the state until the first run below, because an
   apply today would take whatever Oracle published last and replace the nodes.
2. **Workflow `node-image`** (`.github/workflows/node-image.yml`, every Monday 02:00 UTC or by hand: Actions -> node-image -> Run
   workflow). It makes read-only calls to Oracle (`scripts/node-image-bump.sh`: cluster list, node pool list, node-pool-options
   get), takes the newest aarch64 non-GPU image for the cluster's Kubernetes version (the same filter as `oke.tf`) and compares
   it with the pin:
   - **no pin file yet:** opens a PR "pin the node image to the one the pool runs now". It **changes nothing** in the cluster
     (the plan must show no change to the node pool); it only freezes today's state. Do this first.
   - **pin older than the newest image:** opens a PR "OKE node image <name>" that changes the one line.
   - otherwise nothing.
3. **The PR is the review.** The tofu `plan` job comments the plan on it. A bump PR must show **only** the node pool being
   replaced (`oci_containerengine_node_pool.arm`, node source image). Anything else in the plan: do not merge.
4. **Merge, then apply** (`apply oracle-always-free <code>` in ChatOps `infra`, or Actions -> tofu -> Run workflow -> `apply`), in a quiet hour.

Secret (name only, optional): `NODE_IMAGE_PR_TOKEN`, a fine-grained token with Contents and Pull requests read/write on this repo.
Without it the PR is opened with the default token and GitHub does not start the plan for it: close and reopen the PR once.
The workflow runs on `main`, and on `main` the OIDC login becomes the *apply* user (`bootstrap/identity.tf` maps the `sub` claim,
not the event): that is why the script is read-only and a test lists the only three calls it may make.

## How the pool is replaced (and what that does to your apps)

`infra/oke.tf` has `node_pool_cycling_details { is_node_cycling_enabled = true, maximum_surge = "0", maximum_unavailable = "1" }`.
OKE replaces **one node at a time**: cordon, drain (evictions respect PodDisruptionBudgets), terminate, create a new node on the new
image, wait until it is Ready, then the next. About 10 to 15 minutes per node. `maximum_surge` has to stay 0: the free Arm allowance
is 2 OCPU / 12 GB and the two nodes use all of it, so there is no room for a third node.

What that means, honestly. It is **not** zero downtime for everything:

| Workload | During the replacement |
|---|---|
| Traefik (2 replicas, PDB `maxUnavailable: 1`, spread over the nodes) and cloudflared (2 replicas) | stay up: the tunnel and the front door always have one pod on the other node |
| Everything else (Flux controllers, Kyverno, Prometheus, ntfy-standby, changedetection, previews, ...) runs **once** | restarts on the other node: about 1 to 3 minutes each |
| CPU room | measured 19 Nov 2026: requests are about 535 m and 600 m on the two nodes against 840 m allocatable per node, 1,135 m in total. While one node is out, about 300 m of pods **cannot be scheduled** and stay Pending until the new node is Ready (5 to 10 minutes). Re-measure before an apply: `kubectl describe nodes \| grep -A8 'Allocated resources'` |
| `changedetection` data | **lost for the node that is replaced**: its `local-path` volume is a folder on that node's boot disk (`cluster/apps/changedetection/pvc.yaml`; the history is not backed up, the watches are recreated by the seeder). The pod may stay Pending on the old volume afterwards: if so `kubectl -n changedetection delete pvc datastore` and let Flux recreate it |

So the answer to "without downtime" is: **the front door (Traefik, cloudflared) and Home's apps never go down; the cluster's
single-replica apps restart once and some wait a few minutes for capacity.** Nothing in the free allowance makes that better: a
third node does not fit, and a bigger node shape is not free.

### Before you apply a bump

```bash
kubectl get nodes -o wide                                              # both Ready, same version
kubectl get pdb -A                                                     # Traefik: ALLOWED DISRUPTIONS 1
kubectl get deploy,sts -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas | awk '$3 == 1'   # what restarts
kubectl describe nodes | grep -A8 'Allocated resources'                # the CPU room above
kubectl get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]   # which node holds changedetection's disk
```

(ChatOps `cluster` channel runs the same `kubectl` reads: `nodes`, `pods`, `flux`.) Apply in the evening local time (nothing here
is time-critical), then watch: `kubectl get nodes -w` and the OKE work request (Console -> Containers -> oke-free -> Work requests).

### After

`kubectl get nodes -o wide` shows the new image's kernel and OS version on both nodes; `flux get kustomizations` is all Ready;
`kubectl get pods -A | grep -v Running` is empty after a few minutes. If a node does not come up, the pool keeps the old node
(`maximum_unavailable = 1`): fix or revert the PR (the previous line of `node-image.auto.tfvars`) and apply again.

### Rollback

Revert the PR (restore the previous `node_image` line) and apply: the pool cycles back to the old image, one node at a time, with the
same cost. Oracle keeps older images selectable for a while; if the old one is gone the apply fails at plan time and you pick another
from `tofu output node_image_newest`.

## The Kubernetes version: control plane floats, workers follow the image (2026-11-20)

`kubernetes_version` stays empty on purpose, so the **control plane** takes the newest version Oracle offers at the next apply (v1.37.0 -> v1.37.1 was applied on 2026-11-20 in 8 minutes, nothing restarted). The **node pool** version is read from the pinned image's name (`OKE-1.37.0-...`, `pool_k8s_version` in `oke.tf`): Oracle answers 409 "Cannot update Kubernetes version which has already been set by OKE worker node image" when the two differ. So the workers move only when a node-image pull request changes the image, and that pull request is the one that replaces the nodes (one at a time). The workflow looks for an image for the cluster's version: with the control plane on v1.37.1 it proposes the first v1.37.1 image Oracle publishes. A worker two or three patch versions behind the control plane is normal for Kubernetes.

## What this deliberately does not do

- No `dnf update` on the nodes, no SSH to them, no OS Management Hub agent: a node you can patch by hand is a node that drifts.
- No automatic apply: merging is yours, and the apply is the manual dispatch (the repo's rule).
- It does not touch the Kubernetes version (`kubernetes_version`): that is its own change.
