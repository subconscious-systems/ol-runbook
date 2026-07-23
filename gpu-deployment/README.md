# GPU deployment

Install path for SGLang workers on a customer GPU host. Profiles, host bootstrap,
and private AWS routing automation live in this directory. Suggest cloning this repo on a local device to run AWS setup.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian, 4× GPU for profiles below |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Will need to setup deployment |

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
2. In the gateway dashboard, generate a worker API key. Add it as the Distr Hub
   Secret `WORKER_API_KEY`; keep the same value for the dashboard worker pool
   in step 4.
3. If Datadog is enabled for the gateway infrastructure, create these additional
   Distr Hub Secrets:

   | Secret name | Create the value in Datadog | Used by |
   |---|---|---|
   | `DD_API_KEY` | **Organization Settings → API Keys → New Key** | Datadog Agent ingestion and the infrastructure runner |
   | `DD_APP_KEY` | **Organization Settings → Application Keys → New Key** | Terraform-managed dashboards, monitors, pipelines, and metric configuration |

   The application key must belong to a Datadog user or service account allowed
   to manage those resources. Enter both values directly in Distr so they remain
   masked. Do not put either key in the worker profile, Helm Values, Application
   Config, git, or gateway pods. The infrastructure deployment consumes them;
   the `27b-deployment` worker application does not.
4. Navigate to **Deployments** and click **New Deployment**.
5. Select `27b-deployment` as the application.
6. Enter a deployment name and set **Kubernetes Namespace** to `sglang`.
7. Leave the default Application Config. Open [profiles](profiles/), choose the
   model, and copy the complete profile into **App Config → Helm Values**.
8. Click **Customize Helm options** and set the operation timeout to `2h`.
9. Click **Create deployment**.
10. On the GPU host, run the command Distr provides. It should look like:

```bash
kubectl apply -n sglang -f "https://app.distr.sh/api/v1/connect?..."
```

---

## Step 3 — AWS: NLB per worker

The interactive setup handles AWS discovery, Terraform configuration, and the
plan. Before running it, authenticate the AWS CLI (`aws login`) with permission
to manage EC2 networking, ELBv2, ACM, and Route 53.

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

Review the plan before applying. Each worker should have one target group,
internal NLB, TLS listener, and DNS record.

After apply, add the suffix printed by the wizard to the gateway Helm values:

```yaml
gateway:
  routeAllowedHostSuffixes:
    - workers.example.com
```

Manual setup, existing-resource adoption, and troubleshooting details are in
[`terraform/aws-private-workers/README.md`](terraform/aws-private-workers/README.md).

---

## Step 4 — Dashboard worker pool

Model group from step 3 → **Create worker pool**. One line per worker; same `WORKER_API_KEY` for all.

**27B** (`qwen3.6-27b`):

```text
27b-a | https://27b-a.<worker-domain> | <WORKER_API_KEY>
27b-b | https://27b-b.<worker-domain> | <WORKER_API_KEY>
```

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
