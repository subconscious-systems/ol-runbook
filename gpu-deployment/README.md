# GPU deployment

Install path for SGLang workers on a customer GPU host. Start in
[`profiles/`](profiles/): every YAML includes its exact host-install and weight-
download commands. Run host preparation, weight downloads, and the Distr
Kubernetes connect command on the GPU node. Clone this repo on an operator
device to run the shared cloud routing wizard.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU host | AWS EC2 or GCP Compute Engine running Ubuntu/Debian or Rocky/RHEL 8.4+, with the GPU count required by the selected profile |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Must be entitled to the SGLang application |
| SGLang chart | **0.10.0+** for Qwen profiles; **0.13.0+** for GLM-5.2 profiles |
| Model storage | Enough persistent space at the host path declared by the selected profile (`/models/hf` for Qwen/GLM FP8, `/mnt` for GLM NVFP4) |

The gateway [EKS upgrade](../api-gateway/aws/eks-upgrade.md) does not alter these
separate k3s worker clusters. After every EKS hop, however, the operator must
smoke the gateway-to-worker route (`/health`) and authenticated inference before
declaring the gateway upgrade healthy.

## Select a profile

| Model | Profile | Supported topology |
|---|---|---|
| Qwen3.6-27B-FP8 | `profiles/qwen36-27b-*/values.yaml` | L4 (2/4/8 GPUs); L40S, A100-80GB, H100-80GB, H200, or B200 (1/2/4/8 GPUs) |
| Qwen3-8B-FP8 | `profiles/qwen3-8b-l4-1gpu/values.yaml` | One L4 GPU |
| GLM-5.2-FP8 + DFLASH | `profiles/glm-5.2-b200-{4,8}gpu/values.yaml` | Four or eight B200 GPUs |
| GLM-5.2-NVFP4 | `profiles/glm-5.2-nvfp4-b200-4gpu/values.yaml` | Four B200 GPUs (`CUDA_VISIBLE_DEVICES=0,1,2,3`) |

Select a profile that exactly matches the GPU type and count on one node. The
legacy `qwen36-27b/` and `qwen3-8b/` examples remain for existing
deployments; use the explicitly named profile for new installs.

The GLM-5.2 NVFP4 profile uses the existing `glm-52` worker route on NodePort
`30001`, advertises the served model as `glm-5.2`, and pulls
`registry.distr.sh/subconscious/timrun:sm_100-v0.13`. It mounts the preloaded
`nvidia/GLM-5.2-NVFP4` weights from `/mnt/glm-5.2-nvfp4`; it does not use the
FP8 or DFLASH repositories.

## Step 1 — GPU Host Preparation

Clone the runbook on the GPU host, enter the profiles directory, and run the
installer located beside the YAML files:

```bash
git clone https://github.com/subconscious-systems/ol-runbook.git
cd ol-runbook/gpu-deployment/profiles
./install.sh
```

The bundled installer supports Debian/Ubuntu (`apt`) and Rocky/RHEL-family
hosts (`dnf`). On Rocky/RHEL, the NVIDIA host driver must already work:
`nvidia-smi` must succeed before the script installs the container toolkit and
k3s. When `firewalld` is active, the installer keeps it enabled and adds the
official k3s API, pod, and service-network rules plus TCP NodePorts
`30001-30006`. Override the last range with `K3S_FIREWALL_NODEPORTS` if the
selected profile uses different ports. On enforcing SELinux hosts, it also
persists `container_file_t` labels for `/models/hf` and
`/mnt/glm-5.2-nvfp4`; override the colon-separated paths with
`MODEL_STORAGE_PATHS` when using custom model locations. Rocky/RHEL 8 commonly
boots with cgroup v1; the installer detects that filesystem and persists the
kubelet's temporary `failCgroupV1=false` compatibility setting so k3s can start
without a host reboot. Prefer cgroup v2 for future OS images.

The installer pins k3s to `v1.36.0+k3s1` (containerd `v2.2.3-k3s1`) so large
private-registry image pulls are not subject to the response-header cutoff in
newer containerd releases. Rerunning it replaces a different installed k3s
version with the pin. Set `K3S_VERSION` explicitly only when validating a
replacement version against the Distr worker image.

It may reboot for NVIDIA drivers. Return to the same directory and run
`./install.sh` again after reboot. The script should print `Install finished.`
Then verify:

```bash
nvidia-smi
kubectl get nodes
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
kubectl get namespace sglang
```

## Step 2 — Download model weights

Enter the selected profile directory and run its profile-specific `weights.sh`.
Each folder contains only its `values.yaml` and bound download command.

```bash
cd glm-5.2-nvfp4-b200-4gpu
./weights.sh
```

The script prompts without echoing for a Hugging Face token, then asks for the
download root. Accept its default unless you are also updating every model and
host-mount path in the YAML. For FP8 + DFLASH it downloads the main GLM weights
and the DFLASH repository serially; NVFP4 downloads only NVFP4. Rerunning the
command resumes or verifies the same target directories through the Hugging
Face CLI.

Confirm the profile's `worker.modelPath` exists before continuing. For the
four-GPU NVFP4 profile:

```bash
test -f /mnt/glm-5.2-nvfp4/config.json
find /mnt/glm-5.2-nvfp4 -maxdepth 1 -name '*.safetensors' | head
```

---

## Step 3 — Distr Setup

1. Log into [Distr](https://app.distr.sh/) and open **Secrets**.
2. Create the Hub Secrets required by the selected profile. Keep
   `WORKER_API_KEY` in the customer password manager—you need the same value in
   dashboard setup.

   | Secret name | Create the value | Used by |
   |---|---|---|
   | `WORKER_API_KEY` | Gateway dashboard → model group → worker API key | All worker profiles and dashboard worker endpoints |
   | `DD_API_KEY` | Datadog → Organization Settings → API Keys → New Key | All published profiles; Datadog Agent GPU health |

   Hugging Face tokens are entered only into `weights.sh` on the GPU host. Do
   not add `HF_TOKEN` to Distr or place a resolved token in Helm values.

3. Navigate to **Deployments** → **New Deployment**.
4. Select the SGLang / gpu-deployment application. Use **0.10.0 or newer** for
   Qwen, or **0.13.0 or newer** for either GLM-5.2 profile.
5. Enter a deployment name and set **Kubernetes Namespace** to `sglang`.
6. Open [profiles](profiles/), pick the model and exact GPU topology, and paste
   the folder's **entire `values.yaml`** into **App Config → Helm Values** (full replace).
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

Helm Apply does not download model weights. Profiles mount their host weight
volume read-only and start the worker against the paths populated in Step 2.
If a checkpoint is missing or incomplete, fix it with `weights.sh` and Apply
again.

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

A PAT-driven flow is possible and should run on the GPU node after Step 2,
because that node owns the local k3s kubeconfig and must install the Distr
Kubernetes agent. A Distr PAT alone is not enough input: automation would also
need the entitled application/profile choice, deployment name, worker API key,
Datadog key, and—for GLM—the Hugging Face token. Until a
reviewed command exists, do not give a PAT to `setup.sh` or place it on a command
line.

---

## Step 4 — Worker URL with AWS

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

## Step 4 — Worker URL with GCP

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

## Step 5 — Adding to Dashboard

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
