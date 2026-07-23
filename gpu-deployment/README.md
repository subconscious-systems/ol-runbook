# GPU deployment

Install path for SGLang workers on a customer GPU host. Profiles, host bootstrap,
and private AWS routing automation live in this directory. Suggest cloning this repo on a local device to run AWS setup.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian, 4× GPU for profiles below |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Will need to setup deployment |
| SGLang chart **0.9.0+** | Installs Datadog Agent with GPU monitoring when profiles enable it |

## Step 1 — GPU Host Preparation

Download with **`curl`** onto GPU host and run.

```bash
curl -fsSL https://raw.githubusercontent.com/subconscious-systems/ol-runbook/main/gpu-deployment/dependencies.sh -o ~/dependencies.sh
chmod +x ~/dependencies.sh
~/dependencies.sh
```
May reboot for NVIDIA drivers. Run script again after reboot. Script should print "install finished". Then verify:

```bash
nvidia-smi
kubectl get nodes
kubectl get namespace sglang
```

---

## Step 2 — Distr Setup

1. Log into [Distr](https://app.distr.sh/) and open **Secrets**.
2. Create these Hub Secrets (keep `WORKER_API_KEY` — you need it again in step 4):
   | Secret name | Create the value | Used by |
   |---|---|---|
   | `WORKER_API_KEY` | Gateway dashboard → model group → worker API key | Worker pods + dashboard worker pool |
   | `DD_API_KEY` | Datadog → Organization Settings → API Keys → New Key | Datadog Agent on the GPU host (GPU Health) |
3. Navigate to **Deployments** → **New Deployment**.
4. Select the SGLang / gpu-deployment application and choose app version **0.9.0 or newer**.
5. Enter a deployment name and set **Kubernetes Namespace** to `sglang`.
6. Open [profiles](profiles/), pick the model, and paste the **entire** profile into **App Config → Helm Values** (full replace). Make sure to change DataDog URL to your correct region.
7. **Customize Helm options** — set the operation timeout to 120m.
8. Click **Create deployment**.
9. On the GPU host, run the connect command Distr provides. It should look like:

```bash
kubectl apply -n sglang -f "https://app.distr.sh/api/v1/connect?..."
```

After Apply succeeds, confirm the Agent and workers:

```bash
kubectl -n sglang get pods
# Expect worker pods plus a Datadog Agent pod (gpuMonitoring enabled)
kubectl -n sglang get pods -l app.kubernetes.io/name=datadog
```

GPU Health appears in Datadog under **Infrastructure → GPU Monitoring** once the Agent is Running (metrics such as `gpu.utilization`).

---

## Step 3 — Worker URL with AWS

The interactive setup handles AWS discovery, Terraform configuration, and the plan.  
Before running it, authenticate the AWS CLI (`aws login`) with permission to manage EC2 networking, ELBv2, ACM, and Route 53.

```bash
./gpu-deployment/terraform/aws-private-workers/setup.sh
```

Add `--profile <name>` or `--region <region>` when needed. The wizard lets you
select the EKS cluster, GPU instance, Route 53 zone, model, and worker domain.
It then:

- discovers both VPCs, subnets, security groups, existing peering, and ACM cert;
- writes the complete `terraform.tfvars`;
- runs `terraform init`, `validate`, and `plan`;
- optionally runs `terraform apply`.

Review `terraform.tfvars` before running `terraform apply`.  
Each worker should have one target group, internal NLB, TLS listener, and DNS record. 

After apply, add the suffix printed by the wizard to the Helm override values of the gateway Distr deployment:

```yaml
gateway:
  routeAllowedHostSuffixes:
    - workers.example.com
```

Manual setup, existing-resource adoption, and troubleshooting details are in
[`terraform/aws-private-workers/README.md`](terraform/aws-private-workers/README.md).

---

## Step 4 — Adding to Dashboard

Create a new Model Group, same `WORKER_API_KEY` from Distr secrets for all.

Example 

**8B** (`qwen3-8b`):

```text
8b-a | https://8b-a.<worker-domain> | <WORKER_API_KEY>
8b-b | https://8b-b.<worker-domain> | <WORKER_API_KEY>
8b-c | https://8b-c.<worker-domain> | <WORKER_API_KEY>
8b-d | https://8b-d.<worker-domain> | <WORKER_API_KEY>
```

Add `<worker-domain>` (for example `workers.example.com`) to the gateway
`routeAllowedHostSuffixes`, then wait for each endpoint to report `registered`.

---
