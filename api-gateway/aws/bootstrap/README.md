# Docker agent host bootstrap (canonical day-0)

This directory is the **only** source of truth for day-0 bootstrap Terraform and scripts (customer runbook).

Laptop- or shell-applied Terraform that creates a small EC2 with an **instance profile** capable of running the api-gateway-infra Distr Docker Application. **No AWS access keys** in Distr Hub.

Full AWS procedure: [../instructions.md](../instructions.md) · Architecture: [../README.md](../README.md).

## Prerequisites

- AWS CLI + Terraform >= 1.6 (laptop or any Terraform-capable shell, including SSM)
- Admin (or equivalent) rights to create EC2 / IAM / EIP in the target account
- Account **default VPC** with at least one public subnet (or set `vpc_id` / `subnet_id` in `terraform.tfvars`)
- Prefer remote state via `backend.tf` (see `backend.tf.example`) so re-applies from any checkout share the same state

## Quick start

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/api-gateway/aws/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit region / name_prefix if needed
# recommended remote state:
#   cp backend.tf.example backend.tf && edit bucket/key

./scripts/bootstrap.sh
```

### 1. Distr Docker agent (on this EC2)

Copy the Distr Docker-agent **connect URL** from Hub, then:

```bash
./scripts/run-agent.sh 'https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…'
```

### 2. After EKS exists: Distr Kubernetes agent (in the cluster)

The K8s agent is **not** installed on this EC2. Hub’s `kubectl apply` command installs `distr-agent` pods into namespace `GATEWAY_DISTR_DEPLOYMENT_NAME` inside EKS. This host only runs `kubectl` over SSM (day-0 API is locked to this host’s IP).

```bash
./scripts/connect-k8s-agent.sh \
  'kubectl apply -n <GATEWAY_DISTR_DEPLOYMENT_NAME> -f "https://app.distr.sh/api/v1/connect?…"'
```

Then re-run infra with `GATEWAY_AUTO_DEPLOY=true` (or deploy the gateway app in Hub).

### Break-glass debug (human kubectl)

EKS API access is CIDR-locked to this host. For power-user debug, open an interactive SSM shell and run `kubectl` / docker logs **on the box** (not from your laptop):

```bash
./scripts/connect.sh <DEPLOY_NAME>   # refreshes kubeconfig, then SSM session
./scripts/connect.sh                 # SSM session only
```

Requires the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your laptop. Distinct from `connect-k8s-agent.sh` (agent install).

### Rotate app secrets (csrf / encryption)

Same SSM connection path as `connect.sh`, non-interactive:

```bash
./scripts/rotate-app-secret.sh csrf <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
./scripts/rotate-app-secret.sh encryption <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
```

Full procedure: [../secret-rotation.md](../secret-rotation.md).

## Idempotency

| Action | Behavior |
| --- | --- |
| Re-run `./scripts/bootstrap.sh` | Terraform keeps the **same** instance (`user_data` ignored after create). Then SSM re-applies `scripts/host-setup.sh` (Docker/compose/kubectl). Distr agents are **not** torn down. |
| Re-run `./scripts/ensure-host.sh` | Same host-setup via SSM only (no Terraform). |
| Re-run `./scripts/run-agent.sh` | Ensures host setup, then re-runs Docker-agent connect. |
| Re-run `./scripts/connect-k8s-agent.sh` | Ensures host setup, then re-applies K8s agent manifests into EKS. |
| Re-run `./scripts/connect.sh` | Opens a new SSM session (optional kubeconfig refresh). |
| Re-run `./scripts/rotate-app-secret.sh` | Non-interactive SSM rotate of csrf or encryption (see [secret-rotation.md](../secret-rotation.md)). |

Cloud-init is first-boot only. Setup script changes do **not** replace the EC2; push them with `ensure-host` / `bootstrap` / `run-agent` / `connect-k8s-agent`.

## Hub env after bootstrap

From `./scripts/bootstrap.sh` output / Hub template:

| Field | Value |
| --- | --- |
| AWS keys | **omit** (instance profile) |
| `AWS_REGION` | same as bootstrap |
| `GATEWAY_AUTO_DEPLOY` | soft-skips until K8s agent target exists; set `true` for the second infra run |

(`CLUSTER_ENDPOINT_PUBLIC_ACCESS=true` is the template default. Leave `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS` empty unless you need extra CIDRs; the runner fills this host's `/32`.)

Hub Secrets still needed: `DISTR_TOKEN`, `DD_*` (if Datadog on), optional dashboard bootstrap password. Cluster secrets: [../gateway-secrets.md](../gateway-secrets.md).

## Layout

| Path | Role |
| --- | --- |
| `scripts/bootstrap.sh` | `terraform apply` + `ensure-host` |
| `scripts/ensure-host.sh` | Idempotent Docker/compose/kubectl via SSM |
| `scripts/host-setup.sh` | Canonical host setup (cloud-init + SSM) |
| `scripts/run-agent.sh` | Ensure host + Distr Docker connect via SSM |
| `scripts/connect-k8s-agent.sh` | Ensure host + install Distr K8s agent into EKS via SSM |
| `scripts/connect.sh` | Break-glass SSM shell on this host (optional kubeconfig refresh) |
| `scripts/rotate-app-secret.sh` | Rotate csrf / encryption via SSM + runner image |
| `scripts/tests/test-rotate-app-secret.sh` | CLI contract unit tests (no AWS) |
| `*.tf` | EC2, EIP, SG (egress), IAM instance profile |
| `policies/platform-apply.json` | Broad platform-apply rights (scope later) |
| `cloud-init.yaml.tftpl` | First-boot only (embeds `host-setup.sh`) |

## Destroy

```bash
terraform destroy -auto-approve
```

Only destroys this host, not the platform VPC/EKS created by the infra runner.
