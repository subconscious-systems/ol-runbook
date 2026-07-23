# Troubleshooting (AWS API Gateway)

Common failure modes for Assisted Self-Managed AWS deploys.

Architecture: [README.md](README.md) · Setup: [instructions.md](instructions.md) · Secrets: [gateway-secrets.md](gateway-secrets.md) · Rotation: [secret-rotation.md](secret-rotation.md) · Bootstrap: [bootstrap/](bootstrap/).

## Day-0 / Distr

### `entitlement required` / registry pull denied

The Docker agent is connected, but the customer org cannot pull `registry.distr.sh/.../api-gateway-infra/runner` (or gateway images).

This is **not** fixed by creating a Docker or Kubernetes deployment target.

Vendor portal → **Licenses** → customer → grant:

1. Application entitlement for **api-gateway-infra** (and later **api-gateway**)
2. Artifact entitlement including the runner image, chart, and gateway images

Confirm the compose/chart tags were published.

### Runner `Exited (1)` / healthcheck confusion

Two different signals:

1. **`Exited (1)`**: entrypoint failed before idle. Hub may loop “not in running state” because Distr re-runs `compose up`. Common causes: Terraform apply failure (including Datadog metric-tag 409 / dashboard tag policy). Secrets are ensured only **after** a successful apply.
2. Health can pass while Terraform is still running; exit 1 afterward means apply (or a later step) failed.

Missing K8s agent target does **not** hard-fail the runner. Keep
`GATEWAY_AUTO_DEPLOY=false` until the target exists; if enabled early,
auto-deploy soft-skips.

#### Debug on the bootstrap EC2

```bash
cd api-gateway/aws/bootstrap
./scripts/connect.sh <DEPLOY_NAME>   # SSM shell + kubeconfig refresh
# or: ./scripts/connect.sh           # SSM shell only
```

On the box:

```bash
export HOME=/root KUBECONFIG=/root/.kube/config
docker ps -a --filter name=runner
docker logs --tail 200 distr-*-runner-1
# look for terraform Error: / [runner] ERROR

kubectl -n <GATEWAY_DISTR_DEPLOYMENT_NAME> get pods,deploy,svc
kubectl -n <GATEWAY_DISTR_DEPLOYMENT_NAME> logs deploy/<name> --tail=200
```

### Datadog metric-tag ensure failed / flaky API

Terraform runs a Datadog metric-tag ensure script during apply. 409 / rate-limit / timeout failures can fail the whole infra run. Re-run the infra job; upserts are idempotent. Secrets are ensured only after a successful apply.

### Why can’t I just kubectl from my laptop?

Day-0 EKS API is CIDR-locked to the bootstrap host EIP. Your laptop is not on that path by default. Use `./scripts/connect.sh` and run `kubectl` **on the bootstrap host**. Day-0 dashboard admin should use the identity-bootstrap Job, not kubectl (see [FAQ.md](../../FAQ.md#how-is-the-initial-dashboard-admin-created)).

### First run / second infra deploy

First infra run builds the platform and prepares SM/ESO secrets with
`GATEWAY_AUTO_DEPLOY=false`. Connect the K8s target with
`connect-k8s-agent.sh <DEPLOY_NAME> '<Hub command>'`; the explicit first
argument selects the EKS cluster and the Hub command supplies the separate
gateway namespace. Then trigger a **second** infra deploy with
`GATEWAY_AUTO_DEPLOY=true` and `GATEWAY_CHART_VERSION=latest`.

The first **empty** api-gateway Helm deploy (before the K8s agent) is **expected to fail / do nothing**.

### Second infra / gateway auto-deploy

Fragment generation, ESO sync timing, Ingress/DNS, and Datadog asset conflicts often need a re-run or Hub/env tweak. Prefer fixing infra env fields. Hub hand-edits to gateway Helm overrides are overwritten on the next auto-deploy.

### EKS API from your laptop

Day-0 EKS API is CIDR-locked to the bootstrap host EIP. Use `./scripts/connect.sh` and run `kubectl` **on that host**, not from your laptop (unless you deliberately add your IP to `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS`).

### Naming limits

Keep Distr deployment names **32 characters or fewer**. Release name, namespace, and K8s target must equal `GATEWAY_DISTR_DEPLOYMENT_NAME`. See [FAQ.md](../../FAQ.md).

## Secrets / bootstrap

- Cluster SoT is AWS Secrets Manager + ESO ([gateway-secrets.md](gateway-secrets.md)). Manual gateway Helm before `gateway-secrets` exists leads to migrate Job / readiness failures.
- Day-2 rotation (csrf, encryption, RDS/Valkey redeploy, org and worker keys): [secret-rotation.md](secret-rotation.md).
- Identity-bootstrap Job password is **not** rotated on re-run. Break-glass: `ops-cli identity bootstrap` from a gateway pod when needed.
- Forbidden: AWS keys in Hub; Datadog keys in gateway Helm secrets; vendor publish token as customer `DISTR_TOKEN`.

## Database / release rollback

Prefer **roll-forward** for schema when the running app can tolerate the current schema.

### Schema revert

Use only for a bad reversible migration that is already applied and unsafe to leave in place.

- Scale down or stop new-schema consumers first.
- Confirm the `.down.sql` is present in the running gateway image.

```bash
kubectl -n "$NAMESPACE" exec deploy/"$RELEASE"-gateway -- \
  ops-cli migrate-revert --target 1
```

Then restart/roll pods as needed and re-check dashboard login, `/readyz`, and authenticated inference.

### Helm rollback (distinct from DB revert)

Do not use Helm rollback. It breaks the Distr kubernets agent. Use the Distr Hub to rollback the gateway Helm app desired version. This is why you must revert the DB first (where down migrations are present with the new version) and then push update the application.

Work with your FDE in the event of a rollback with a DB migration. They may elect to push a hot-fix instead.

### RDS / bootstrap destroy notes

- Platform RDS day-0 defaults typically include backup retention, deletion protection, and a final snapshot on destroy.
- `terraform destroy` in [bootstrap/](bootstrap/) only destroys the Docker-agent EC2 host, **not** the platform VPC/EKS/RDS created by the infra runner.
