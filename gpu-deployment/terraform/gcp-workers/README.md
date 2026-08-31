# GCP worker HTTPS routing

This Terraform root creates stable HTTPS worker domains for an existing GCP
GPU VM running k3s and SGLang. Its interactive setup supports two modes:

| Mode | Frontend | Gateway path | Required protection |
|---|---|---|---|
| `internal` | Regional internal Application Load Balancer | Same-region GKE VPC over VPC Network Peering, or the same VPC | `SGLANG_WORKER_API_KEY` remains enabled |
| `public-api-key` | Regional external Application Load Balancer | Public HTTPS | `SGLANG_WORKER_API_KEY` is mandatory |

Both modes create or reuse a regional Certificate Manager wildcard
certificate and publish per-worker Cloud DNS records. One load balancer uses
host routing to send each name to its corresponding k3s NodePort:

```text
8b-a.workers.example.com ─┐                 ┌─ GPU VM:30003
8b-b.workers.example.com ─┼─ HTTPS LB ─────┼─ GPU VM:30004
8b-c.workers.example.com ─┼─ wildcard cert ┼─ GPU VM:30005
8b-d.workers.example.com ─┘                 └─ GPU VM:30006
```

It does not create the GPU VM, gateway GKE cluster, k3s, SGLang deployment,
gateway Helm release, or dashboard worker records.

## Prerequisites

- Terraform 1.6 or newer and the Google Cloud CLI.
- An existing GCP GPU VM with healthy SGLang NodePorts.
- A service account attached to that VM. A dedicated worker identity is
  preferred; Terraform uses it as the target of the load-balancer firewall
  rules without taking ownership of the VM.
- A public Cloud DNS managed zone. It may be in a separate project.
- Compute Engine, Cloud DNS, Certificate Manager, and GKE APIs enabled in the
  projects where the corresponding resources live.
- Permission to manage regional load-balancer resources, firewall rules,
  Certificate Manager resources, and DNS records. Internal mode also needs
  network-peering permission in both projects.
- The gateway GKE clients and internal load balancer must be in the same region.

Authenticate before running the wizard:

```bash
gcloud auth login
gcloud config set project <WORKER_PROJECT_ID>
gcloud config set compute/region <REGION>
```

The wizard exports a short-lived access token so Terraform uses the same
identity as `gcloud`; it does not write credentials to disk.

Check each worker on the GPU VM before provisioning the load balancer:

```bash
curl -i http://127.0.0.1:30003/health
```

Do not continue until every configured NodePort returns HTTP 200.

## Interactive setup

From the `ol-runbook` checkout:

```bash
./gpu-deployment/setup.sh gcp
```

Or select a mode up front:

```bash
./gpu-deployment/setup.sh gcp \
  --project worker-project-id \
  --dns-project dns-project-id \
  --region us-central1 \
  --mode internal

./gpu-deployment/setup.sh gcp \
  --project worker-project-id \
  --region us-central1 \
  --mode public-api-key
```

The wizard:

1. discovers the running GPU VM and its VPC/subnet;
2. in internal mode, selects a same-region GKE cluster and its VPC;
3. reuses the region's active proxy-only subnet or asks for a new `/23`;
4. selects the public Cloud DNS zone, worker domain, and worker layout;
5. reuses an active matching regional certificate or creates one with DNS
   authorization;
6. writes `terraform.tfvars`, initializes, validates, and saves a plan;
7. optionally applies the saved plan.

Use `--plan-only` to stop after writing `tfplan`. Always review both
`terraform.tfvars` and the plan before applying.

## Internal mode

Internal mode reserves an RFC1918 frontend address in the worker subnet and
publishes that private address in the public DNS zone. Public DNS can return a
private address, but only connected networks can reach it.

The root creates both directions of VPC Network Peering unless the gateway and
worker already use the same VPC or you tell the wizard that peering exists.
GCP peering is non-transitive. If the gateway reaches the worker VPC through a
hub, VPN, NCC, or another existing topology, set:

```hcl
manage_network_peering = false
```

Regional internal Application Load Balancers are reachable from a peered VPC
only by clients in the load balancer's region. Select a gateway GKE cluster
whose nodes are in the same region as the GPU VM.

## Public API-key mode

Public mode deliberately exposes the HTTPS frontend to the internet. Before
the wizard will generate a plan, it requires confirmation that the deployed
profile has both:

```yaml
worker:
  auth:
    enabled: true

secrets:
  worker:
    SGLANG_WORKER_API_KEY: "{{.Secrets.WORKER_API_KEY}}"
```

All published profiles in this directory already use those settings. The
load balancer forwards the `Authorization` header unchanged; SGLang enforces
the bearer key. `/health` remains available for load-balancer health checks and
must not return model data.

The Terraform confirmation is an acknowledgement, not a remote inspection of
the k3s Secret. Verify auth before adding the public endpoint to the gateway:

```bash
# Must fail without a key.
curl -i https://8b-a.workers.example.com/v1/models

# Must succeed with the same worker key stored in Distr and the dashboard.
curl -i \
  -H 'Authorization: Bearer <WORKER_API_KEY>' \
  https://8b-a.workers.example.com/v1/models
```

## What Terraform creates

- one regional proxy-only subnet when an active one does not already exist;
- one unmanaged instance group containing the existing GPU VM;
- one health check and backend service per worker NodePort;
- one regional URL map, HTTPS proxy, TLS policy, forwarding rule, and address;
- narrowly sourced firewall rules for health checkers and managed proxies;
- a regional Certificate Manager DNS authorization and wildcard certificate,
  unless an existing certificate is supplied;
- one Cloud DNS A record per worker;
- in internal mode, both sides of VPC Network Peering when requested.

Firewall targets use the GPU VM's service account because this root does not
take ownership of the existing VM merely to add a network tag. If that service
account is shared, the rules can technically target other VMs with the same
identity, but their sources and destination ports remain restricted.

## Configure the gateway

After apply:

```bash
terraform output worker_endpoints
terraform output -raw gateway_route_allowed_host_suffix
```

Add the suffix to the gateway Helm override values:

```yaml
gateway:
  routeAllowedHostSuffixes:
    - workers.example.com
```

Create one dashboard worker endpoint per Terraform output, using the same
gateway-issued worker key supplied to the worker deployment.

## Verify and troubleshoot

Certificate issuance can take several minutes after the DNS authorization
record appears. Inspect it with:

```bash
gcloud certificate-manager certificates describe <CERTIFICATE_NAME> \
  --project <WORKER_PROJECT_ID> \
  --location <REGION>
```

Inspect backend health:

```bash
gcloud compute backend-services get-health <BACKEND_SERVICE_NAME> \
  --project <WORKER_PROJECT_ID> \
  --region <REGION>
```

Every backend must become healthy. If it does not, check the local `/health`
response, the generated proxy and health-check firewall rules, the instance
group named ports, and whether k3s binds the NodePort on the VM interface.

For internal mode, run HTTPS verification from a gateway pod. DNS resolution
from a laptop is not proof of reachability because the returned address is
private.

## Manual configuration and reuse

Copy and edit the example when automation is not appropriate:

```bash
cd gpu-deployment/terraform/gcp-workers
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform plan
```

Set `proxy_only_subnet_name` when the VPC already has its one active regional
proxy subnet. Set `existing_certificate_id` to the resource name of an active
regional Certificate Manager certificate covering `*.worker_domain`.

Existing load-balancer components with the generated names must be imported
before planning. Never apply a plan that replaces a live forwarding rule or
address without coordinating the DNS and gateway impact.
