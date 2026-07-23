# FAQ

Common questions for deploying the Subconscious Inference System.

Architecture and setup: [api-gateway/aws/README.md](api-gateway/aws/README.md) · [api-gateway/aws/instructions.md](api-gateway/aws/instructions.md). Day-0 host: [api-gateway/aws/bootstrap/](api-gateway/aws/bootstrap/). Secrets: [api-gateway/aws/gateway-secrets.md](api-gateway/aws/gateway-secrets.md). Rotation: [api-gateway/aws/secret-rotation.md](api-gateway/aws/secret-rotation.md). Troubleshooting: [api-gateway/aws/troubleshooting.md](api-gateway/aws/troubleshooting.md). Example env: [api-gateway/aws/sample-gateway-infra.env](api-gateway/aws/sample-gateway-infra.env).

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

Terraform state keys and Datadog `env` (defaults from the infra `DEPLOY_NAME` unless you set `DATADOG_ENV`) are derived from the names you provide. Gateway **cluster** secrets live in AWS Secrets Manager (`orangeline/{infra-name}/rds|valkey|app`) and sync into the cluster via External Secrets Operator - not Distr Hub keys for DB/Redis/crypto. Details: [api-gateway/aws/gateway-secrets.md](api-gateway/aws/gateway-secrets.md).

Keep each Distr deployment name **32 characters or fewer**. Longer names can hit cloud resource id limits (especially cache replication group ids).

The infra runner sets Helm `NamespaceOverride` to the gateway deploy name and assumes the Distr Helm **release name** equals that same name (and the Kubernetes namespace). Do not rename the release independently of `GATEWAY_DISTR_DEPLOYMENT_NAME`.

`VPC_CIDR` stays an explicit field: choose a `/16` that does not overlap other VPCs in the account (important if you later peer or share routing). It is not auto-detected today.

## Do I need a manual api-gateway deploy before infra works?

No live gateway on the cluster is required for Terraform or SM/ESO secret prep.

You need:

- The published **api-gateway Helm Application** in Distr (leave `DISTR_GATEWAY_APPLICATION_ID` as the default unless forking)
- For auto-deploy: a Kubernetes deployment **target** named `GATEWAY_DISTR_DEPLOYMENT_NAME` (after the K8s agent connects) and `GATEWAY_CHART_VERSION` set (see below)

Practical greenfield path: first infra deploy (platform + secrets; auto-deploy may soft-skip) → connect K8s agent → second infra deploy with `GATEWAY_CHART_VERSION=latest`. See [instructions.md](api-gateway/aws/instructions.md).

## How do I choose the gateway chart version?

Set `GATEWAY_CHART_VERSION` on the **infra** Docker deployment (not a Distr UUID):

| Value | When to use |
| --- | --- |
| `latest` | Default - newest non-archived entitled version via Distr API |
| `nochange` | Keep whatever version is already on the gateway deploy (fails if none exists) |
| `0.n.n` | Pin a published Distr version **name** (chart/semver tag) |
| (rare) `DISTR_GATEWAY_APPLICATION_VERSION_ID` | Absolute UUID override; wins over `GATEWAY_CHART_VERSION` |

Empty `GATEWAY_CHART_VERSION` is an error when auto-deploy is on.

`GATEWAY_CHART_VERSION` only selects the Distr application **version**. Helm override YAML is **always regenerated** by the infra runner on auto-deploy. Hub UI edits to gateway values are overwritten. Put lasting customizations on the infra env / fragment path, or set `GATEWAY_AUTO_DEPLOY=false`.

When `GATEWAY_AUTO_DEPLOY=true`, every successful infra apply re-`PUT`s the gateway deployment (not change-aware). Use `GATEWAY_AUTO_DEPLOY=false` for infra-only runs.

## If auto-deploy is off, are cluster secrets still prepared?

Yes. After apply the runner still ensures the AWS Secrets Manager `app` secret and waits for ESO to sync `gateway-secrets`. The composed values fragment is pushed to Distr only when auto-deploy runs. Manual gateway Helm before `gateway-secrets` exists will fail readiness; wait for a successful infra apply first. See [gateway-secrets.md](api-gateway/aws/gateway-secrets.md).

