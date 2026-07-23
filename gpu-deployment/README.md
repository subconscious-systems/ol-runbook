# GPU deployment

Install path for SGLang workers on a customer GPU host. Profiles, host bootstrap,
and private AWS routing automation live in this directory.

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

Use the Terraform root in
[`terraform/aws-private-workers/`](terraform/aws-private-workers/). It creates
the VPC peering and routes, security-group rules, one target group and internal
NLB per worker, `/health` checks, TLS listeners, wildcard ACM certificate,
Route 53 aliases, and the scoped gateway worker-egress NetworkPolicy output.

### Information required

Collect these values before running Terraform:

- AWS region containing both VPCs.
- Gateway EKS cluster name, VPC ID, and private subnet IDs.
- Worker VPC ID and the subnets where internal NLBs may be created. Include the
  GPU instance availability zone.
- GPU EC2 instance ID and one security group attached to that instance.
- Existing public Route 53 zone, such as `example.com`.
- Worker DNS suffix, such as `workers.example.com`.
- Worker names and NodePorts. The supplied profiles use `30001-30002` for 27B
  and `30003-30006` for 8B.
- Gateway namespace and Helm release name. These are used to generate the
  correctly scoped egress NetworkPolicy.
- Optional existing VPC peering ID, reusable NLB security-group ID, and issued
  wildcard ACM certificate ARN.

The applying AWS identity needs permission to manage EC2 networking, ELBv2,
ACM, and Route 53. Terraform derives the effective route tables from the subnet
IDs, including implicit main route-table associations.

Run the read-only discovery script with just a region to list the AWS account,
VPCs, subnets, EKS clusters, EC2 instances, VPC peerings, public Route 53
zones, and regional ACM certificates:

```bash
./gpu-deployment/terraform/aws-private-workers/discover-aws.sh \
  --region us-east-2
```

After identifying the GPU instance and gateway EKS cluster, generate the exact
`terraform.tfvars` file:

```bash
./gpu-deployment/terraform/aws-private-workers/discover-aws.sh \
  --region us-east-2 \
  --gpu-instance-id i-... \
  --eks-cluster gateway-production \
  --route53-zone example.com \
  --worker-domain workers.example.com \
  --model 8b \
  --gateway-namespace api-gateway \
  --gateway-release-name api-gateway \
  --tfvars > gpu-deployment/terraform/aws-private-workers/terraform.tfvars
```

`--tfvars` writes only valid HCL to stdout, so the redirected file is exactly
what Terraform needs. The script resolves both VPCs, subnets, the GPU security
group, existing peering, hosted zone, and wildcard certificate. You must provide
the model (`8b` or `27b`), gateway namespace, and gateway Helm release name. If
the GPU has multiple attached security groups, the script stops and tells you
to rerun with `--worker-security-group <sg-id>`. Add `--profile <name>` when
using a named AWS CLI profile.

Open the generated file and review each `GENERATED NOTE`, especially whether
Terraform should manage pre-existing VPC routes and whether additional worker
subnets are wanted. No placeholder replacement is required when the command
completes successfully.

### Configure Terraform

```bash
cd gpu-deployment/terraform/aws-private-workers
cp terraform.tfvars.example terraform.tfvars
```

Fill in `terraform.tfvars`. A four-worker 8B configuration looks like:

```hcl
aws_region = "us-east-2"

gateway_vpc_id = "vpc-..."
gateway_subnet_ids = [
  "subnet-gateway-private-a",
  "subnet-gateway-private-b",
]

worker_vpc_id = "vpc-..."
worker_subnet_ids = [
  "subnet-worker-a",
  "subnet-worker-b",
]

worker_instance_id                = "i-..."
worker_instance_security_group_id = "sg-..."

route53_zone_name = "example.com"
worker_domain     = "workers.example.com"

workers = {
  "8b-a" = { node_port = 30003 }
  "8b-b" = { node_port = 30004 }
  "8b-c" = { node_port = 30005 }
  "8b-d" = { node_port = 30006 }
}

gateway_namespace    = "api-gateway"
gateway_release_name = "api-gateway"
```

Reuse existing shared resources when applicable:

```hcl
existing_vpc_peering_connection_id = "pcx-..."
existing_nlb_security_group_id      = "sg-..."
certificate_arn                    = "arn:aws:acm:REGION:ACCOUNT:certificate/..."
```

### Plan and apply

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Review the plan before approving it. It should create one target group, NLB,
TLS listener, and DNS record for each entry in `workers`.

After apply, print the endpoint URLs and host suffix:

```bash
terraform output worker_endpoints
terraform output gateway_route_allowed_host_suffix
```

Add the emitted suffix to the gateway Helm values:

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
GPU NodePorts publicly; Terraform permits them only from the private worker NLB
security group.

Complete input, import, certificate, verification, and troubleshooting details
are in
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
