# OrangeLine

**OrangeLine** is the GPU inference runtime for the Subconscious Inference System. It runs TIMRUN on GPUs you provide.

Subconscious provisions a Docker Hub repository for your org and gives your team a pull-only username and access token. Your FDE helps you deploy that image into your environment. On AWS or GCP, optional Terraform in this directory publishes HTTPS worker domains so the gateway can reach those GPUs.

Ryvn is not required on every GPU host. In the full inference system, workers attach to the API Gateway as model routes. GPUs can be in the same AWS, GCP, or Azure account as the gateway, or somewhere else (another hyperscaler, a NeoCloud, an inference platform, a local cluster, or bare metal). If you have GPUs we have not named, we can work with that.

For trials, or if you already have a gateway, you can run OrangeLine alone: pull the image with the credentials we issue and point your own routing layer at it. There is no Ryvn install and no Subconscious API Gateway. OrangeLine still serves models. You will not get context pruning visualization and intelligence without our gateway.

This is step 6 in [getting-started.md](../getting-started.md). Product overview: [OrangeLine](https://docs.subconscious.dev/on-prem/inference-runtime/overview). Placement relative to the gateway: [configurations](https://docs.subconscious.dev/on-prem/deployments/configurations).

## Pull the image

Your FDE supplies `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, and the image (`DOCKERHUB_REPOSITORY:TAG`). Do not commit the token.

```text
# OrangeLine pull instructions

Image:
  <DOCKERHUB_REPOSITORY>:<TAG>

1) Log in with the pull-only access token we provided:

  export DOCKERHUB_USERNAME="<DOCKERHUB_USERNAME>"
  export DOCKERHUB_TOKEN="<DOCKERHUB_TOKEN>"
  echo "$DOCKERHUB_TOKEN" | docker login --username "$DOCKERHUB_USERNAME" --password-stdin

2) Pull:

  docker pull <DOCKERHUB_REPOSITORY>:<TAG>
```

## Provider helpers

The optional [provider helpers](profiles/README.md#provider-helpers) prepare
GPU hosts for FDE-assisted deployments. Their capabilities vary by provider:
some create a VM, some print setup instructions, and managed inference platforms
need their own deployment configuration. A provider folder does not mean every
GPU topology is supported or that a complete runtime deployment is automated.

For a new deployment, start with the Docker Hub image and FDE instructions
above. These helpers still prepare the existing k3s-based host profiles; your
FDE must adapt the image, credentials, and runtime configuration to your deployment.
AWS/GCP worker routing below is a separate step after the runtime is healthy.

## Worker URL with AWS

The interactive setup handles AWS discovery, Terraform configuration, and the plan. Before running it, authenticate the AWS CLI (`aws login`) with permission to manage EC2 networking, ELBv2, ACM, and Route 53.

```bash
./gpu-deployment/setup.sh aws
```

The wizard lets you select the EKS cluster, GPU instance, Route 53 zone, 8B/27B worker layout, and worker domain. GLM uses one worker on NodePort 30001 and currently requires the manual Terraform path documented in [`terraform/aws-private-workers/README.md`](terraform/aws-private-workers/README.md). It then:

- discovers both VPCs, subnets, security groups, existing peering, and ACM cert
- writes the complete `terraform.tfvars`
- runs `terraform init`, `validate`, and `plan`
- optionally runs `terraform apply`

Review `terraform.tfvars` before running `terraform apply`. Each worker should have one target group, internal NLB, TLS listener, and DNS record.

After apply, add the suffix printed by the wizard to the gateway `routeAllowedHostSuffixes` (your FDE can set this on the gateway):

```yaml
gateway:
  routeAllowedHostSuffixes:
    - workers.example.com
```

Manual setup, existing-resource adoption, and troubleshooting details are in [`terraform/aws-private-workers/README.md`](terraform/aws-private-workers/README.md).

## Worker URL with GCP

The GCP wizard creates the corresponding Certificate Manager, Cloud DNS, regional HTTPS load-balancer, backend, health-check, and firewall resources. It supports either private same-region GKE-to-worker routing or a public HTTPS frontend protected by the existing worker bearer key.

Before running it, authenticate the Google Cloud CLI with access to the worker, gateway (internal mode), and DNS projects:

```bash
gcloud auth login
./gpu-deployment/setup.sh gcp
```

Choose one mode:

- `internal`: private load-balancer IP, plus VPC Network Peering when the gateway and worker use different VPCs
- `public-api-key`: public load-balancer IP. The wizard requires explicit confirmation that `worker.auth.enabled=true` and `SGLANG_WORKER_API_KEY` is populated before it will plan

The GCP wizard currently offers the 8B and 27B worker layouts. For GLM, use the manual configuration in [`terraform/gcp-workers/README.md`](terraform/gcp-workers/README.md) with one worker on NodePort 30001.

After apply, add the printed worker-domain suffix to the gateway's `routeAllowedHostSuffixes` and add each endpoint to the dashboard with the same worker API key from the gateway dashboard.

Architecture, permissions, manual setup, and verification are in [`terraform/gcp-workers/README.md`](terraform/gcp-workers/README.md).

## Adding to the dashboard

Create a new model group. Use the same worker API key from the gateway dashboard for every endpoint.

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

Add `<worker-domain>` (for example `workers.example.com`) to the gateway `routeAllowedHostSuffixes`, then wait for each endpoint to report `registered`.