## How do I set provider route allowlists?

Production installs with the adapter require external downstream DNS suffixes. Set this on the **infra** Docker deployment (auto-deploy overwrites hand-edited gateway Helm values):

| Hub field | Notes |
| --- | --- |
| `GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES` | Comma or JSON. Matches the suffix and any subdomain. `svc.cluster.local` is always added. |

At least one **external** suffix is required (`svc.cluster.local` alone fails).

```bash
GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES=customer.example,api.baseten.co
```

That allows `l4-a.customer.example`, `g6-b.customer.example`, etc.

## How is the initial dashboard admin created?

Not by Terraform. Prefer the api-gateway chart **identity-bootstrap** Job:

1. Create a Hub Secret for the bootstrap password (12+ chars)
2. Reference it from the infra env (see `sample-gateway-infra.env` / `DASHBOARD_BOOTSTRAP_PASSWORD`)
3. On gateway install, the Job bootstraps the admin using the password in the cluster `gateway-secrets` (via SM/ESO)

Idempotent for existing users (password is **not** rotated on re-run). Break-glass: `ops-cli identity bootstrap` with cluster access. See [troubleshooting.md](api-gateway/aws/troubleshooting.md).

## How do I tag Datadog so I can filter dashboards and metrics?

Set `DATADOG_ENV` (defaults to `DEPLOY_NAME` when empty). That value is applied as:

- Agent tag `env:<DATADOG_ENV>`
- Monitor names prefixed with `[<DATADOG_ENV>]`, queries scoped to `env:<DATADOG_ENV>`
- Dashboard title `[<DATADOG_ENV>][managed] …`
- Log pipeline + gateway Helm UST / `ENVIRONMENT` via the fragment

Two gateways in one Datadog org get distinct monitors/dashboards/pipelines. Filter telemetry with `env:<your-value>`.

Optional Hub overrides:

- `DATADOG_DASHBOARD_TAGS`: default `team:api-gateway` (some sites restrict keys)
- `DATADOG_RESOURCE_TAGS`: extra monitor tags when set
- `DATADOG_MONITORS_DRAFT`: `true` creates monitors as draft (no alerts until published)

Metric tag *configurations* (allowlisted tag keys on metric names) are org-global and shared (intentional). Deploy isolation is via tag *values* (`env`, `service`).

## How do I rotate gateway secrets?

App csrf and credential encryption: copy-paste from [api-gateway/aws/secret-rotation.md](api-gateway/aws/secret-rotation.md) (`bootstrap/scripts/rotate-app-secret.sh`). RDS/Valkey URLs: new infra deploy. Org API keys and worker endpoint keys: dashboard (same doc).

## Infra Hub field cheatsheet

| Field | Notes |
| --- | --- |
| `DEPLOY_NAME` | Infra Distr deploy + TF/EKS name_prefix |
| `GATEWAY_DISTR_DEPLOYMENT_NAME` | Gateway Helm deploy + K8s namespace/release |
| `DOMAIN_NAME` / `DNS_ZONE_NAME` | Public hostname + existing Route 53 zone |
| `VPC_CIDR` | Non-colliding VPC `/16` (explicit; not auto-detected) |
| `DATADOG_ENABLED` / `DATADOG_ENV` | Sample path: on; env facet for titles/monitors/filters |
| `DATADOG_DASHBOARD_TAGS` | Optional; default `team:api-gateway` |
| `DATADOG_MONITORS_DRAFT` | Draft vs published monitors only |
| `GATEWAY_AUTO_DEPLOY` | Default true; soft-skips until K8s target exists |
| `GATEWAY_CHART_VERSION` | `latest` (default), `nochange`, or `0.n.n` |
| `GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES` | Provider DNS suffixes; `svc.cluster.local` always added |
| `DISTR_GATEWAY_APPLICATION_ID` | Defaulted to Subconscious-published api-gateway app |
| `DISTR_GATEWAY_APPLICATION_VERSION_ID` | Rare UUID override; prefer `GATEWAY_CHART_VERSION` |
| `DASHBOARD_BOOTSTRAP_PASSWORD` | Optional; enables identity-bootstrap Job |

Full template comments: shipped with the infra Application as `runner/template.env`.
