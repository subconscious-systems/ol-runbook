# GPU deployment

Install path for SGLang workers on a customer GPU host. Everything is in this file.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Subconscious provisions the SGLang worker Helm application |
| Distr registry access | Profile enables `distrPullSecret` for `registry.distr.sh/subconscious/timrun` |

## Namespace

Use **`sglang`** for every profile and every Distr step:

| Step | Where to set `sglang` |
|---|---|
| 1 | `./dependencies.sh` (creates the namespace) |
| 2 | Distr agent connect: `kubectl apply -n sglang ...` |
| 4 | Distr **Customize Helm options → namespace** |

Namespace is **not** in profile YAML. Multiple models on one host share `sglang` (use different NodePorts per profile).

## Install checklist

| Step | Where | What |
|---|---|---|
| **1** | GPU host | `./dependencies.sh` |
| **2** | Distr UI | Connect k3s agent (`-n sglang`) |
| **3** | Dashboard + Distr | Create worker API key → Distr Hub Secret `WORKER_API_KEY` |
| **4** | Distr UI | Apply — paste `profiles/<model>.yaml`, namespace `sglang` + timeout |
| **5** | AWS Console | NLB + target group per worker NodePort |
| **6** | Dashboard | Register worker pool with NLB URLs + same `WORKER_API_KEY` |

Helm values live in **`profiles/`** only (one YAML per model).

---

## Pick a model

| Model | Profile | Timeout |
|---|---|---|
| Qwen3.6-27B-FP8 | `profiles/qwen36-27b.yaml` | 120m |
| Qwen3.6-7B-FP8 | `profiles/qwen36-7b.yaml` | 60m |

Copy the **entire profile file** into Distr Helm Values (step 4).

---

## Step 1 — GPU host

Download with **`curl`** — do not copy/paste the script into vim; pasted files often get corrupted (`apt-get` → `apget`, broken lines).

```bash
curl -fsSL https://raw.githubusercontent.com/subconscious-systems/ol-runbook/main/gpu-deployment/dependencies.sh -o ~/dependencies.sh
chmod +x ~/dependencies.sh
~/dependencies.sh
```

The GPU host may reboot once for NVIDIA drivers. Rerun script after reboot until it prints install finished. Then verify:

```bash
nvidia-smi
kubectl get nodes
kubectl get namespace sglang
```

---

## Step 2 — Connecting Distr

1. Log into [Distr](https://app.distr.sh/) and click on the secrets page.
2. Add a secret called WORKER_API_KEY, go to gateway dashboard to generate value, store this somewhere safe, will need it to configure path.
3. Navigate to the deployments page and click on New Deployment.
4. Select 27b-deployment as the application.
5. Enter deployment name and set Kubernetes Namespace to "sglang".
6. Leave default Application Config, go to [profiles](profiles/) and find the correct profile. Copy and paste exactly from the profile file into the Helm Values section in the App Config section of Distr.
7. Click create deployment.
8. Go back to GPU host and run the command Distr provides, should look like:

```bash
kubectl apply -n sglang -f "https://app.distr.sh/api/v1/connect?..."
```

---

Verify on the host:

```bash
kubectl -n sglang get pods
kubectl -n sglang get svc
export WORKER_API_KEY='your-key'
curl -sS -H "Authorization: Bearer ${WORKER_API_KEY}" http://127.0.0.1:30001/v1/models
```

---

## Step 3 — AWS: NLB per worker

Each worker gets a **NodePort** on the GPU instance (see table). Repeat for every worker.

**Security group:** allow each NodePort from gateway egress only — not the public internet.

### Target group

EC2 → Target groups → Create → **Instances**, TCP port = NodePort (e.g. `30001`) → register GPU instance.

### Network Load Balancer

EC2 → Load balancers → **Network Load Balancer** → TLS :443 (ACM cert) → forward to target group → copy NLB DNS name.

---

## Step 4 — Dashboard worker pool

Model group from step 3 → **Create worker pool**:

```text
27b-a | https://<nlb-dns-for-30001> | <WORKER_API_KEY>
27b-b | https://<nlb-dns-for-30002> | <WORKER_API_KEY>
```

Same `WORKER_API_KEY` from Distr secrets for all workers. Wait ~1 minute for sync.

---
