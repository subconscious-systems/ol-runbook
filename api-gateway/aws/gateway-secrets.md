# Gateway cluster secrets (AWS)

How secrets land in the cluster for Assisted Self-Managed API Gateway on AWS.

Cluster source of truth is **AWS Secrets Manager**, synced by **External Secrets Operator (ESO)** into fixed Kubernetes Secret names. The Helm chart uses `secrets.create=false` and consumes those Secrets, not Distr Hub keys for database URLs or crypto material.

Related: [README.md](README.md) · [instructions.md](instructions.md) · [secret-rotation.md](secret-rotation.md) · [FAQ.md](../../FAQ.md).

## Logical bundles (Secrets Manager)

```text
orangeline/{DEPLOY_NAME}/rds      # connection URL JSON { "url": "..." }
orangeline/{DEPLOY_NAME}/valkey   # connection URL JSON { "url": "..." }
orangeline/{DEPLOY_NAME}/app      # crypto / router / bootstrap JSON
```

`DEPLOY_NAME` is the infra Docker deployment name / Terraform name prefix (example: `acme-api-gateway-infra`).

The infra runner ensures the `app` secret after a successful Terraform apply (generate-if-missing) and waits for ESO to sync before gateway auto-deploy.

## App JSON keys

Generate-if-missing in the `app` secret:

| Key | Notes |
| --- | --- |
| `SUBCONSCIOUS_GATEWAY_ROUTER_API_KEY` | Aligned with `SGL_ROUTER_API_KEY` |
| `SUBCONSCIOUS_GATEWAY_CREDENTIAL_ENCRYPTION_KEY` | Dual-key rotation via `_PREVIOUS` |
| `SUBCONSCIOUS_GATEWAY_DASHBOARD_CSRF_SECRET` | Dual-key rotation via `_PREVIOUS` |
| `SGL_ROUTER_API_KEY` | Same value as gateway router key |
| `SGL_ROUTER_CONTROL_PLANE_ADMIN_KEY` | |
| `SGLANG_WORKER_API_KEY` | Adapter probe placeholder; per-worker keys live in the gateway DB |

Previous companions (seeded empty if missing):

- `SUBCONSCIOUS_GATEWAY_CREDENTIAL_ENCRYPTION_KEY_PREVIOUS`
- `SUBCONSCIOUS_GATEWAY_DASHBOARD_CSRF_SECRET_PREVIOUS`
- `SGL_ROUTER_API_KEY_PREVIOUS`
- `SGL_ROUTER_CONTROL_PLANE_ADMIN_KEY_PREVIOUS`

Optional:

- `SUBCONSCIOUS_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD`: when you supply a day-0 dashboard password via Hub / infra env, the runner can place it in the app secret and enable the chart identity-bootstrap Job

There is **no** `LOCAL_API_KEY` / `SUBCONSCIOUS_GATEWAY_LOCAL_API_KEY`. Day-0 org API keys are created in the dashboard after identity bootstrap (or via ops tooling).

## Target Kubernetes Secrets

| Secret | Keys (representative) |
| --- | --- |
| `gateway-secrets` | `SUBCONSCIOUS_GATEWAY_DATABASE_URL`, `SUBCONSCIOUS_GATEWAY_REDIS_URL`, router/encryption/CSRF (+ previous), optional bootstrap password |
| `router-secrets` | `SGL_ROUTER_API_KEY` (+ previous), `SGL_ROUTER_CONTROL_PLANE_ADMIN_KEY` (+ previous) |
| `worker-secrets` | `SGLANG_WORKER_API_KEY` (placeholder) |

## What still goes in Distr Hub (day-0)

Create these Hub Secrets yourself (masked). Reference them from the infra Docker env with `{{.Secrets.NAME}}`. Never paste plaintext into git or the env template.

| Hub secret | Used by |
| --- | --- |
| `DISTR_TOKEN` | Infra runner (customer PAT) |
| `DD_API_KEY` / `DD_APP_KEY` | Infra / Datadog when enabled (not gateway pods) |
| Optional `{gw}_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD` | First dashboard admin (`{gw}` = `GATEWAY_DISTR_DEPLOYMENT_NAME`) |

Do **not**:

- Put AWS access keys in Hub
- Hand-create Hub keys for database URL, Redis URL, or encryption material as the cluster path
- Put Datadog keys into gateway Helm wiring

## Sync path (AWS)

```text
AWS Secrets Manager (orangeline/{DEPLOY_NAME}/…)
        │
        ▼
External Secrets Operator (in EKS)
        │
        ▼
K8s Secrets: gateway-secrets / router-secrets / worker-secrets
        │
        ▼
api-gateway Helm release (secrets.create=false)
```

Verification after a successful infra + gateway deploy:

```bash
# From break-glass SSM on the bootstrap host (day-0 API is CIDR-locked):
kubectl -n <GATEWAY_DISTR_DEPLOYMENT_NAME> get secret gateway-secrets
```

Also confirm the three SM secrets exist under `orangeline/{DEPLOY_NAME}/` in the AWS console or CLI.

## Rotation

Day-2 procedures (csrf / encryption copy-paste, RDS/Valkey via infra redeploy, org and worker keys): [secret-rotation.md](secret-rotation.md).
