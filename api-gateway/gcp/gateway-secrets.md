# Gateway cluster secrets (GCP)

Secret Manager is the source of truth for runtime connection and application
material. External Secrets Operator (ESO) syncs those bundles into fixed
Kubernetes Secrets by using Workload Identity Federation for GKE (WIF). The
gateway Helm release consumes the Kubernetes Secrets with secret creation
disabled.

Related: [README.md](README.md) · [instructions.md](instructions.md) ·
[secret-rotation.md](secret-rotation.md).

## Logical bundles and GCP IDs

Portable logical paths:

```text
orangeline/{DEPLOY_NAME}/rds
orangeline/{DEPLOY_NAME}/valkey
orangeline/{DEPLOY_NAME}/app
```

GCP Secret Manager IDs cannot contain `/`, so the released runner must map them
deterministically:

```text
orangeline__{DEPLOY_NAME}__rds
orangeline__{DEPLOY_NAME}__valkey
orangeline__{DEPLOY_NAME}__app
```

`valkey` remains the portable bundle name even though this GCP architecture
uses Memorystore for Redis 7. Labels should include `deploy`, `environment`,
`bundle`, and `managed-by`, without placing secret values in labels.

Sandbox and production use different projects and independently generated
versions. Never copy a bundle across projects.

## Payload ownership

| Bundle | Minimum JSON content | Writer |
| --- | --- | --- |
| `rds` | Cloud SQL private PostgreSQL URL under `url`, with encrypted connection mode | Platform Terraform/runner |
| `valkey` | `rediss://` private Redis URL under `url`, with URL-encoded AUTH and TLS port | Platform Terraform/runner |
| `app` | Router/API, control-plane, worker-placeholder, CSRF, credential-encryption, previous-key, optional bootstrap/OIDC fields | Runner generate-if-missing/rotation |

The Cloud SQL and Redis connection values are sensitive Terraform outputs and
state content even when marked `sensitive`. Protect the versioned GCS backend
with uniform access, audited IAM, and no public access.

For Redis TLS, the released application image must trust the Memorystore server
CA and successfully validate the endpoint. Do not use plaintext port 6379,
disable peer verification, or put the AUTH string in Helm values to work around
a trust failure.

## App keys

The `app` JSON follows the portable gateway contract:

| Key | Notes |
| --- | --- |
| `SUBCONSCIOUS_GATEWAY_ROUTER_API_KEY` | Same active value as `SGL_ROUTER_API_KEY` |
| `SUBCONSCIOUS_GATEWAY_CREDENTIAL_ENCRYPTION_KEY` | Supports `_PREVIOUS` during re-encryption |
| `SUBCONSCIOUS_GATEWAY_DASHBOARD_CSRF_SECRET` | Supports `_PREVIOUS` during grace |
| `SGL_ROUTER_API_KEY` | Router bearer |
| `SGL_ROUTER_CONTROL_PLANE_ADMIN_KEY` | Router control-plane admin bearer |
| `SGLANG_WORKER_API_KEY` | Placeholder only; endpoint keys live in the gateway database |

Previous companions:

- `SUBCONSCIOUS_GATEWAY_CREDENTIAL_ENCRYPTION_KEY_PREVIOUS`
- `SUBCONSCIOUS_GATEWAY_DASHBOARD_CSRF_SECRET_PREVIOUS`
- `SGL_ROUTER_API_KEY_PREVIOUS`
- `SGL_ROUTER_CONTROL_PLANE_ADMIN_KEY_PREVIOUS`

Optional values copied from masked Hub Secrets:

- `SUBCONSCIOUS_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD`
- `SUBCONSCIOUS_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET`

Terraform may create an empty secret container, but only the runner owns the
generate-if-missing app payload. A reapply must never replace existing crypto
material merely because configuration was regenerated.

## WIF and ESO authorization

Required identity chain:

