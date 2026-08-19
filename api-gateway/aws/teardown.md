# Tear down an AWS gateway platform

Permanently remove the Assisted Self-Managed AWS platform stack (VPC, EKS, RDS, Valkey, ACM, Secrets Manager shells, add-ons). This does not destroy the bootstrap EC2.

RDS snapshots are operator-owned. Take and retain a snapshot in AWS before you destroy if you need the data. The teardown script skips AWS's automatic final snapshot.

## Order

1. Optional: create or retain an RDS snapshot in the AWS console or CLI.
2. In Distr Hub, undeploy or pause the **gateway Helm** app so the Kubernetes agent does not reinstall it.
3. From `api-gateway/aws/bootstrap`, run the teardown script (fails if the gateway namespace still has gateway, adapter, or router Deployments; `distr-agent` is ignored).
4. In Distr Hub, undeploy or pause the **infra Docker** app so a later revision does not recreate the stack.
5. Optional: destroy the bootstrap EC2 after platform destroy has finished.

Keep the bootstrap host until step 3 succeeds. Platform Terraform uses that instance profile and the idle infra runner's Hub env.

## Teardown script

Prerequisites:

- Bootstrap Terraform applied (`./scripts/bootstrap.sh`) so terraform outputs resolve the EC2 instance
- Session Manager access from your laptop (aws CLI; interactive plugin not required)
- Infra Docker app still present/idle on the host (the script copies Hub env from the runner container)
- Gateway Helm app already undeployed in Hub

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

What it does on the bootstrap host:

- Refreshes kubeconfig for the EKS cluster
- Fails if `GATEWAY_DEPLOY_NAME` still has gateway, adapter, or router Deployments (`distr-agent` is ignored; missing namespace is OK)
- Disables RDS `deletion_protection` on `<INFRA_DEPLOY_NAME>-postgres`
- Runs `terraform destroy` against `api-gateway-infra/<INFRA_DEPLOY_NAME>/terraform.tfstate` with `rds_skip_final_snapshot=true`
- Leaves the account-global Datadog AWS integration, the tfstate bucket, and the bootstrap EC2 in place

This is not a Hub infra apply. Helm-facing Terraform replace stays fail-closed on the runner; destroy is this script only.

## Bootstrap EC2

After the platform is gone, from `api-gateway/aws/bootstrap`:

```bash
terraform destroy -auto-approve
```

That destroys only this host, not a platform stack that is already gone.
