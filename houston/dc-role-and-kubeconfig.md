# Houston per-DC wiring: role and kubeconfig

Houston is Subconscious's operator console. It runs in Subconscious's AWS account. This page tells the FDE what exists for each datacenter (DC) site and how to wire a new one.

## What exists per DC

| Item | Name | Purpose |
| --- | --- | --- |
| IAM role | `houston-dc-{dcId}` | The Houston worker assumes this role. The role can read and write the DC's bearer credentials in SSM and use the DC's KMS key. |
| SSM parameters | `/houston/dc-bearer/{dcId}/*` | Bearer credentials for the DC, stored as SecureString. The role above is the only path that reads or writes them. |
| SSM parameters | `/houston/dc-kubeconfig/{dcId}` | The kubeconfig for the DC's cluster, used by the DGD apply step. The worker reads it from SSM at deploy time; it is never on a laptop. |
| KMS key | dc-bearer key | One key in the Houston environment wraps all `/houston/dc-bearer/**` values. |

The first DC is `baseten-slack`, so its role is `houston-dc-baseten-slack`.

## How to wire a new DC

Do this when onboarding a customer DC that Houston will operate.

1. In the houston repo, edit `backend/terraform/core/iam.tf` and call the `runner-role` module with the new `dc_id`. Read the module file first; it takes only `dc_id`, the worker IRSA role, and the KMS key.
2. Set `tfvars` for the environment and run `backend/scripts/aws/terraform-deploy.sh apply`. The apply creates the role. It never contains a secret, so no extra step is needed.
3. Store the kubeconfig: `aws ssm put-parameter --name /houston/dc-kubeconfig/{dcId} --type SecureString --value "<kubeconfig yaml>"`. Run this with the operator session in the Houston account. Do not commit the kubeconfig anywhere.
4. The Houston worker reads the kubeconfig from SSM when it applies a site workflow to the DC cluster. No further setup is needed.

## Boundary rules

- The Houston API pods hold no SSM permissions at all.
- The worker IRSA role can only assume `houston-dc-*` roles and read `/houston/gateway-admin/*`. It has no other access.
- The CI role (`houston-ci`) can never write `/houston/dc-bearer/*`. A compromised CI token cannot mint DC bearer credentials.
- Bearer credentials expire after 2 days and re-mint on demand. Rotate by deleting the SSM parameter and letting the worker re-mint it.

See the houston repo design docs for the full model: `design/09_orangeline-deployment.md` covers the role and bearer flow.
