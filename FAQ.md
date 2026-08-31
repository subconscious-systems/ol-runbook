# FAQ

Common questions for deploying the Subconscious Inference System.

AWS: [architecture](api-gateway/aws/README.md) · [setup](api-gateway/aws/instructions.md) · [bootstrap](api-gateway/aws/bootstrap/) · [secrets](api-gateway/aws/gateway-secrets.md) · [rotation](api-gateway/aws/secret-rotation.md) · [rollback](api-gateway/aws/rollback.md) · [teardown](api-gateway/aws/teardown.md) · [troubleshooting](api-gateway/aws/troubleshooting.md).

GCP: [architecture and release gate](api-gateway/gcp/README.md) · [setup](api-gateway/gcp/instructions.md) · [bootstrap](api-gateway/gcp/bootstrap/) · [secrets](api-gateway/gcp/gateway-secrets.md) · [rotation](api-gateway/gcp/secret-rotation.md) · [rollback](api-gateway/gcp/rollback.md) · [teardown](api-gateway/gcp/teardown.md) · [troubleshooting](api-gateway/gcp/troubleshooting.md).

## Can I use the GCP runbook with any infra release?

No. The GCP runbook defines a complete production-parity contract, but the
selected `api-gateway-infra` Distr Application release must explicitly say its
full `CLOUD=gcp` path is enabled. A release whose runner still reports GCP as a
stub fails closed. Complete the sandbox dress rehearsal before production.

The GCP path is greenfield only: separate sandbox/production projects in
`us-east1`, no AWS data migration, and no GPU provisioning. See
[api-gateway/gcp/README.md](api-gateway/gcp/README.md).

## How should I name my deployments, namespaces, and releases?

Use a short readable slug and keep the Distr deployment names consistent:

| What | Name |
| --- | --- |
| Infra Distr Docker deployment (`api-gateway-infra`) | `{readable-slug}-api-gateway-infra` |
| Gateway cluster identity (`GATEWAY_DISTR_DEPLOYMENT_NAME`) | `{readable-slug}-api-gateway` |
| Kubernetes namespace | same as `GATEWAY_DISTR_DEPLOYMENT_NAME` |
| Helm release name | same as `GATEWAY_DISTR_DEPLOYMENT_NAME` |
| Hub Kubernetes target (optional `GATEWAY_DISTR_PORTAL_NAME`) | same as cluster identity unless the Hub target was renamed |

Example: slug `acme` → infra `acme-api-gateway-infra`, gateway/namespace/release `acme-api-gateway`.

It is rare to need more than one deployment of the infra package or the api-gateway chart. If you do, use a different readable slug for each stack. The same rule applies to the public hostname where the api-gateway dashboard is hosted (`DOMAIN_NAME`): each deploy needs its own unique hostname.

Terraform state keys and Datadog `env` (defaults from the infra `DEPLOY_NAME` unless you set `DATADOG_ENV`) are derived from the names you provide. Gateway **cluster** secrets live in AWS Secrets Manager (`orangeline/{infra-name}/rds|valkey|app`) and sync into the cluster via External Secrets Operator - not Distr Hub keys for DB/Redis/crypto. Details: [api-gateway/aws/gateway-secrets.md](api-gateway/aws/gateway-secrets.md).

On GCP the same logical bundles map to Secret Manager IDs such as
`orangeline__{infra-name}__rds|valkey|app` and sync through ESO with Workload
Identity Federation. Sandbox and production use independent projects and
secret versions. Details:
[api-gateway/gcp/gateway-secrets.md](api-gateway/gcp/gateway-secrets.md).

Keep each Distr deployment name **32 characters or fewer**. Longer names can hit cloud resource id limits (especially cache replication group ids).

The infra runner treats `GATEWAY_DISTR_DEPLOYMENT_NAME` as the Kubernetes namespace and Helm release. Do not rename the live release or namespace independently of that field.

Greenfield can use one name for the Hub Kubernetes target, namespace, and Helm release. If you later rename the Hub target for sorting (for example `subconscious-gcp-gateway` → `gcp-gateway`), set `GATEWAY_DISTR_PORTAL_NAME` to the new Hub name and leave `GATEWAY_DISTR_DEPLOYMENT_NAME` as the live namespace. Changing `GATEWAY_DISTR_DEPLOYMENT_NAME` moves Terraform/ESO into a new namespace.

