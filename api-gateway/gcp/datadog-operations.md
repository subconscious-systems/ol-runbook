# Datadog operations (GCP API Gateway)

This deployment uses three complementary paths:

1. **Datadog GCP STS integration** for keyless Cloud Monitoring/asset metrics;
2. **Datadog Agent on GKE** for Kubernetes, warn/error logs, and gateway
   OpenMetrics (APM / OTLP off unless opted in);
3. **Cloud SQL PostgreSQL DBM** as a direct private database check.

Datadog API/application keys are masked infra Hub Secrets. They are not GCP
credentials and never belong in gateway Helm values or `gateway-secrets`.

## Keyless GCP STS integration

### Domain Restricted Sharing prerequisite

If `constraints/iam.allowedPolicyMemberDomains` is enforced, Datadog's
delegate cannot receive Token Creator until an organization policy
administrator allows Datadog's customer identity. Commercial Datadog sites,
including US5, use `C0147pk0i`; government sites use `C03lf3ewa`.

Prefer a project-level override on each gateway environment rather than
broadening the policy for the whole organization. Preserve every customer ID
already allowed by the effective policy and add the Datadog ID:

```bash
gcloud org-policies describe \
  constraints/iam.allowedPolicyMemberDomains \
  --project="$GCP_PROJECT" \
  --effective \
  --format=yaml

GCP_PROJECT_NUMBER="$(
  gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
)"
cat >domain-restricted-sharing.yaml <<EOF
name: projects/${GCP_PROJECT_NUMBER}/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
  - values:
      allowedValues:
      - EXISTING_CUSTOMER_ID
      - C0147pk0i
EOF
gcloud org-policies set-policy domain-restricted-sharing.yaml
```

Replace `EXISTING_CUSTOMER_ID` with the value from the effective policy; do
not remove the organization's existing identity. Setting the override requires
`roles/orgpolicy.policyAdmin`. The bootstrap service account receives only
`roles/orgpolicy.policyViewer`, and the infra runner fails before Terraform
mutation if the required Datadog identity is absent.

Create one dedicated integration service account per project, for example:

```text
datadog-integration@acme-gateway-prod.iam.gserviceaccount.com
```

The released infra Terraform should create the Datadog V2 GCP STS integration,
receive Datadog's delegate account email, and allow that delegate to impersonate
only this service account. No JSON key is created.

Minimum read roles in each monitored project:

- `roles/compute.viewer`;
- `roles/monitoring.viewer`;
- `roles/cloudasset.viewer`;
- `roles/cloudsql.viewer`;
- `roles/redis.viewer`;
- `roles/browser` only where required for project discovery;
- `roles/serviceusage.serviceUsageConsumer` for per-project Monitoring API
  quota attribution.

On the integration service account, grant Datadog's exact delegate principal
the impersonation role required by the selected Datadog provider/API release
(`roles/iam.serviceAccountTokenCreator` for the current STS Terraform
resource). Do not grant Token Creator project-wide.

Keep sandbox and production as separate Datadog integration accounts or
strictly filtered resource configs. Disable CSPM, Security Command Center, logs,
and unrelated product collection unless separately approved.

The integration default-denies the pinned Datadog namespace inventory and
enables only `cloudsql`, `compute`, `container`, `kubernetes`, `loadbalancing`,
`redis`, and `router`. Global-location collection remains enabled for GCE
Ingress/load-balancer metrics while regional collection is restricted to the
deployment region. Refresh the namespace inventory when upgrading the Datadog
provider because its API currently has no default-deny switch for future
namespaces.

Verify without tokens:

```bash
gcloud iam service-accounts keys list \
  --iam-account="$DATADOG_GCP_SERVICE_ACCOUNT"

gcloud iam service-accounts get-iam-policy \
  "$DATADOG_GCP_SERVICE_ACCOUNT" \
  --format=json | jq '.bindings'
```

