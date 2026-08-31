# Teardown (GCP)

Teardown permanently removes the production platform in reverse dependency
order.

Teardown production only after traffic has moved, retention/export decisions
are approved, and an independent operator has verified the target project.

- Point traffic off of the deployment.
- Take a snapshot of the DB if desired
- Undeploy the gateway Helm Application through Distr.
- Run the teardown script to destroy the platform.
- Undeploy the infra application through Distr.
- Teardown the infra-application terraform.

Copy-paste (from `api-gateway/gcp/bootstrap`):

```bash
./scripts/teardown-platform.sh --yes <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
```

Example:

```bash
./scripts/teardown-platform.sh --yes acme-api-gateway-infra acme-api-gateway
```

| Arg | Meaning |
| --- | --- |
| `--yes` | Required. Refuses to destroy without it. |
| `INFRA_DEPLOY_NAME` | Infra Distr Docker / Terraform name prefix. GKE is `<name>-gke`. Must match Hub `DEPLOY_NAME`. |
| `GATEWAY_DEPLOY_NAME` | Gateway Distr Helm deploy name / Kubernetes namespace |

Optional: `RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>` if image discovery fails.

The script fails if `GATEWAY_DEPLOY_NAME` still has gateway, adapter, or
router Deployments. `distr-agent` is ignored. Missing namespace is OK.
Confirm Cloud SQL backup/PITR requirements before you run it; the script does
not create an extra snapshot.
