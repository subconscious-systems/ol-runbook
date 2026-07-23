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

1. Log into [Distr](https://app.distr.sh/) and click on the secrets page.
2. Create three secrets:
   Keep `WORKER_API_KEY` safe, will need it to configure route in dashboard later.
   | Secret name | Location |
   |---|---|
   | `DD_API_KEY` | **Datadog → Organization Settings → API Keys → New Key** |
   | `DD_APP_KEY` | **Datadog → Organization Settings → Application Keys → New Key** |
   | `WORKER_API_KEY` | **Subconscious Gateway Dashboard → Model Groups → Generate Worker API Key** |
3. Navigate to the deployments page and click on New Deployment.
4. Select gpu-deployment as the application.
5. Enter deployment name and set Kubernetes Namespace to "sglang".
6. Leave default Application Config, go to [profiles](profiles/) and find the correct profile. Copy and paste exactly from the profile file into the Helm Values section in the App Config section of Distr.
7. Click Customize Helm options and set watcher to 2h.
8. Click create deployment.
9. Go back to GPU host and run the command Distr provides, should look like:

```bash
kubectl apply -n sglang -f "https://app.distr.sh/api/v1/connect?..."
```

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