Only Google-managed keys should exist. The impersonation binding should contain
only the Datadog delegate returned for the intended Datadog organization.

The infra runner also fails closed after apply unless:

- the service account has no user-managed keys;
- all seven project reader roles are present;
- Token Creator names exactly one Datadog STS delegate;
- the Datadog API reports this project in `accessible_projects`;
- only the allowlisted metric namespaces are enabled.

Datadog project discovery is asynchronous, so the runner retries this API proof
for up to ten minutes. The application key needs `gcp_configuration_read` in
addition to the manage permission used by Terraform.

## GKE Agent

The infra release installs a pinned Datadog Agent chart in a dedicated
namespace. Required settings:

- cluster name = infra `DEPLOY_NAME`;
- `env:<DATADOG_ENV>` and consistent `service`/`version` tags;
- ARM64-compatible Agent images;
- gateway/router/adapter OpenMetrics checks;
- APM/OTLP endpoints and metadata-only LLM Observability only when
  `DATADOG_APM_ENABLED` / `DATADOG_LLM_OBS_ENABLED` are true;
- secrets referenced from an operator-managed Kubernetes Secret, not plaintext
  values;
- tolerations/resources sized for two N4A nodes;
- no GPU checks in this gateway cluster.

Readiness:

```bash
kubectl -n datadog get daemonset,deploy,pods
kubectl -n datadog rollout status daemonset/datadog-agent --timeout=10m
kubectl -n datadog logs daemonset/datadog-agent -c agent --tail=200
kubectl -n datadog exec daemonset/datadog-agent -c agent -- \
  agent status
```

Names can vary by the pinned chart; use `kubectl -n datadog get all` before
selecting a pod. Do not paste `agent status` sections containing credentials
into a ticket without redaction.

## Cloud SQL metrics versus DBM

The STS integration reads Cloud SQL service metrics from Cloud Monitoring. DBM
is separate: an Agent cluster check connects to PostgreSQL over the private IP
and provides query/plan/wait-event visibility.

Stage DBM:

| Phase | Setting | Gate |
| --- | --- | --- |
| 1 | `DATADOG_GCP_CLOUD_METRICS_ENABLED=true` | Cloud SQL service metrics visible with correct project/env tags |
| 2 | `DATADOG_POSTGRES_DBM_PREREQUISITES_ENABLED=true` | `pg_stat_statements`, least-privilege DBM user, TLS trust, and secret sync ready |
| 3 | `DATADOG_POSTGRES_DBM_ENABLED=true` | Agent direct check healthy from GKE private network |
| 4 | `DATADOG_DATABASE_MONITORS_ENABLED=true` | Metrics populated; monitors remain draft during baseline |

The released prerequisite automation must:

- run `CREATE EXTENSION pg_stat_statements` (Cloud SQL already sets the related
  flags on this stack; that is online);
- create a non-superuser DBM role with only Datadog's documented monitoring
  grants (for example the appropriate `pg_monitor` access);
- generate/store its credential without printing it;
- sync it to the Datadog namespace, not the gateway Secret;
- require encrypted PostgreSQL transport over the private IP;
- avoid granting table data access beyond what documented DBM features need.

