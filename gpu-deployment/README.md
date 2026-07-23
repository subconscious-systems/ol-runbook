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

Download with **`curl`** — do not copy/paste the script into vim; pasted files often get corrupted (`apt-get` → `apget`, broken lines).

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

The interactive setup handles AWS discovery, Terraform configuration, and the
plan. Before running it, authenticate the AWS CLI (`aws login`) with permission
to manage EC2 networking, ELBv2, ACM, and Route 53.

```bash
./gpu-deployment/terraform/aws-private-workers/setup.sh
```

Add `--profile <name>` or `--region <region>` when needed. The wizard lets you
select the EKS cluster, GPU instance, Route 53 zone, model, worker domain, and
gateway Helm identity. It then:

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

If the gateway chart's baseline `networkPolicy.enabled` is already true, apply
the generated additive worker-egress policy:

```bash
terraform output -raw gateway_worker_egress_network_policy_yaml \
  | kubectl apply -f -
```

Do not apply that policy by itself when no complete baseline policy selects the
gateway pods, because it would isolate them to worker egress. Do not expose the
GPU NodePorts publicly.

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
