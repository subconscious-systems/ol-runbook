# Teardown (AWS)

Teardown permanently removes an environment in reverse dependency order.

Teardown production only after traffic has moved, retention/export decisions
are approved, and an independent operator has verified the target account.

- Point traffic off of the deployment.
- Take a snapshot of the DB if desired
- Undeploy the gateway Helm Application through Distr.
- Run the teardown script to destroy the platform.
- Undeploy the infra application through Distr.
- Teardown the bootstrap EC2 terraform.

Keep the bootstrap host until the teardown script succeeds. The script
disables RDS deletion protection and skips AWS's automatic final snapshot;
take and retain a snapshot in AWS first if you need the data.

Copy-paste (from `api-gateway/aws/bootstrap`):

```bash
./scripts/teardown-platform.sh --yes <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
```

Example:

```bash
./scripts/teardown-platform.sh --yes awsgateway-api-gateway-infra awsgateway-api-gateway
```

| Arg | Meaning |
| --- | --- |
| `--yes` | Required. Refuses to destroy without it. |
| `INFRA_DEPLOY_NAME` | Infra Distr Docker / Terraform name prefix (EKS cluster name). Must match Hub `DEPLOY_NAME`. |
| `GATEWAY_DEPLOY_NAME` | Gateway Distr Helm deploy name / Kubernetes namespace |

Optional: `RUNNER_IMAGE=registry.distr.sh/subconscious/api-gateway-infra/runner:<tag>` if image discovery fails.

The script fails if `GATEWAY_DEPLOY_NAME` still has gateway, adapter, or
router Deployments. `distr-agent` is ignored. Missing namespace is OK.

After the platform is gone, from `api-gateway/aws/bootstrap`:

```bash
terraform destroy -auto-approve
```

That destroys only this host, not a platform stack that is already gone.