Auto-deploy looks up the Kubernetes target named `GATEWAY_DISTR_PORTAL_NAME` (empty means `GATEWAY_DISTR_DEPLOYMENT_NAME`) and still `PUT`s Helm `releaseName` as `GATEWAY_DISTR_DEPLOYMENT_NAME`. If Hub lists deployments by Helm release name rather than target name, that UI label may snap back on the next auto-deploy.

`VPC_CIDR` stays an explicit field: choose a `/16` that does not overlap other VPCs in the account (important if you later peer or share routing). It is not auto-detected today.

## Do I need a manual api-gateway deploy before infra works?

No live gateway on the cluster is required for Terraform or SM/ESO secret prep.

You need:

- The published **api-gateway Helm Application** in Distr (leave `DISTR_GATEWAY_APPLICATION_ID` as the default unless forking)
- For auto-deploy: a Kubernetes deployment **target** named `GATEWAY_DISTR_PORTAL_NAME` if set, otherwise `GATEWAY_DISTR_DEPLOYMENT_NAME` (after the K8s agent connects), and `GATEWAY_CHART_VERSION` set (see below)

Practical greenfield path: first infra deploy with `GATEWAY_AUTO_DEPLOY=false`
(platform + secrets) → connect K8s agent → second infra deploy with
`GATEWAY_AUTO_DEPLOY=true` and `GATEWAY_CHART_VERSION=latest`. See
[instructions.md](api-gateway/aws/instructions.md).

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

## How do I add another public hostname to the AWS gateway ALB?

Use the AWS-only alias fields on the **infra** Docker deployment:

| Hub field | Notes |
| --- | --- |
| `GATEWAY_EXTRA_INGRESS_HOSTS` | Comma or JSON list of additional hostnames routed to the existing gateway Service. |
| `GATEWAY_EXTRA_ACM_CERTIFICATE_ARNS` | Comma or JSON list of issued ACM certificate ARNs in the ALB's AWS region. |

For a hostname whose DNS is authoritative outside Route 53, request a separate
ACM certificate in the ALB's region and publish ACM's validation CNAME with the
authoritative DNS provider. Keep that validation record permanently for ACM
renewal. Do not add the alias to the primary Terraform-managed certificate or
to `GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES`.

The generated Ingress keeps `DOMAIN_NAME` as the only external-dns hostname,
adds the aliases as host rules, and attaches the primary and extra certificates
to the ALB listener. Empty alias fields retain the original single-host
behavior. Configure these fields instead of editing the live Ingress or ALB:
the next auto-deploy replaces manual changes.

Before changing public DNS, resolve the alias directly to the ALB and verify
valid TLS plus a gateway response. Then change the alias's traffic record with
its authoritative provider. Roll back by restoring that record; the additional
ALB rule and certificate may remain attached safely.

## How is the initial dashboard admin created?

Not by Terraform. Prefer the api-gateway chart **identity-bootstrap** Job:

1. Create a Hub Secret for the bootstrap password (12+ chars)
2. Reference it from the infra env (see `sample-gateway-infra.env` / `DASHBOARD_BOOTSTRAP_PASSWORD`)
3. On gateway install, the Job bootstraps the admin using the password in the cluster `gateway-secrets` (via SM/ESO)

Idempotent for existing users (password is **not** rotated on re-run). Break-glass: `ops-cli identity bootstrap` with cluster access. See [troubleshooting.md](api-gateway/aws/troubleshooting.md).

The gateway base URL (`https://<DOMAIN_NAME>/`) redirects to `/dashboard`. Day-0
login uses the bootstrap password; day-2 operators can use corporate SSO after
you enable OIDC and invite them (see below).

## How do I enable dashboard SSO (Okta / Entra ID)?

Dashboard login supports OpenID Connect (OIDC). Inference APIs still use org API
keys. Invite users (or create accounts) before first SSO login — there is no open
JIT provisioning.

