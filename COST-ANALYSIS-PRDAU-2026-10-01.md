# Materialize on AKS — PROD (prdau) Cost Analysis

**Scope:** Reporting only. No changes were made to Azure or Materialize.
**Subscription:** `4ed507aa-62d6-4499-9e25-56253d723f46`
**Resource groups analyzed:**
- `SGPRDAU-MATERIALIZE-RESOURCES` (control-plane RG: AKS cluster object, Postgres, Storage, Key Vault)
- `MC_SGPRDAU-MATERIALIZE-RESOURCES_sgprdau-materialize-aks_australiaeast` (AKS-managed node RG: VMs, disks, internal LB)

**Sources used:**
- Live Azure state via Azure Resource Graph (queried 2026-10-01)
- Azure Retail Prices API (`prices.azure.com`), region `australiaeast`, USD, queried 2026-10-01
- Materialize official Azure deployment guidelines (`materialize-docs` skill)
- `azure/examples/simple/terraform-prdau.tfvars` and module defaults in this repo
- INFRA team's `Materialize Cost Estimates_PROD.xlsx` — **could not be parsed** (see [Cross-check vs INFRA estimate](#cross-check-vs-infra-estimate) at the end). Numbers below are independently derived from live Azure state + public retail pricing, not copied from the spreadsheet.

> All $ figures are **USD**, on a **730 hours/month** basis, **today's live resource sizes** (not the not-yet-applied tfvars changes — see the Postgres drift note below). **AUD figures shown in parentheses use a fixed conversion rate of 1 USD = 1.44 AUD**, per your instruction — not a live/floating FX pull.

---

## 1. What's actually running today (live Azure state)

| Resource | Where | Live SKU / size | Count |
|---|---|---|---|
| Materialize node pool (VMSS) | `MC_..._aks_australiaeast` | `Standard_E32pds_v6` (32 vCPU / 256 GiB / 1,200 GiB local NVMe) | **2 nodes** |
| System/default node pool (VMSS) | `MC_..._aks_australiaeast` | `Standard_D4pds_v6` (4 vCPU / 32 GiB) | **2 nodes** |
| AKS cluster | `SGPRDAU-MATERIALIZE-RESOURCES` | `sgprdau-materialize-aks`, k8s 1.34.10, **Standard** SKU tier | 1 |
| PostgreSQL Flexible Server (metadata DB) | `SGPRDAU-MATERIALIZE-RESOURCES` | `Standard_E4ds_v5` (Memory Optimized, 4 vCore/32 GiB), **32 GB storage, P20 tier**, HA disabled | 1 |
| Storage account (persist/blob backend) | `SGPRDAU-MATERIALIZE-RESOURCES` | `sgprdaumaterializestg`, **Premium_LRS**, BlockBlobStorage kind | 1 |
| Internal Standard Load Balancer | `MC_..._aks_australiaeast` | `kubernetes-internal`, Standard SKU, no public IP | 1 |
| Managed disks (PVCs) | `MC_..._aks_australiaeast` | 2× StandardSSD_LRS, **10 GB** and **100 GB** | 2 |
| Key Vault | `SGPRDAU-MATERIALIZE-RESOURCES` | Standard | 1 |



### Materialize clusters 

| Cluster | Replicas | Size (cc) | vCPU | Memory |
|---|---|---|---|---|
| ar_serving | 1 | 100cc | 2 | ~15.16 GiB |
| ar_transform | 1 | 600cc | 12 | ~90.97 GiB |
| ingest_cluster_miles | 1 | 100cc | 2 | ~15.16 GiB |
| peopleorg_serving | 1 | 100cc | 2 | ~15.16 GiB |
| peopleorg_transform | 1 | 100cc | 2 | ~15.16 GiB |
| vehicle_contract_serving | 1 | 100cc | 2 | ~15.16 GiB |
| vehicle_contract_transform | 1 | 100cc | 2 | ~15.16 GiB |
| **Subtotal (user clusters)** | | **1,300cc** | **26 vCPU** | **~197.6 GiB** |
| + `mz_catalog_server`/system clusters (not shown in screenshot, typically small) | 1 | ~50–100cc | ~1–2 | ~8–15 GiB |
| + `environmentd` (dedicated request, same tainted node pool) | — | — | **7 vCPU** | **16 GiB** |

