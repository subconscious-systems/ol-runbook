# API Gateway on GCP (Assisted Self-Managed)

Customer-facing architecture for deploying the Subconscious Inference System
API Gateway on Google Cloud with Distr. The setup intentionally mirrors the
[AWS workflow](../aws/instructions.md): one Docker-agent bootstrap host, one
infra Docker Application, one gateway Helm Application, and two infra
deployment cycles around connecting the Kubernetes agent.

Step-by-step setup: [instructions.md](instructions.md). Bootstrap:
[bootstrap/](bootstrap/). Secrets: [gateway-secrets.md](gateway-secrets.md).
Operations: [datadog-operations.md](datadog-operations.md),
[gke-upgrade.md](gke-upgrade.md), and
[rollback-teardown.md](rollback-teardown.md).

## Architecture overview

| Application | Type | Where it runs | Job |
| --- | --- | --- | --- |
| `api-gateway-infra` | Distr Docker Application | Private bootstrap VM | Terraform for VPC, GKE, Cloud SQL, Redis, DNS, ESO/WIF, Datadog, and generated Helm values |
| `api-gateway` | Distr Helm Application | GKE via the Kubernetes agent | Installs and upgrades the gateway chart |

The bootstrap VM authenticates with its attached service account. Distr never
receives Google credentials. Both agents make egress-only connections to Hub.

The normal deployment sequence is the same as AWS:

1. Bootstrap the Docker-agent VM.
2. Create Hub secrets and the infra Docker deployment.
3. Connect the Docker agent and run infra with `GATEWAY_AUTO_DEPLOY=false`.
4. Create the gateway Helm deployment and connect the Kubernetes agent.
5. Re-run infra with `GATEWAY_AUTO_DEPLOY=true`.

GCP internally creates its cloud foundation before the in-cluster resources so
the Terraform runner can reach the IAM-protected GKE DNS endpoint. That
checkpoint completes inside the first infra deployment and does not add a
customer-facing deployment cycle.

## Production architecture

| Layer | Required configuration |
| --- | --- |
| Project | One dedicated production project plus an existing shared Cloud DNS project |
| Region | `us-east1` |
| Kubernetes | Regional GKE Standard; two `n4a-standard-4` ARM64 nodes initially, autoscaling 2–4 |
| Control plane | Private nodes; IAM-protected DNS endpoint; IP endpoints disabled |
| Network | Custom VPC, Private Google Access, Pod/Service ranges, Cloud NAT |
| PostgreSQL | Cloud SQL PostgreSQL 16, regional HA, private IP, backups and PITR |
| Cache | Memorystore Redis 7, `STANDARD_HA`, AUTH and TLS |
| Ingress | GCE Ingress, reserved global IP, managed certificate, HTTPS redirect, 900-second timeout |
| Secrets | Secret Manager to External Secrets Operator through Workload Identity |
| Bootstrap | Private `e2-standard-2` VM, IAP + OS Login, attached service account, no public IP or key file |

Before installation, verify N4A quota and capacity in `us-east1-b` and
`us-east1-c`. The gateway can become healthy without GPU capacity; inference
requires an approved provider or worker endpoint.

## GCP-only differences from AWS

- The bootstrap Terraform creates the dedicated project and attaches billing.
- Human login needs both gcloud user auth and Application Default Credentials.
- The first local state is automatically migrated into the new GCS bucket.
- The platform service account receives scoped DNS access in the existing DNS
  project.
- Operator access uses IAP/OS Login and the GKE DNS endpoint instead of SSM and
  the EKS endpoint.

Hub secrets, deployment naming, Docker/Kubernetes agent connection, gateway
version selection, generated Helm values, and the second infra auto-deploy
match AWS.

## Prerequisites

- Rights to create a project under the selected organization/folder, attach
  billing, enable services, administer the budget, set IAM, and update the
  selected Cloud DNS zone.
- One production project ID, an existing DNS project/zone, and non-overlapping
  RFC1918 `/24` bootstrap and `/16` platform ranges.
- Distr customer PAT plus Application and artifact entitlements.
- Terraform 1.11.4+, gcloud, GKE auth plugin, jq, and curl.
- Optional Datadog API/application keys and GCP STS approval.

## Next steps

1. [instructions.md](instructions.md) — AWS-aligned end-to-end checklist
2. [bootstrap/](bootstrap/) — project and private Docker-agent VM
3. [sample-gateway-infra.env](sample-gateway-infra.env) — Hub environment
4. [gateway-secrets.md](gateway-secrets.md) — Secret Manager, ESO, and WIF
5. [troubleshooting.md](troubleshooting.md) — common failures
6. [rollback-teardown.md](rollback-teardown.md) — rollback and ordered teardown
