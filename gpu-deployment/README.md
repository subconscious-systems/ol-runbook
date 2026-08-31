# GPU deployment

Install path for SGLang workers on a customer GPU host. Profiles, host bootstrap,
and AWS/GCP worker-domain routing automation live in this directory. Run host
preparation and the Distr Kubernetes connect command on the GPU node. Clone
this repo on an operator device to run the shared cloud routing wizard.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU host | AWS EC2 or GCP Compute Engine, Ubuntu/Debian, with the GPU count required by the selected profile |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Must be entitled to the SGLang application |
| SGLang chart | **0.10.0+** for Qwen profiles; **0.13.0+** for GLM-5.2 FP8 + DFLASH |
| Model storage | Enough persistent space under `/models/hf` for every model downloaded by the selected profile |

The gateway [EKS upgrade](../api-gateway/aws/eks-upgrade.md) does not alter these
separate k3s worker clusters. After every EKS hop, however, the operator must
smoke the gateway-to-worker route (`/health`) and authenticated inference before
declaring the gateway upgrade healthy.

## Select a profile

| Model | Profile | Supported topology |
|---|---|---|
| Qwen3.6-27B-FP8 | `profiles/qwen36-27b-*.yaml` | L4 (2/4/8 GPUs); L40S, A100-80GB, H100-80GB, H200, or B200 (1/2/4/8 GPUs) |
| Qwen3-8B-FP8 | `profiles/qwen3-8b-l4-1gpu.yaml` | One L4 GPU |
| GLM-5.2-FP8 + DFLASH | `profiles/glm-5.2-b200-{4,8}gpu.yaml` | Four or eight B200 GPUs |

Select a profile that exactly matches the GPU type and count on one node. The
legacy `qwen36-27b.yaml` and `qwen3-8b.yaml` examples remain for existing
deployments; use the explicitly named profile for new installs.

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
2. Create the Hub Secrets required by the selected profile. Keep
   `WORKER_API_KEY` in the customer password manager—you need the same value in
   step 4.

   | Secret name | Create the value | Used by |
   |---|---|---|
   | `WORKER_API_KEY` | Gateway dashboard → model group → worker API key | All worker profiles and dashboard worker endpoints |
   | `DD_API_KEY` | Datadog → Organization Settings → API Keys → New Key | All published profiles; Datadog Agent GPU health |
   | `HF_TOKEN` | Hugging Face read token | GLM profiles; authenticates both the main GLM and DFLASH downloads |

   The main `zai-org/GLM-5.2-FP8` repository is public and does not itself
   require a token. The GLM profiles still require `HF_TOKEN` as their
   authenticated download contract and pass it to both model-download init
   containers. Never place any resolved secret directly in Helm values.

3. Navigate to **Deployments** → **New Deployment**.
4. Select the SGLang / gpu-deployment application. Use **0.10.0 or newer** for
   Qwen, or **0.13.0 or newer** for GLM-5.2 FP8 + DFLASH.
5. Enter a deployment name and set **Kubernetes Namespace** to `sglang`.
6. Open [profiles](profiles/), pick the model and exact GPU topology, and paste
   the **entire** profile into **App Config → Helm Values** (full replace).
   Change `datadog.site` if the customer does not use `datadoghq.com`.
7. **Customize Helm options** — set the operation timeout to 120m.
8. Create/save the deployment and its namespace-scoped Kubernetes target.
9. On the GPU host, run the one-time connect command Distr provides. Treat its
   URL as a password; do not paste it into chat, a ticket, or shell history. It
   should look like:

   ```bash
   kubectl apply -n sglang -f "https://app.distr.sh/api/v1/connect?..."
   ```

10. Wait for the target to report connected, then return to the deployment and
    click **Apply**. Watch the Distr deployment until Helm succeeds.

Helm Apply downloads model weights before starting the worker:

- Qwen profiles create one model-download init container.
- GLM profiles create two serial init containers: the main
  `zai-org/GLM-5.2-FP8` weights under `/models/hf/GLM-5.2-FP8`, then
  `SubconsciousDev/glm-5.2-fp8-dflash-v2` under
  `/models/hf/glm-5.2-fp8-dflash-v2`.
