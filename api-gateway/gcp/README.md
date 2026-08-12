# API Gateway on GCP

Customer-facing runbook for one production Subconscious Inference System API
Gateway on Google Cloud. This path creates a dedicated production project. It
does not migrate AWS data or provision GPU workers.

The resumable guided installer performs the mechanical work. Every apply still
consumes a reviewed plan, and the infra runner stops after creating the cloud
foundation so the complete in-cluster plan can be reviewed separately.

End-to-end procedure: [instructions.md](instructions.md). Project and private
bootstrap VM: [bootstrap/](bootstrap/). Secrets:
[gateway-secrets.md](gateway-secrets.md). Operations:
[datadog-operations.md](datadog-operations.md),
[gke-upgrade.md](gke-upgrade.md), and
[rollback-teardown.md](rollback-teardown.md).

## Production architecture

| Layer | Required configuration |
| --- | --- |
| Project | One dedicated production project with billing and budget alerts; one existing shared DNS-zone project |
| Region | `us-east1` |
| Kubernetes | GKE Standard regional cluster; two `n4a-standard-4` ARM64 nodes initially, autoscaling 2–4 |
| Control plane | Private nodes; IAM-protected DNS endpoint; IP endpoints disabled |
| Network | Custom VPC, Private Google Access, separate Pod/Service ranges, Cloud NAT |
| PostgreSQL | Cloud SQL PostgreSQL 16, Enterprise, regional HA, private IP, backups and PITR |
| Cache | Memorystore Redis 7, `STANDARD_HA`, AUTH and server-authenticated TLS |
| Ingress | GCE Ingress, reserved global IP, managed certificate, HTTPS redirect, 900-second backend timeout |
| Secrets | Secret Manager → External Secrets Operator using Workload Identity |
| Bootstrap | Private `e2-standard-2` VM, attached service account, IAP + OS Login, no public IP or service-account key |
| Observability | Optional Datadog STS integration, GKE Agent, managed assets, and Cloud SQL DBM |

Before installation, verify N4A quota and capacity in `us-east1-b` and
`us-east1-c`. A documented machine type is not a capacity reservation.

## Applications and ownership

| Application | Type | Responsibility |
| --- | --- | --- |
| `api-gateway-infra` | Docker on the private bootstrap VM | GCS state, VPC, GKE, data services, DNS/ingress dependencies, WIF/ESO, Datadog, generated Helm values |
| `api-gateway` | Helm through the Distr Kubernetes agent | Gateway, router, adapter, migrations, dashboard, services, and Ingress |

The VM authenticates to Google APIs with its attached service account. Distr
Hub never receives a GCP credential file. Both agents make egress-only
connections to Distr.

## Guided installation

Copy `guided-install.json.example`, fill in the non-secret production inputs,
and run:

```bash
cd bootstrap
bash scripts/guided-install.sh --config ../guided-install.json
```

The installer creates and updates the Hub resources, connects both agents,
waits for every stage, and resumes after interruption. The operator makes five
typed approvals:

1. Review and apply the production project/bootstrap plan.
2. Review and apply the exact infra cloud-foundation plan.
3. Review and apply the exact complete platform plan.
4. Review and deploy the pinned gateway release and generated Helm values.
5. Accept the passing production smoke checks.

State migration, preflight, Hub target/deployment creation, both agent
connections, stage toggles, and output discovery are automatic. Never combine
the two infra applies, apply an unreviewed replacement, use a public VM or
cluster IP endpoint, create a service-account key, or place database/cache
credentials in Terraform variables or Helm values.

## Required inputs

- Google Cloud organization or folder and billing account.
- One globally unique production project ID.
- An existing shared Cloud DNS zone for the production hostname, in a project
  distinct from the new gateway project.
- One non-overlapping RFC1918 `/16` for the platform and one `/24` for the
  isolated bootstrap subnet.
- Distr organization, PAT, entitlements, and pinned infra/gateway releases.
- Optional Datadog API/application keys and GCP STS approval.
- Terraform 1.11.4+, jq, curl, Python 3, and a SHA-256 utility. The installer
  installs/checks gcloud and its GKE auth plugin.

No GPU capacity is required for gateway/dashboard health. Authenticated
inference requires an approved provider endpoint.

## Runbook map

1. [instructions.md](instructions.md) — resumable five-approval installation
2. [bootstrap/](bootstrap/) — project, state, private VM, and operator access
3. [sample-gateway-infra.env](sample-gateway-infra.env) — Distr infra settings
4. [gateway-secrets.md](gateway-secrets.md) — Secret Manager, ESO, and WIF
5. [secret-rotation.md](secret-rotation.md) — application and data credentials
6. [datadog-operations.md](datadog-operations.md) — optional observability
7. [gke-upgrade.md](gke-upgrade.md) — staged one-minor upgrades
8. [troubleshooting.md](troubleshooting.md) — common failure modes
9. [rollback-teardown.md](rollback-teardown.md) — rollback and ordered teardown
10. [cost-estimate.md](cost-estimate.md) — production planning estimate