Do not hand-run broad `GRANT` statements from this runbook. Review the exact SQL
in the released bootstrap Job against the current
[Datadog PostgreSQL setup](https://docs.datadoghq.com/database_monitoring/setup_postgres/)
and Cloud SQL version before approval.

Useful Agent checks:

```bash
kubectl -n datadog exec deploy/datadog-cluster-agent -- \
  agent clusterchecks

kubectl -n datadog exec daemonset/datadog-agent -c agent -- \
  agent check postgres
```

Resolve the actual release names first. The check must report the private Cloud
SQL address, TLS, and no authentication/permission error without printing the
password.

## Managed dashboards and monitors

Search Datadog for:

```text
[<DATADOG_ENV>][managed] Subconscious API Gateway
```

Use `$env`, `$service`, `$model`, and `$request_id` template variables.
Production and sandbox must have different `DATADOG_ENV` values.

Recommended rollout:

1. `DATADOG_MONITORS_DRAFT=true` and
   `DATADOG_DATABASE_MONITORS_DRAFT=true`;
2. baseline for one to two weeks;
3. tune latency, error ratio, limiter, connection saturation, CPU/storage,
   Redis memory/evictions, and DBM thresholds;
4. set gateway monitors published;
5. publish database monitors only after DBM/Cloud Monitoring data is stable;
6. enable managed SLOs after alert behavior is accepted.

Key GCP-specific signals:

- GKE node/pod readiness, scheduling, ARM image pull failures, and control-plane
  operation health;
- Cloud SQL CPU, memory, disk, disk read/write ops, connections, failover,
  backup, PITR, and DBM query/wait behavior;
- Memorystore memory, CPU, connections, evictions, failover, and command
  latency;
- GCE Ingress backend health, 4xx/5xx, certificate and load-balancer latency;
- Cloud NAT allocation/port and dropped-packet errors;
- ESO reconciliation and gateway dependency readiness.

The managed GCP database group uses current Datadog metrics under
`gcp.cloudsql.database.*` and `gcp.redis.*`; it does not reuse AWS CloudWatch
queries. Terraform selects the GCP group and GCP-tagged monitors while keeping
AWS database assets out of the GCP plan.

### Slow queries

The managed GCP group charts Cloud SQL connections and disk read/write ops.
Cloud SQL IOPS scale with disk size (autoresize), so there is no fixed IOPS
page; use the disk ops widgets plus CPU/disk utilization.

Normalized query lists (literals stripped) are on the managed dashboard
**PostgreSQL engine** group after phase 3: **Slowest PostgreSQL queries
(normalized)** and **Most frequent PostgreSQL queries (normalized)**. For the
full list, open Datadog **APM > Database Monitoring > Query Metrics** and
filter `env:<DATADOG_ENV>`. Do not enable raw statement collection.

## LLM Observability and tenant debugging

The default path is metrics + Conversations + error logs. Trace Explorer and
LLM Observability stay empty unless Hub `DATADOG_APM_ENABLED=true` and
`DATADOG_LLM_OBS_ENABLED=true`. The gateway then emits metadata-only GenAI
spans. It does not capture full prompts/tool trees unless separately
instrumented on the client side. Correlate with conversation/session IDs and
environment/service tags.

Prometheus metrics intentionally avoid high-cardinality organization IDs. Use
gateway logs, dashboard Conversations/Usage, and limiter events for
tenant-specific debugging. Process logs default to `GATEWAY_LOG_LEVEL=WARN`.

## Day-2 integration changes

- Pin the Datadog provider and Agent chart in the infra release.
- Run infra with `GATEWAY_AUTO_DEPLOY=false` for STS/Agent/DBM-only changes.
- Review Terraform plans for delegate-account replacement. A changed delegate
  or Datadog organization is a stop condition.
- Keep DD application-key permissions limited to the managed assets and GCP
  integration operations the release uses.
- Rotate DD keys in Hub, redeploy the infra runner/Agent, verify intake, then
  revoke old keys. Never put them in Secret Manager app bundles.

## Common failures

| Symptom | First checks |
| --- | --- |
| No GCP metrics | STS integration account status, delegate impersonation binding, Monitoring Viewer, project/resource filters |
| Agent pending on all nodes | ARM64 image manifest, node taints, resources, image entitlement |
| `403` from Datadog API | Application-key scopes and Datadog organization/site |
| Cloud SQL metrics but no DBM | Direct private connectivity, DBM K8s Secret, TLS, database grants, `pg_stat_statements` |
| Duplicate hosts/envs | cluster name, `DATADOG_ENV`, integration resource filters |
| Database monitors No Data | Keep draft; confirm metric source and tags before publishing |

More diagnostics: [troubleshooting.md](troubleshooting.md).
