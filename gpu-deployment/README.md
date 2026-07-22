# GPU deployment

Install path for SGLang workers on a customer GPU host. Everything is in this file.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Subconscious provisions the SGLang worker Helm application |
| Distr registry access | Profile enables `distrPullSecret` for `registry.distr.sh/subconscious/timrun` |

## Namespace (one per Distr deployment)

Pick a Kubernetes namespace name once. Use the **same value** for:

1. `NAMESPACE=... ./dependencies.sh` (step 1)
2. Distr agent connect (`kubectl apply -n ...`)
3. Distr **Customize Helm options → namespace** (step 4)

Namespace is **not** in profile YAML. Examples:

| Deployment | Suggested `NAMESPACE` |
|---|---|
| Qwen3.6-27B-FP8 | `sglang-qwen36-27b` |
| Qwen3.6-7B-FP8 | `sglang-qwen36-7b` |

Use a different namespace per model when both run on the same host.

## Install checklist

| Step | Where | What |
|---|---|---|
| **1** | GPU host | `NAMESPACE=<name> ./dependencies.sh` |
| **2** | Distr UI | Connect k3s agent (`-n` = same namespace) |
| **3** | Dashboard + Distr | Create worker API key → Distr Hub Secret `WORKER_API_KEY` |
| **4** | Distr UI | Apply — paste `profiles/<model>.yaml`, same namespace + timeout |
| **5** | AWS Console | NLB + target group per worker NodePort |
| **6** | Dashboard | Register worker pool with NLB URLs + same `WORKER_API_KEY` |

Helm values live in **`profiles/`** only (one YAML per model).

---

## Pick a model

| Model | Profile | Timeout | NodePorts |
|---|---|---|---|
| Qwen3.6-27B-FP8 | `profiles/qwen36-27b.yaml` | 120m | 30001, 30002 |
| Qwen3.6-7B-FP8 | `profiles/qwen36-7b.yaml` | 60m | 30003, 30004 |

Copy the **entire profile file** into Distr Helm Values (step 4).

---

## Step 1 — Bootstrap the GPU host

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/gpu-deployment
chmod +x dependencies.sh
NAMESPACE=sglang-qwen36-27b ./dependencies.sh
```

May reboot once for NVIDIA drivers. Then verify:

```bash
nvidia-smi
kubectl get nodes
kubectl get namespace "${NAMESPACE}"
```

---

## Step 2 — Connect Distr

In Distr, add a **Kubernetes deployment target** for this host and run the k3s agent install command with the **same namespace**:

```bash
kubectl apply -n "${NAMESPACE}" -f "https://app.distr.sh/api/v1/connect?..."
```

---

## Step 3 — Worker API key

1. **api-gateway dashboard** → model group for your served model (`qwen3.6-27b` or `qwen3.6-7b`) → create **worker API key**.
2. **Distr → Hub Secrets** → `WORKER_API_KEY` = that key.

---

## Step 4 — Distr Apply

1. Open the SGLang worker Helm application in Distr.
2. **Create Deployment** → paste the profile YAML from the table above.
3. **Customize Helm options** — namespace (same as step 1) and timeout from the table.
4. **Apply** — waits for model download + image pull + worker pods Ready.

Verify on the host:

```bash
kubectl -n "${NAMESPACE}" get pods
kubectl -n "${NAMESPACE}" get svc
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
