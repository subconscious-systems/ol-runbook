# GPU deployment

Install path for SGLang workers on a customer GPU host. Everything is in this file.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian, NVIDIA GPUs (4× L4 for 27B; 2+ for 7B) |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable (typically EKS) |
| [Distr](https://app.distr.sh) account | Subconscious provisions the SGLang worker Helm application |
| Distr registry access | Profile enables `distrPullSecret` for `registry.distr.sh/subconscious/timrun` |

## Install checklist

| Step | Where | What |
|---|---|---|
| **1** | GPU host | `./dependencies.sh` — k3s, NVIDIA drivers, device plugin |
| **2** | Distr UI | Connect k3s agent to this host |
| **3** | Dashboard + Distr | Create worker API key → Distr Hub Secret `WORKER_API_KEY` |
| **4** | Distr UI | Apply — paste `profiles/<model>.yaml`, set namespace + timeout |
| **5** | AWS Console | NLB + target group per worker NodePort |
| **6** | Dashboard | Register worker pool with NLB URLs + same `WORKER_API_KEY` |

Helm values live in **`profiles/`** only (one YAML per model). There is no separate overrides folder.

---

## Pick a model

| Model | Paste into Distr | Namespace | Timeout | NodePorts |
|---|---|---|---|---|
| Qwen3.6-27B-FP8 | `profiles/qwen36-27b.yaml` | `sglang-qwen36-27b` | 120m | 30001, 30002 |
| Qwen3.6-7B-FP8 | `profiles/qwen36-7b.yaml` | `sglang-qwen36-7b` | 60m | 30003, 30004 |

Copy the **entire file** into Distr Helm Values (step 4).

---

## Step 1 — Bootstrap the GPU host

`dependencies.sh` is self-contained — step 1 only needs that one file. Profiles (`profiles/*.yaml`) are for Distr Apply in step 4.

**Option A — clone the runbook (recommended)**

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/gpu-deployment
chmod +x dependencies.sh
./dependencies.sh
```

**Option B — copy just the bootstrap script**

From your laptop (same directory as this README):

```bash
scp gpu-deployment/dependencies.sh admin@<GPU_HOST>:~/
```

On the GPU host:

```bash
chmod +x ~/dependencies.sh
~/dependencies.sh
```

Use your instance SSH user and key (e.g. `admin` on Debian, `-i ~/.ssh/your-key.pem`).

May reboot once for NVIDIA drivers. Then verify:

```bash
nvidia-smi
kubectl get nodes
```

---

## Step 2 — Connect Distr

In Distr, add a **Kubernetes deployment target** for this host and run the k3s agent install command.

---

## Step 3 — Worker API key

1. **api-gateway dashboard** → model group for your served model (`qwen3.6-27b` or `qwen3.6-7b`) → create **worker API key**.
2. **Distr → Hub Secrets** → `WORKER_API_KEY` = that key.

---

## Step 4 — Distr Apply

Profile YAML lives in `profiles/` in this repo. If you only copied `dependencies.sh` in step 1, clone or copy the profile you need now:

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
# or: scp ol-runbook/gpu-deployment/profiles/qwen36-27b.yaml admin@<GPU_HOST>:~/
```

1. Open the SGLang worker Helm application in Distr.
2. **Create Deployment** → paste the profile YAML from the table above.
3. **Customize Helm options** — namespace and timeout from the table; **120m** / **60m** on first Apply.
4. **Apply** — waits for model download Job + image pull + worker pods Ready.

Verify on the host:

```bash
kubectl -n sglang-qwen36-27b get pods
kubectl -n sglang-qwen36-27b get svc
export WORKER_API_KEY='your-key'
curl -sS -H "Authorization: Bearer ${WORKER_API_KEY}" http://127.0.0.1:30001/v1/models
```

---

## Step 5 — AWS: NLB per worker

Each worker gets a **NodePort** on the GPU instance (see table). Repeat for every worker.

**Security group:** allow each NodePort from gateway egress only — not the public internet.

### Target group

EC2 → Target groups → Create → **Instances**, TCP port = NodePort (e.g. `30001`) → register GPU instance.

### Network Load Balancer

EC2 → Load balancers → **Network Load Balancer** → TLS :443 (ACM cert) → forward to target group → copy NLB DNS name.

---

## Step 6 — Dashboard worker pool

Model group from step 3 → **Create worker pool**:

```text
27b-a | https://<nlb-dns-for-30001> | <WORKER_API_KEY>
27b-b | https://<nlb-dns-for-30002> | <WORKER_API_KEY>
```

Same `WORKER_API_KEY` for all workers. Wait ~1 minute for sync.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Pods not Ready | `kubectl -n <namespace> logs deploy/...` |
| 401 from worker | `WORKER_API_KEY` mismatch between Distr and dashboard |
| NLB unhealthy | GPU security group / target group port |
| Apply timeout | 120m (27B) or 60m (7B) |
| Port conflict | 27B: 30001–30002; 7B: 30003–30004 on same host |

---

## Related repos

- **27b-deployment** (private) — Helm chart source published to Distr
- [`api-gateway`](https://github.com/subconscious-systems/api-gateway) — Router and dashboard
