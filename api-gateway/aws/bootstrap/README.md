# Docker agent host bootstrap

Terraform and scripts for the day-0 EC2 host that runs the Distr Docker agent and api-gateway-infra runner, with an **instance profile** for AWS APIs. **No AWS access keys** in Distr Hub.

**Setup procedure (SoT):** [../instructions.md](../instructions.md) — steps 4 (bootstrap), 7 (Docker agent), and 9 (Kubernetes agent) invoke the scripts here. Architecture: [../README.md](../README.md).

This directory is the source of truth for bootstrap **Terraform and scripts**, not the end-to-end checklist.

## What this host does

- Runs the Distr Docker agent and the infra Compose / runner image
- Supplies AWS credentials via the EC2 instance profile (platform Terraform, Secrets Manager, EKS API)
- Day-0 EKS API access is CIDR-locked to this host’s EIP; `kubectl` for agent install and break-glass runs **on the box** over SSM (not from your laptop)
- The Distr **Kubernetes** agent is **not** installed on this EC2. Hub’s `kubectl apply` command installs `distr-agent` pods into EKS (namespace = `GATEWAY_DISTR_DEPLOYMENT_NAME`). This host only runs that `kubectl` over SSM.

## Bootstrap-specific prerequisites

- AWS CLI + Terraform ≥ 1.6 (laptop or any Terraform-capable shell, including SSM)
- Rights to create EC2 / IAM / EIP in the target account
- Account **default VPC** with at least one public subnet (or set `vpc_id` / `subnet_id` in `terraform.tfvars`)
- Prefer remote state via `backend.tf` (see `backend.tf.example`) so re-applies from any checkout share the same state

Naming, Hub Secrets, entitlements, and the full ordered checklist live in [../instructions.md](../instructions.md).

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

## Break-glass debug (human kubectl)

EKS API access is CIDR-locked to this host. For power-user debug, open an interactive SSM shell and run `kubectl` / docker logs **on the box**:

```bash
./scripts/connect.sh <DEPLOY_NAME>   # refreshes kubeconfig, then SSM session
./scripts/connect.sh                 # SSM session only
```

Requires the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your laptop. Distinct from `connect-k8s-agent.sh` (agent install — see [instructions.md](../instructions.md) step 9).

## Rotate app secrets (csrf / encryption)

Same SSM connection path as `connect.sh`, non-interactive:

```bash
./scripts/rotate-app-secret.sh csrf <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
./scripts/rotate-app-secret.sh encryption <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
```

Full procedure: [../secret-rotation.md](../secret-rotation.md).

## Hub env notes (after bootstrap)

Bootstrap does not write Hub config. When you paste the infra env (see [instructions.md](../instructions.md) and [sample-gateway-infra.env](../sample-gateway-infra.env)):

| Field | Note |
| --- | --- |
| AWS keys | **omit** (instance profile) |
| `AWS_REGION` | same region as this bootstrap |
| `GATEWAY_AUTO_DEPLOY` | soft-skips until the K8s agent target exists; use `true` on the second+ infra run |

(`CLUSTER_ENDPOINT_PUBLIC_ACCESS=true` is the template default. Leave `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS` empty unless you need extra CIDRs; the runner fills this host’s `/32`.)

Hub Secrets and cluster secret paths: [../gateway-secrets.md](../gateway-secrets.md).

## Destroy

```bash
terraform destroy -auto-approve
```

Only destroys this host, not the platform VPC/EKS created by the infra runner. It is recommended to first destroy kubernetes resources via undeployment of the gateway Helm app and then undeploy the infra app. Then terraform destroy the bootstrapped EC2 host and all related resources.