```text
Kubernetes ServiceAccount
  external-secrets/external-secrets
       │ Workload Identity Federation for GKE
       ▼
GCP service account (or direct WIF principal)
       │ secretmanager.versions.access on the three environment secrets only
       ▼
Secret Manager
```

The preferred released implementation uses a dedicated GCP service account,
for example `gateway-eso@PROJECT.iam.gserviceaccount.com`, and:

1. grants it `roles/secretmanager.secretAccessor` on the three secret resources,
   not project-wide;
2. permits only
   `serviceAccount:PROJECT_ID.svc.id.goog[external-secrets/external-secrets]`
   to impersonate it with `roles/iam.workloadIdentityUser`;
3. annotates the ESO Kubernetes ServiceAccount with the GCP service-account
   email;
4. configures `ClusterSecretStore/orangeline-gcp-secretmanager` with the
   environment project ID.

A direct WIF principal binding is also acceptable when the released ESO
configuration supports it and the binding is secret-scoped. Service-account
JSON keys, node-wide Secret Manager access, and the Compute Engine default
service account are not acceptable substitutes.

## Fixed Kubernetes Secrets

| Secret | Representative keys |
| --- | --- |
| `gateway-secrets` | Database/Redis URLs; router, encryption, CSRF and previous keys; optional bootstrap/OIDC values |
| `router-secrets` | Router API and control-plane admin keys, including previous values |
| `worker-secrets` | Worker placeholder key |

ESO must set an owner reference/creation policy appropriate for regeneration.
Deleting a generated Kubernetes Secret should cause ESO to recreate it from
Secret Manager; it must not create a new cloud secret version.

## What belongs in Distr Hub

Masked, environment-specific Hub Secrets:

- customer `DISTR_TOKEN`;
- Datadog API/application keys;
- optional dashboard bootstrap password;
- optional OIDC client secret.

Never place these in Hub:

- GCP service-account JSON or ADC;
- Cloud SQL URL/password;
- Redis URL/AUTH string or CA material;
- app/router/CSRF/encryption values;
- Terraform state or backend credentials.

## Verification without revealing values

From the private bootstrap VM:

```bash
gcloud secrets list \
  --project="$GCP_PROJECT" \
  --filter="name~^orangeline__${DEPLOY_NAME}__(rds|valkey|app)$" \
  --format='table(name,labels)'

for id in \
  "orangeline__${DEPLOY_NAME}__rds" \
  "orangeline__${DEPLOY_NAME}__valkey" \
  "orangeline__${DEPLOY_NAME}__app"; do
  gcloud secrets versions list "$id" \
    --project="$GCP_PROJECT" \
    --filter='state=ENABLED' \
    --format='table(name,state,createTime)'
done

kubectl get clustersecretstore orangeline-gcp-secretmanager
kubectl -n "$GATEWAY_NAMESPACE" get externalsecret
kubectl -n "$GATEWAY_NAMESPACE" get \
  secret/gateway-secrets secret/router-secrets secret/worker-secrets
```

Do not run `gcloud secrets versions access` into a terminal transcript, ticket,
shell history, or CI log. Use [bootstrap/scripts/smoke-checks.sh](bootstrap/scripts/smoke-checks.sh)
for structural and readiness checks.

## Failure behavior

- Missing/denied Secret Manager access: ESO remains not Ready; gateway
  auto-deploy must stop.
- Missing app payload: runner creates missing keys once and writes a new secret
  version; it must preserve existing keys.
- Invalid Cloud SQL or Redis URL: public `/readyz` and dependency probes fail;
  correct through the reviewed infra deployment, not a hand-edited Kubernetes
  Secret.
- WIF error: fix the KSA/GSA principal and secret-level IAM. Do not create a
  service-account key.
- Disabled/destroyed secret version: restore/enable only after identifying why;
  do not guess which historical crypto version is safe.

Day-2 procedures: [secret-rotation.md](secret-rotation.md).