cc→resource mapping used (Materialize's fixed 1:8 vCPU:GiB ratio): **50cc = 1 vCPU / ~7.58 GiB**, confirmed via `mz_cluster_replica_sizes` in an earlier session on this same deployment family.

**Capacity used vs. provisioned:** ~34 vCPU / ~220 GiB in use out of **64 vCPU / 512 GiB** provisioned (2× E32pds_v6) → **~53% CPU / ~43% memory headroom** on the Materialize pool today.

---

## 2. Cost breakdown — what each component contributes

All VM prices are **on-demand Linux, australiaeast**, pulled live from the Azure Retail Prices API.

| Component | Qty | Unit price (on-demand) | Monthly (on-demand) | Monthly (1-yr reserved) | Monthly (3-yr reserved) |
|---|---|---|---|---|---|
| Materialize node pool — `E32pds_v6` | 2 nodes | $2.333/hr (A$3.36/hr) | **$3,406 (A$4,905)** | $2,010 (A$2,894) | $1,294 (A$1,863) |
| System node pool — `D4pds_v6` | 2 nodes | $0.229/hr (A$0.33/hr) | **$334 (A$481)** | $197 (A$284) | $127 (A$183) |
| AKS Standard SLA (control plane) | 1 cluster | $0.10/hr flat (A$0.14/hr) | **$73 (A$105)** | *(not reservable — flat meter)* | *(not reservable)* |
| PostgreSQL compute — `Standard_E4ds_v5` | 4 vCore | $0.15/vCore-hr (A$0.22/vCore-hr) | **$438 (A$631)** | $263 (A$379) | $175 (A$252) |
| PostgreSQL storage (32 GB, live P20) | 32 GB | $0.138/GB-mo (A$0.20/GB-mo) | **$4.42 (A$6.37)** | *(not reservable)* | *(not reservable)* |
| Blob storage (Premium LRS, persist backend) | ~6–10 GB observed | $0.218/GB-mo (A$0.31/GB-mo) | **~$2 (A$3)** | *(not reservable)* | *(not reservable)* |
| Managed disks (2× StandardSSD_LRS PVCs, 10+100 GB) | 2 disks | ~E2/E6 tier | **~$12 (A$17)** | *(not reservable)* | *(not reservable)* |
| Internal Standard LB (no public IP) | 1 | data-processed only, ~$0.005/GB (A$0.007/GB) | **~$2–5 (A$3–7)** | *(not reservable)* | *(not reservable)* |
| Microsoft Defender for Containers (All Features Enabled) | 1 subscription | confirmed via Azure Pricing Calculator | **$424.53 (A$611.33)** | *(not reservable — SaaS meter)* | *(not reservable)* |
| **Total (infra + Defender)** | | | **≈ $4,695/mo (A$6,760)** | **≈ $2,985/mo (A$4,297)** (−36%) | **≈ $2,105/mo (A$3,030)** (−55%) |

**Reservation discount actually computed from live retail pricing** (not assumed): **~41% at 1-year, ~62% at 3-year** on the VM/Postgres compute itself, consistent across every VM family and Postgres family checked (E32pds_v6, E16pds_v6, D4pds_v6, Edsv5) — close to the "~38% / ~61%" rule of thumb you quoted. **The blended total-line savings above (36%/55%) are lower than that** purely because Defender for Containers is a flat SaaS meter that gets **no reservation discount at all** — it costs the same $424.53 (A$611.33)/month whether the underlying VMs are on-demand or 3-year reserved, so it drags down the overall % as reservation coverage grows.

### Microsoft Defender for Containers — confirmed cost (Azure Pricing Calculator)
**Confirmed: $611.33 AUD/month** (≈ $424.53 USD/month at the 1.44 rate) for **Defender for Containers with All Features Enabled** — this replaces the earlier Resource Graph-based estimate (~$494 USD / A$711, computed from a flat $0.00941/vCore-hour assumption across 72 vCPUs), now confirmed against the actual Azure Pricing Calculator output instead of an inferred per-vCore rate.

**Optimization angle, now that the number is confirmed:** "All Features Enabled" is a toggle, not a fixed price — Defender for Containers bills separately for sub-capabilities (e.g. agentless discovery/posture, registry vulnerability scanning, runtime threat detection/Defender agent). If any of those aren't required for this subscription's compliance posture, disabling them in **Microsoft Defender for Cloud → Environment settings → Containers** would reduce the $611.33 (A$)/month below the "all features" figure — worth a follow-up with whoever owns the Defender for Cloud policy for this subscription to confirm which sub-features are actually mandated vs. just defaulted on.

---

## 3. How much of the VM cost does each cluster "cause"?

The Materialize node pool is bought in whole-node (whole-VM) units, not per-vCPU — so cost attribution is really "share of provisioned capacity," not a true variable cost. Treating the $3,406/month (A$4,905/month, on-demand) Materialize-pool bill as **proportional to vCPU reserved**:

| Cluster | vCPU | % of 34 vCPU in use | Attributed $/month (of $3,406 / A$4,905) |
|---|---|---|---|
| ar_transform (600cc) | 12 | 35% | **~$1,202 (A$1,731)** |
| environmentd (dedicated) | 7 | 21% | **~$701 (A$1,009)** |
| ar_serving (100cc) | 2 | 6% | **~$200 (A$288)** |
| ingest_cluster_miles (100cc) | 2 | 6% | **~$200 (A$288)** |
| peopleorg_serving (100cc) | 2 | 6% | **~$200 (A$288)** |
| peopleorg_transform (100cc) | 2 | 6% | **~$200 (A$288)** |
| vehicle_contract_serving (100cc) | 2 | 6% | **~$200 (A$288)** |
| vehicle_contract_transform (100cc) | 2 | 6% | **~$200 (A$288)** |
| mz_catalog_server + overhead (~1 vCPU) | 1 | 3% | **~$100 (A$144)** |
| **Unused headroom (30 of 64 vCPU)** | 30 | — | **~$1,600 (A$2,304) of the $3,406 (A$4,905) is currently idle headroom**, not attributable to any cluster |

**Key takeaway:** nearly half of the Materialize-pool spend is currently *idle capacity*, not active cluster cost — this is normal (you provision ahead of the next 1–2 domains, and a single replica can't straddle two nodes), but it's also exactly why the next new domain below is close to free.

---

## 4. Cost to onboard a new domain (50cc transform + 50cc serving)

- **50cc + 50cc = 100cc = 2 vCPU total**, ~15.16 GiB combined memory.
- Current spare capacity on the 2-node Materialize pool: **~30 vCPU / ~290 GiB** free.
- **This fits entirely within existing, already-paid-for headroom.** Marginal infrastructure cost ≈ **$0/month** — no new node is triggered.
- **The real economics are a step function, not linear.** Keep adding ~100cc domains and the pool eventually crosses 64 vCPU (roughly 5–6 more 100cc domains, depending on what else grows), at which point the cluster autoscaler adds a **3rd `E32pds_v6` node in one jump**: **+$1,703/month on-demand (A$2,452/month)** (+$1,005/mo at 1-yr reserved / A$1,447, +$647/mo at 3-yr reserved / A$932) for that single step — not a smooth per-domain increment.
- **Rule of thumb for budgeting:** treat new 50+50cc domains as free *until* a Portal/kubectl check shows the pool is within ~1 node's capacity of the ceiling, then budget a full extra node, not a prorated slice of one.

---

## 5. Max cc per cluster, and the AR 800cc question

A Materialize cluster **replica cannot span two nodes** — one replica's pod must fit on a single node. So the real ceiling is: *(node vCPU) − (AKS/system overhead) − (anything else co-scheduled on that same node, chiefly `environmentd`'s 7 vCPU request)*.

| Node SKU | Total vCPU | Minus ~2 vCPU AKS/system overhead | Minus `environmentd` (7 vCPU) if co-located | Safe max single-replica size |
|---|---|---|---|---|
| `Standard_E16pds_v6` (16 vCPU) | 16 | 14 | **7** → **~350cc** | Matches why 600cc (12 vCPU) was already tight/risky on E16 — 12+7=19 > 16 |
| `Standard_E32pds_v6` (32 vCPU, **what's live today**) | 32 | 30 | **23** → **~1,150cc** | Comfortably covers 600cc today (12+7=19 of 32) |

**Your recollection is correct for E16, but you're already on E32.** On `Standard_E32pds_v6`:
- Current `ar_transform` at 600cc (12 vCPU) + `environmentd` (7 vCPU) = 19 of 32 vCPU, even in the worst case where Kubernetes schedules both on the same node.
- Bumping `ar_transform` to **800cc (16 vCPU)**: 16 + 7 = 23 of 32 vCPU — **still fits with ~9 vCPU of headroom**, no node resize or new node needed.
- You could safely push a single replica up to roughly **1,000–1,100cc** (20–22 vCPU) before co-location with `environmentd` becomes the binding constraint on an E32 node, and further than that if the scheduler happens to place `environmentd` on the other node (not guaranteed, so don't plan around it).

**Bottom line: the "16-core → max 600cc" ceiling you remembered is real, but it describes `E16pds_v6`, which this environment moved away from precisely because of that limit.** On the currently-deployed `E32pds_v6`, 800cc for `ar_transform` is already safe today with no infrastructure change.

---

## 6. Is there a cheaper VM series? (cross-checked against Materialize's own guidance)

**Short answer: no, not for the Materialize-dedicated pool — `Epdsv6` is already Materialize's own documented recommendation for Azure production.** From Materialize's official Azure deployment guidelines:

> "When operating on Azure in production, we recommend **Epdsv6 sizes** ... with Local NVMe Disk." Recommended ratio: **1:8 vCPU-to-GiB** (memory-optimized), **≥2:1 local-disk-to-memory** for swap.

- `Standard_E32pds_v6` is exactly this family. Switching to a non-memory-optimized, non-NVMe family (e.g. `Dpdsv6`, 1:8 vCPU:GiB only up to `D` series' lower RAM ratio, or a `D`/`F` series at 1:4 or 1:2) would **under-provision memory per vCPU for Materialize's in-memory arrangements** and risks OOM under load — explicitly against vendor guidance, not recommended regardless of the $/hr saving.
- Checked **newer vs. older generation pricing directly** (this is worth knowing, it's counter-intuitive): `D4pds_v6` (currently used for the *system* pool) at **$0.229/hr (A$0.33/hr) is already cheaper** than `D4s_v5` ($0.24/hr / A$0.35/hr) or `D4ds_v5` ($0.284/hr / A$0.41/hr) in `australiaeast` — newer-generation v6 SKUs here are *not* a premium over v5, they're actually slightly cheaper. There is **no cheaper-but-still-adequate alternative** found for either pool via a straight VM-family swap.
- **The only VM-series lever worth taking seriously for the *system* pool** (not Materialize-dedicated — this pool just runs `cert-manager`/`coredns`/the operator, nothing memory-bound) is `Standard_D4as_v5` (AMD, no Premium Storage/local NVMe) at $0.216/hr (A$0.31/hr) vs. the current $0.229/hr (A$0.33/hr) — a **$0.013/hr × 2 nodes × 730h ≈ $19/month (A$27/month)** saving. Marginal; probably not worth the SKU-family change for A$27/month.

**Where the real savings are: Reserved Instances / Savings Plans (§2), not a cheaper VM family.** 1-year reservations save ~40% and 3-year save ~61% on every compute meter in this deployment (VMs and Postgres alike), with zero architecture change required.

---

## 7. Other optimization opportunities found

1. **Reserve now, on both the Materialize pool and the system pool.** At 1-year terms alone this is **~$1,710/month saved (A$2,462)** ($4,270 → $2,560, i.e. A$6,149 → A$3,686) with zero risk, since this is a steady-state production deployment, not a short-lived POC. 3-year terms save **~$2,590/month (A$3,730)** if you're confident in the 3-year horizon.
2. **Microsoft Defender for Containers is confirmed at $424.53/month (A$611.33), "All Features Enabled."** This is now the single largest non-reservable line item in the whole bill (bigger than the system node pool). Review with whoever owns Defender for Cloud policy whether every sub-feature (agentless discovery, registry scanning, runtime threat detection) is actually required — turning off any non-mandated ones is the most direct way to cut this specific line, since it gets zero benefit from VM/Postgres reservations.
3. **Autoscaler ceiling risk, not a cost saving but a budgeting flag:** both node pools have `max_nodes = 5` (Terraform default, not overridden in `terraform-prdau.tfvars`). If load ever pushes either pool to its ceiling, Materialize-pool cost alone could reach **5× $2.333/hr ≈ $8,516/month on-demand (A$12,263/month)** — budget-holders should know the ceiling, not just the current 2-node cost.
4. **Reconcile the Postgres tfvars-vs-live drift** (P20 live vs. P30 declared) before the infra team's estimate cites one or the other — they're not the same monthly figure (storage alone: 32GB×$0.138=$4.42 either way since Flexible Server storage billing is flat-per-GB regardless of P-tier label in this storage mode, but make sure the *provisioned size* doesn't silently change on next apply).
5. **PVC sizing:** the two `StandardSSD_LRS` PVCs are small (10 GB, 100 GB) — not a meaningful cost lever, flagged only for completeness.

---

## 8. Node count vs. Materialize replication — a clarification for the report

Two unrelated "2"s in this deployment, worth stating explicitly so the cost model isn't double-counted or misread:

| | What it is | Live value | Cost impact |
|---|---|---|---|
| **AKS node pool size** | `materialize_node_pool_min_nodes` / `default_node_pool_min_count` (Terraform **defaults**, not overridden in `terraform-prdau.tfvars`) | **2 nodes**, confirmed live on both VMSS, sitting at the autoscaler floor | Direct — this is *why* you're paying for 2× the VM rate per pool today |
| **Materialize `REPLICATION FACTOR`** | SQL-level, per-cluster HA duplication | **1** for every cluster shown in the screenshot ("Replicas" column) | None currently — no HA duplicate compute is running |

`default_node_pool_max_pods = 30` is a **kubelet pod-density cap, not a billed resource** — Azure bills per node/VM, never per pod. It was raised from 15 solely to stop Defender/`coredns-custom` DaemonSet pods from being `Pending` on the **system** pool; it has no cost effect on the Materialize pool, which is never pod-count constrained (a few large pods, not many small ones).

---

## 9. Deep dive: `min_nodes = 2` — can non-prod run on 1 node, and what would break

There are actually **two separate `min_nodes=2` settings**, in different states of parameterization today:

| Pool | Setting | Where it lives | Already overridable per-environment? |
|---|---|---|---|
| **Materialize-dedicated pool** | `materialize_node_pool_min_nodes` | `azure/examples/simple/variables.tf` — a real **variable**, default `2` | **Yes** — just set `materialize_node_pool_min_nodes = 1` in a non-prod `.tfvars`, no code change needed |
| **System/default pool** | `default_node_pool_min_count` | **Hardcoded literal `2`** directly in `azure/examples/simple/main.tf` (not wired to any variable) | **No** — would need a small module change (add a variable, thread it through) before any `.tfvars` file could set it to `1` |

### Straight cost saving of going to 1 node
Steady-state saving is simply one fewer VM on whichever pool you shrink — e.g. on `prdau`'s current SKUs: dropping the Materialize pool from 2→1 `E32pds_v6` saves **$1,703/month on-demand (A$2,452/month)** ($2.333/hr × 730h); dropping the system pool from 2→1 `D4pds_v6` saves **$167/month (A$240/month)**. A non-prod environment would typically also run a *smaller* VM size on top of this, compounding the saving — but the **node-count** saving itself is independent of which VM size you pick.

### What actually breaks (or gets riskier) at 1 node — this is the part that matters more than the $ saving

**1. Blue-green rollouts need headroom for two generations to coexist, briefly.**
Per this repo's own documented operational notes: any Materialize CRD change that triggers a rollout (`forceRollout`, a version bump, certain system-parameter changes) spins up a **full new "generation"** of `environmentd` **and every compute replica pod** *alongside* the still-running old generation, and keeps both running for a **10-minute stability window** before promoting the new one and tearing down the old. For that window, the node pool needs roughly **double** the steady-state capacity it normally uses.
- **With `min_nodes=1` but autoscaling left *enabled* and `max_nodes ≥ 2`:** this still works, but every single rollout now *always* forces a scale-up event (1→2+ nodes) that wasn't previously needed, adding **Azure VMSS node-provisioning latency (typically ~2–5 minutes: VM boot, local NVMe attach, taints/labels, image pull)** stacked in front of the existing 10-minute stability wait. You also briefly pay for 2 nodes during every deploy — so a non-prod environment that deploys/alters clusters often won't actually keep the full steady-state saving; it trades a *permanent* 2nd node for a *frequent temporary* one.
- **With a hard fixed `node_count=1` and autoscaling *disabled*:** this is the risky option. There is no mechanism to add capacity at all, so the new generation's pods get stuck `Pending` with the exact same `Insufficient cpu`/`Insufficient memory` signature already seen in this repo's history when the VM *size* was too small — except now it's the node *count* that's insufficient, not the size. Because the old generation only tears down **after** the new one proves healthy, this is a **deadlock**: the rollout can never complete on its own, and someone has to notice and manually scale the pool before it unsticks. Do not disable autoscaling on a 1-node pool that anyone will run `ALTER CLUSTER`/version rollouts against.

**2. Cluster/replica resizing (`ALTER CLUSTER ... SIZE`) likely follows the same create-before-drop pattern.** Resizing a single cluster's replica to a new `cc` size is a smaller-scale version of the same problem — Materialize brings up the new-size replica before dropping the old one, so it briefly needs room for **both the old and new replica of that one cluster** at once. Same consequence as above, just scoped to one cluster instead of the whole environment: fine with autoscaling enabled (brief burst + latency), risky/stuck with a hard fixed count.

**3. Single node = single point of failure for whatever's on it, independent of rollouts.** Any Azure platform maintenance reboot, local-NVMe hardware fault, or node-image auto-upgrade (all of which already happen periodically on this cluster per prior session logs) takes down **everything scheduled on that one node** simultaneously until it's back:
 - On the **Materialize pool**: every cluster's compute replica, `environmentd`, `balancerd`, and `console` that happen to be on that node go down together — with `REPLICATION FACTOR=1` on every cluster today, this is a real full outage of whatever's on that node, not just a degraded-redundancy event (note this risk already exists today regardless of node count, since 1 replica per cluster has no redundancy either way — going to 1 node doesn't create this risk, it just removes the *chance* that a reboot only hits half your clusters instead of all of them).
 - On the **system pool**: `coredns`, `cert-manager`, Defender agents, and the **Materialize operator itself** all go down together. `coredns` being down briefly breaks cluster-wide DNS resolution (including egress to Postgres/Blob Storage hostnames) — a real availability concern, not just a deploy-time inconvenience. The operator being down blocks *new* rollouts/CRD changes but does not affect already-running environmentd/compute pods.

### `default_node_pool_min_count` specifically — what it does, the real saving, and the real risk

Since this one came up directly: **what it does** — it's the AKS cluster-autoscaler **floor** for the **system/default node pool** (the untainted pool that runs everything *except* Materialize's own compute). Unlike `materialize_node_pool_min_nodes`, this one is **hardcoded as a literal `2`** directly in `azure/examples/simple/main.tf` (`default_node_pool_min_count = 2`), not wired to any variable — so there's currently no `.tfvars` knob for it at all; making it `1` for non-prod means adding a variable and threading it through first, a small code change, not a one-line tfvars edit.

**What's actually running on this pool today** (confirmed by reading the module wiring, not guessed): `coredns`/`coredns-custom`, `cert-manager`, the **Materialize operator**, Azure Policy/Gatekeeper, Microsoft Defender's node daemonsets, the Azure Monitor agent — **and, confirmed just now, Prometheus server + Grafana are also explicitly pinned here** (`node_selector = local.generic_node_labels` in both the `module "prometheus"` and `module "grafana"` blocks in `main.tf` — the same label used for `default_node_pool_node_labels`). That matters because Prometheus in this environment isn't a trivial pod: it's sized at **1 vCPU request / 2 vCPU limit, 2Gi/4Gi memory** specifically to handle this deployment's 300–600cc clusters' scrape cardinality — a meaningful chunk of a 4-vCPU `D4pds_v6` node all on its own, on top of everything else in that list.

- **Cost saving:** same figure as already computed above — dropping this pool 2→1 `D4pds_v6` saves **$167/month on-demand (A$240/month)**, or less at reserved rates.
- **Risk #1 — this is a capacity question, not just an HA question, and it's genuinely closer to the edge than the Materialize pool's math.** Rough-summing typical requests for everything above (Prometheus ~1 vCPU, Grafana ~0.25 vCPU, cert-manager/coredns/operator/Azure Policy/Defender/AMA agent collectively perhaps another ~1–1.5 vCPU) lands in the ballpark of **~2.5–3 vCPU of requests** against a 4-vCPU node's **allocatable** capacity (which is itself less than 4 vCPU once AKS's own system-reserved overhead is subtracted) — plausible to fit on 1 node, but with much less margin than a back-of-envelope "4 vCPU is plenty" assumption would suggest, and **this estimate is not a live measurement**. **Before shrinking this pool, run `kubectl describe nodes` / `kubectl top pods -A --field-selector spec.nodeName=<system-node>` to get the real current request/usage total** — don't commit to 1 node on the estimate above alone.
- **Risk #2 — broader single-point-of-failure blast radius than the Materialize pool.** A reboot/maintenance event on this one node takes out `coredns` (cluster-wide DNS), the Materialize operator (blocks new rollouts, doesn't affect already-running compute), **and now also your entire Prometheus+Grafana monitoring stack** — meaning you'd lose observability at exactly the moment something else might also be going wrong. This is a different (and arguably more disruptive day-to-day) risk profile than the Materialize pool's blue-green rollout/resize concern from point 1 above.

### Recommendation
For a genuinely low-traffic, infrequently-changed **non-prod** environment, `materialize_node_pool_min_nodes = 1` is a reasonable cost lever **as long as autoscaling stays enabled** (`materialize_node_pool_auto_scaling_enabled = true`, the default) **with `max_nodes` left at ≥2** — you get the steady-state 1-node price most of the time and the pool simply bursts to 2 nodes automatically (with a few minutes' added latency) whenever a rollout or `ALTER CLUSTER ... SIZE` needs the headroom. Avoid disabling autoscaling with a hard `node_count=1` — that configuration can deadlock a rollout entirely. **For `default_node_pool_min_count` (the system pool), treat it as the lower-priority/higher-friction change of the two**: it needs a code change just to become configurable, the dollar saving is smaller ($167/mo vs. $1,703/mo), and — now that Prometheus/Grafana are confirmed to live there too — it's worth an actual `kubectl` capacity check before assuming 1 node is safe, even for non-prod.

---

## Cross-check vs. INFRA estimate

The attached `Materialize Cost Estimates_PROD.xlsx` **could not be read** — only a binary file header was available in this session (no cell/sheet content), so the numbers above are **independently derived**, not reconciled line-by-line against the spreadsheet yet.

**To finish the cross-check, please either:**
1. Save the spreadsheet into the repo workspace (e.g. `temp/Materialize Cost Estimates_PROD.xlsx`) so it can be opened directly, or
2. Paste the key totals/line items (even just the per-resource-group monthly totals) here.

Everything else in this report (live resource inventory, retail pricing, cc→vCPU mapping, Materialize's own VM guidance) is sourced directly from Azure and Materialize's own documentation, not from the spreadsheet — only the final side-by-side reconciliation is still pending.

---

## Assumptions & caveats

- **AUD conversions use a fixed rate of 1 USD = 1.44 AUD** (as instructed), not a live/floating FX rate — re-derive if you need figures pegged to a specific billing date's actual rate.
- 730 hours/month used throughout (365×24/12) for on-demand monthly conversions.
- Reserved-instance monthly figures are the *term total ÷ term months* (e.g. 1-yr total ÷ 12), not a separate retail monthly meter.
- Per-cluster $ attribution in §3 is **proportional to vCPU reserved**, since Azure bills per node, not per pod/cc — treat it as a cost-allocation convention, not a literal metered charge.
- Blob storage and LB figures are approximate (based on data volumes referenced in prior session notes for this deployment family, not a fresh metering pull) — flagged inline, not material to the overall total.
- Defender for Cloud's exact pricing tier (Free vs. Standard) could not be confirmed via Resource Graph in this session — treat the $494/month figure in §2 as conditional until verified in the Portal.
