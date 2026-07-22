# GPU deployment

Install path for SGLang workers on a customer GPU host. Everything is in this file.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Subconscious provisions the SGLang worker Helm application |
| Distr registry access | Profile enables `distrPullSecret` for `registry.distr.sh/subconscious/timrun` |

## Install checklist

| Step | Where | What |
|---|---|---|
| **1** | GPU host | `./dependencies.sh` — k3s, NVIDIA drivers, device plugin, **namespace** |
| **2** | Distr UI | Connect k3s agent (`-n` = same namespace as step 1) |
| **3** | Dashboard + Distr | Create worker API key → Distr Hub Secret `WORKER_API_KEY` |
| **4** | Distr UI | Apply — paste `profiles/<model>.yaml`, same namespace + timeout |
| **5** | AWS Console | NLB + target group per worker NodePort |
| **6** | Dashboard | Register worker pool with NLB URLs + same `WORKER_API_KEY` |

Helm values live in **`profiles/`** only (one YAML per model). There is no separate overrides folder.

---

## Pick a model

| Model | Paste into Distr | Namespace | Timeout | NodePorts |
|---|---|---|---|---|
| Qwen3.6-27B-FP8 | `profiles/qwen36-27b.yaml` | `sglang-qwen36-27b` | 120m | 30001, 30002 |
| Qwen3.6-7B-FP8 | `profiles/qwen36-7b.yaml` | `sglang-qwen36-7b` | 60m | 30003, 30004 |

Copy the **entire file** into Distr Helm Values (step 4). Use the **same namespace** for steps 1, 2, and 4.

---

## Step 1 — Bootstrap the GPU host

Default namespace is **`sglang-qwen36-27b`**. For 7B only, set `NAMESPACE=sglang-qwen36-7b`.

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/gpu-deployment
chmod +x dependencies.sh
./dependencies.sh
```

7B example:

```bash
NAMESPACE=sglang-qwen36-7b ./dependencies.sh
```

May reboot once for NVIDIA drivers. Then verify:

```bash
nvidia-smi
kubectl get nodes
kubectl get namespace sglang-qwen36-27b
```

---

## Step 2 — Connect Distr

In Distr, add a **Kubernetes deployment target** for this host and run the k3s agent install command.

The Hub command must use the **same namespace** `dependencies.sh` created, e.g.:

```bash
kubectl apply -n sglang-qwen36-27b -f "https://app.distr.sh/api/v1/connect?..."
```

---

## Step 3 — Worker API key

1. **api-gateway dashboard** → model group for your served model (`qwen3.6-27b` or `qwen3.6-7b`) → create **worker API key**.
2. **Distr → Hub Secrets** → `WORKER_API_KEY` = that key.

---

## Step 4 — Distr Apply

1. Open the SGLang worker Helm application in Distr.
2. **Create Deployment** → paste the profile YAML from the table above.
3. **Customize Helm options** — namespace (same as step 1) and timeout from the table; **120m** / **60m** on first Apply.
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
