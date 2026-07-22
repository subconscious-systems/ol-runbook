# GPU deployment

Install path for SGLang workers on a customer GPU host. Everything is in this file.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian, 4× GPU for profiles below |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Subconscious provisions the SGLang worker Helm application |

## Step 1 — GPU host

Download with **`curl`** — do not copy/paste the script into vim; pasted files often get corrupted (`apt-get` → `apget`, broken lines).

```bash
curl -fsSL https://raw.githubusercontent.com/subconscious-systems/ol-runbook/main/gpu-deployment/dependencies.sh -o ~/dependencies.sh
chmod +x ~/dependencies.sh
~/dependencies.sh
```

Or clone the runbook (includes profiles for step 4):

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/gpu-deployment
chmod +x dependencies.sh
./dependencies.sh
```

May reboot once for NVIDIA drivers. Then verify:

```bash
nvidia-smi
kubectl get nodes
kubectl get namespace sglang
```

---

## Step 2 — Connect Distr

1. Log into [Distr](https://app.distr.sh/) and click on the secrets page.
2. Add a secret called WORKER_API_KEY, go to gateway dashboard to generate value, store this somewhere safe, will need it to configure path.
3. Navigate to the deployments page and click on New Deployment.
4. Select 27b-deployment as the application.
5. Enter deployment name and set Kubernetes Namespace to "sglang".
6. Leave default Application Config, go to [profiles](profiles/) and find the correct profile. Copy and paste exactly from the profile file into the Helm Values section in the App Config section of Distr.
7. Click Customize Helm options and set watcher to 2h.
8. Click create deployment.
9. Go back to GPU host and run the command Distr provides, should look like:

```bash
kubectl apply -n sglang -f "https://app.distr.sh/api/v1/connect?..."
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

Model group from step 3 → **Create worker pool**. One line per worker; same `WORKER_API_KEY` for all.

**27B** (`qwen3.6-27b`):

```text
27b-a | https://<nlb-dns-for-30001> | <WORKER_API_KEY>
27b-b | https://<nlb-dns-for-30002> | <WORKER_API_KEY>
```

**8B** (`qwen3-8b`):

```text
8b-a | https://<nlb-dns-for-30003> | <WORKER_API_KEY>
8b-b | https://<nlb-dns-for-30004> | <WORKER_API_KEY>
8b-c | https://<nlb-dns-for-30005> | <WORKER_API_KEY>
8b-d | https://<nlb-dns-for-30006> | <WORKER_API_KEY>
```

Wait ~1 minute for sync.

---
