# Secret rotation (AWS)

Day-2 rotation for Assisted Self-Managed API Gateway on AWS.

Cluster layout and SM paths: [gateway-secrets.md](gateway-secrets.md). Break-glass kubectl: [bootstrap/](bootstrap/) `./scripts/connect.sh`. Architecture: [README.md](README.md).

## App secrets (csrf and encryption)

App crypto and CSRF live in AWS Secrets Manager `orangeline/{INFRA_DEPLOY_NAME}/app`, sync via External Secrets into `gateway-secrets`, and support dual-key `_PREVIOUS` during rotation.

Use the bootstrap wrapper (same SSM path as `connect.sh`). It refreshes kubeconfig on the Docker-agent host and runs the entitled infra runner image’s rotate script.

Prerequisites:

- Bootstrap Terraform applied (`./scripts/bootstrap.sh`) so terraform outputs resolve the EC2 instance
- Session Manager access from your laptop (aws CLI; interactive plugin not required for this script)
- Entitled `api-gateway-infra` runner image already pulled on the host (from a prior infra deploy), or set `RUNNER_IMAGE`

Copy-paste (from `api-gateway/aws/bootstrap`):

```bash
./scripts/rotate-app-secret.sh csrf <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
./scripts/rotate-app-secret.sh encryption <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
```

Example:

```bash
./scripts/rotate-app-secret.sh csrf awsgateway-api-gateway-infra awsgateway-api-gateway
./scripts/rotate-app-secret.sh encryption awsgateway-api-gateway-infra awsgateway-api-gateway
```

| Arg | Meaning |
| --- | --- |
| `INFRA_DEPLOY_NAME` | Infra Distr Docker / Terraform name prefix (EKS cluster name; SM path `orangeline/{name}/app`) |
| `GATEWAY_DEPLOY_NAME` | Gateway Distr Helm deploy name / Kubernetes namespace |

What each does:

| Mode | Effect |
| --- | --- |
| `csrf` | Rotates dashboard CSRF secret with dual-key grace (default 30 minutes before clearing `_PREVIOUS`) |
| `encryption` | Rotates credential encryption key, runs a one-off `ops-cli reencrypt-credentials` Job, then clears `_PREVIOUS` |

Optional: `RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>` if discovery from a running `*runner*` container fails.

### Verify

- **csrf**: dashboard login works after the roll (and still works after `_PREVIOUS` is cleared). Re-login may be required when previous is cleared.
- **encryption**: an existing org API key still authenticates, and/or dashboard provider credentials / Quick Chat still work with `_PREVIOUS` empty.

If the re-encrypt Job fails, `_PREVIOUS` is left in place so decrypt keeps working. Fix the Job (logs under `job/gateway-reencrypt-credentials` in the gateway namespace), then re-run or clear previous only after ciphertext is rewritten.

## RDS Postgres and ElastiCache Valkey

Database and Redis URLs come from `orangeline/{INFRA_DEPLOY_NAME}/rds` and `…/valkey`, not the app crypto JSON. Rotate them by applying a **new infra deploy** so Terraform refreshes the managed secret material, ESO syncs `gateway-secrets`, then roll gateway/adapter pods as needed. Pair with your FDE for change windows; there is no separate rotate script for these URLs.

Confirm ExternalSecrets are synced and pods are ready after the deploy.

## Org API keys

Rotate from the **dashboard** (API keys UI): create or rotate a key, update clients during the grace window, then revoke the old key when traffic has moved. Day-0 org keys are not stored as Hub cluster secrets.

## Worker endpoint keys

Per-endpoint worker bearers live in the gateway DB (not the SM `SGLANG_WORKER_API_KEY` placeholder). Rotate in the dashboard:

1. Generate a new worker endpoint key
2. Put it in the worker Distr Hub secret your GPU deploy uses
3. Redeploy the worker
4. Revoke the old active key

See [gpu-deployment/README.md](../../gpu-deployment/README.md) for worker deploy context.