- Okta: [api-gateway/sso-okta.md](api-gateway/sso-okta.md)
- Microsoft Entra ID: [api-gateway/sso-entra.md](api-gateway/sso-entra.md)

Password login remains available as break-glass for the bootstrap admin.

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

Operations guides: [AWS](api-gateway/aws/datadog-operations.md) ·
[GCP STS/Agent/Cloud SQL DBM](api-gateway/gcp/datadog-operations.md).

## How do I control gateway log volume?

Set Hub `GATEWAY_LOG_LEVEL` (default `WARN`). That one field sets gateway,
adapter, and router together. `WARN` ships exceptions only. `INFO` ships one
`gateway.request.completed` JSON line per request. GPU workers use
`worker.sglang.logLevel: warning` on their own chart.

`DATADOG_ENABLED=true` does **not** turn on APM traces or LLM Observability.
Those stay off unless `DATADOG_APM_ENABLED` / `DATADOG_LLM_OBS_ENABLED`.

## How do I rotate gateway secrets?

App csrf and credential encryption: copy-paste from [api-gateway/aws/secret-rotation.md](api-gateway/aws/secret-rotation.md) (`bootstrap/scripts/rotate-app-secret.sh`). RDS/Valkey URLs: new infra deploy. Org API keys and worker endpoint keys: dashboard (same doc).

For GCP, use
[api-gateway/gcp/secret-rotation.md](api-gateway/gcp/secret-rotation.md). It
uses the keyless bootstrap/IAP path for app keys, overlapping Cloud SQL users,
and blue/green Redis replacement because Memorystore cannot overlap old/new
AUTH strings.

## Infra Hub field cheatsheet

| Field | Notes |
| --- | --- |
| `DEPLOY_NAME` | Infra Distr deploy + TF/EKS name_prefix |
| `GATEWAY_DISTR_DEPLOYMENT_NAME` | Gateway K8s namespace + Helm release |
| `GATEWAY_DISTR_PORTAL_NAME` | Optional Hub Kubernetes target name; empty = `GATEWAY_DISTR_DEPLOYMENT_NAME` |
| `DOMAIN_NAME` / `DNS_ZONE_NAME` | Public hostname + existing Route 53 zone |
| `VPC_CIDR` | Non-colliding VPC `/16` (explicit; not auto-detected) |
| `DATADOG_ENABLED` / `DATADOG_ENV` | Sample path: on; env facet for titles/monitors/filters. Does not turn on OTLP/APM |
| `GATEWAY_LOG_LEVEL` | Default `WARN` (gateway + adapter + router). `INFO` = one `request.completed` line per call |
| `DATADOG_APM_ENABLED` | Default `false`. Opt in to in-cluster OTLP traces |
| `DATADOG_LLM_OBS_ENABLED` | Default `false`. Requires `DATADOG_APM_ENABLED` |
| `DATADOG_DASHBOARD_TAGS` | Optional; default `team:api-gateway` |
| `DATADOG_MONITORS_DRAFT` | Draft vs published monitors only |
| `DATADOG_SLOS_ENABLED` | Managed availability + TTFT SLOs (default off) |
| `GATEWAY_AUTO_DEPLOY` | Default false; enable only for a separate gateway rollout |
| `GATEWAY_CHART_VERSION` | `latest` (default), `nochange`, or `0.n.n` |
| `GATEWAY_ROUTE_ALLOWED_HOST_SUFFIXES` | Provider DNS suffixes; `svc.cluster.local` always added |
| `GATEWAY_EXTRA_INGRESS_HOSTS` | AWS-only public aliases routed by the existing ALB |
| `GATEWAY_EXTRA_ACM_CERTIFICATE_ARNS` | AWS-only issued ACM certificates for those aliases |
| `DISTR_GATEWAY_APPLICATION_ID` | Defaulted to Subconscious-published api-gateway app |
| `DISTR_GATEWAY_APPLICATION_VERSION_ID` | Rare UUID override; prefer `GATEWAY_CHART_VERSION` |
| `DASHBOARD_BOOTSTRAP_PASSWORD` | Optional; enables identity-bootstrap Job |

Full template comments: shipped with the infra Application as `runner/template.env`.
