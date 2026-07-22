# FAQ

Common questions for deploying the Subconscious Inference System.

## How should I name my deployments, namespaces, and releases?

Use a short readable slug and keep the Distr deployment names consistent:

| What | Name |
| --- | --- |
| Infra Distr Docker deployment (`api-gateway-infra`) | `{readable-slug}-api-gateway-infra` |
| Gateway Distr Helm deployment (`api-gateway`) | `{readable-slug}-api-gateway` |
| Kubernetes namespace | `{readable-slug}-api-gateway` |
| Helm release name | `{readable-slug}-api-gateway` |

Example: slug `acme` → infra `acme-api-gateway-infra`, gateway/namespace/release `acme-api-gateway`.

It is rare to need more than one deployment of the infra package or the api-gateway chart. If you do, use a different readable slug for each stack. The same rule applies to the public hostname where the api-gateway dashboard is hosted (`DOMAIN_NAME`): each deploy needs its own unique hostname.

Terraform state keys, Datadog `env` (defaults from the infra `DEPLOY_NAME` unless you set `DATADOG_ENV`), and Distr Hub secrets are derived from the names you provide. Hub secrets for the gateway look like `{readable-slug}-api-gateway_GATEWAY_DATABASE_URL` (deploy-scoped and cloud-agnostic).

Keep each Distr deployment name **32 characters or fewer**. Longer names can hit cloud resource id limits (especially cache replication group ids).

The infra runner sets Helm `fullnameOverride` to the gateway deploy name and assumes the Distr Helm **release name** equals that same name (and the Kubernetes namespace). Do not rename the release independently of `GATEWAY_DISTR_DEPLOYMENT_NAME`.

`VPC_CIDR` stays an explicit field: choose a `/16` that does not overlap other VPCs in the account (important if you later peer or share routing). It is not auto-detected today.

See [api-gateway/aws/sample-gateway-infra.env](api-gateway/aws/sample-gateway-infra.env) for an Assisted Self-Managed AWS example.