- Downloads persist on the host-mounted `/models/hf` volume. A later Apply
  skips a model whose config and weight shards are already complete.
- The worker does not start unless every model download succeeds.

For updates, select the newer application version on the existing deployment
and Apply. The application version supplies the immutable worker digest, and
the profile pre-pulls it before Recreate replaces healthy workers. Do not edit
`releaseImages`, manually pull with `crictl`, or recreate the GPU host. The GLM
profiles intentionally clear the model-neutral release pin and select the
Blackwell fork in `registry.distr.sh` required by their DFLASH and Subconscious
flags. The Distr-injected image pull secret authenticates that pull; no
separate registry credentials are required.

After Apply succeeds, confirm the Agent and workers:

```bash
kubectl -n sglang get pods
# Expect worker pods plus a Datadog Agent pod (gpuMonitoring enabled)
kubectl -n sglang get pods -l app.kubernetes.io/name=datadog
```

GPU Health appears in Datadog under **Infrastructure → GPU Monitoring** once the Agent is Running (metrics such as `gpu.utilization`).

### Current automation boundary

There is no PAT-only GPU bootstrap command today. `gpu-deployment/setup.sh`
configures AWS or GCP worker domains; it does not create Distr resources or run
Apply. The target, deployment, profile selection, secrets, connect command, and
Apply remain the explicit steps above.

A PAT-driven flow is possible and should run on the GPU node after Step 1,
because that node owns the local k3s kubeconfig and must install the Distr
Kubernetes agent. A Distr PAT alone is not enough input: automation would also
need the entitled application/profile choice, deployment name, worker API key,
Datadog key, and—for GLM—the Hugging Face token. Until a
reviewed command exists, do not give a PAT to `setup.sh` or place it on a command
line.

---

## Step 3 — Worker URL with AWS

The interactive setup handles AWS discovery, Terraform configuration, and the plan.  
Before running it, authenticate the AWS CLI (`aws login`) with permission to manage EC2 networking, ELBv2, ACM, and Route 53.

```bash
./gpu-deployment/setup.sh aws
```

The wizard lets you select the EKS cluster, GPU instance, Route 53 zone,
8B/27B worker layout, and worker domain. GLM uses one worker on NodePort 30001
and currently requires the manual Terraform path documented in
[`terraform/aws-private-workers/README.md`](terraform/aws-private-workers/README.md).
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

## Step 3 — Worker URL with GCP

The GCP wizard creates the corresponding Certificate Manager, Cloud DNS,
regional HTTPS load-balancer, backend, health-check, and firewall resources.
It supports either private same-region GKE-to-worker routing or a public HTTPS
frontend protected by the existing worker bearer key.

Before running it, authenticate the Google Cloud CLI with access to the worker,
gateway (internal mode), and DNS projects:

```bash
gcloud auth login
./gpu-deployment/setup.sh gcp
```

Choose one mode:

- `internal`: private load-balancer IP, plus VPC Network Peering when the
  gateway and worker use different VPCs;
- `public-api-key`: public load-balancer IP. The wizard requires explicit
  confirmation that `worker.auth.enabled=true` and `SGLANG_WORKER_API_KEY` is
  populated before it will plan.

The GCP wizard currently offers the 8B and 27B worker layouts. For GLM, use the
manual configuration in [`terraform/gcp-workers/README.md`](terraform/gcp-workers/README.md)
with one worker on NodePort 30001.

After apply, add the printed worker-domain suffix to the gateway's
`routeAllowedHostSuffixes` and add each endpoint to the dashboard with the same
`WORKER_API_KEY` stored in Distr.

Architecture, permissions, manual setup, and verification are in
[`terraform/gcp-workers/README.md`](terraform/gcp-workers/README.md).

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

**GLM-5.2** (`glm-5.2`, one worker for either B200 profile):

```text
glm-52 | https://glm-52.<worker-domain> | <WORKER_API_KEY>
```

Add `<worker-domain>` (for example `workers.example.com`) to the gateway
`routeAllowedHostSuffixes`, then wait for each endpoint to report `registered`.

---
