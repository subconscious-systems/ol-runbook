# Datadog operations (AWS API Gateway)

How to use the managed Datadog assets provisioned by **api-gateway-infra** when
`DATADOG_ENABLED=true`.

Related: [instructions.md](instructions.md) · [troubleshooting.md](troubleshooting.md) ·
[gateway-secrets.md](gateway-secrets.md) · [FAQ.md](../../FAQ.md) ·
[GPU deployment](../../gpu-deployment/README.md) (worker Agent / GPU Health only).

## Landing page

Open Datadog and search for the managed dashboard:

```text
[<DATADOG_ENV>][managed] Subconscious API Gateway
```

`DATADOG_ENV` defaults to `DEPLOY_NAME` when empty. Use dashboard template
variables:

| Variable | Purpose |
| --- | --- |
| `$env` | Scope to this deploy (`env:<DATADOG_ENV>`) |
| `$service` | Gateway / router / adapter service name |
| `$model` | Logical model filter |
| `$request_id` | Drill into correlated request logs |

The Overview group shows **Gateway RPS** plus **Requests / minute** and
**Requests / hour** count widgets so you can read request volume at three time
scales without rebuilding the query.

## What pages (monitors)

Monitors are prefixed `[<DATADOG_ENV>]` and link to
[troubleshooting.md](troubleshooting.md). First checks by symptom:

| Monitor | Symptom | First checks |
| --- | --- | --- |
| GatewayErrorBudgetBurnPage | Sustained 5xx burn | Dashboard 5xx ratio, recent error logs, dependency health |
| GatewayHighErrorRatio | Elevated 5xx | Same; check router/adapter panels |
| GatewayNotReady | `/readyz` failing | Dependency health widget, Postgres/Valkey/Router readiness |
| GatewayDependencyDown | Postgres, Valkey, or router probe down | Managed databases group (if enabled), dependency widget |
| GatewayStreamingTtftP95High | Slow streaming first token | Inference path panels, TTFT SLO (if enabled) |
| GatewayRequestLatencyP95High | Slow end-to-end requests | Gateway latency group, router/adapter latency |
| GatewayLimiterRejectionsSustained | Rate limits firing | Tenant signals group, Valkey CloudWatch (if enabled) |
| GatewayLimiterCheckLatencyHigh | Limiter checks slow (early Valkey warning) | Limiter check latency widget, Valkey CPU/memory (if enabled) |
| GatewayWorkerPoolEmpty | No workers registered | Router worker pool, model-group sync, worker route health |
| GatewayRouterWorkerCbOpen | Worker circuit breaker open | Inference path CB state, worker connectivity |
| GatewayRouterInflightAgeHigh | Stuck router requests | Router inflight age, active requests |
| GatewayRouterActiveRequestsHigh | Router saturation | Worker pool size, adapter upstream TTFT |
| GatewayAdapterUpstreamTtftP95High | Slow adapter → worker path | Adapter upstream TTFT, router latency |
| GatewayMeteringOutboxFailures | Billing pipeline errors | Gateway operations / metering widgets |
| GatewayTracePersistenceFailures | Trace write failures | Observability drops widget |
| Database monitors (optional) | RDS/Valkey/Postgres DBM | [Database observability](#database-observability) below |

Router and adapter monitors can be disabled with `DATADOG_INCLUDE_ROUTER_MONITORS`
or `DATADOG_INCLUDE_ADAPTER_MONITORS` when those components are not deployed.

## Draft → publish

| Hub field | Default | Purpose |
| --- | --- | --- |
| `DATADOG_MONITORS_DRAFT` | `false` | `true` creates all gateway monitors as **draft** (no pages until published) |
| `DATADOG_DATABASE_MONITORS_DRAFT` | `true` | Database monitors stay draft during baseline |
| `DATADOG_SLOS_ENABLED` | `false` | Creates availability + streaming TTFT SLOs |

Recommended rollout:

1. Deploy with `DATADOG_MONITORS_DRAFT=true` (or leave published defaults if you accept starter thresholds).
2. Baseline 1–2 weeks; tune latency, CB, and limiter thresholds in Datadog.
3. Publish monitors (`DATADOG_MONITORS_DRAFT=false`).
4. Enable `DATADOG_SLOS_ENABLED=true` after monitors are stable.

## Inference without worker metrics

The managed gateway dashboard does **not** scrape GPU worker OpenMetrics from the
gateway EKS cluster. Workers run on a separate host/chart with their own Datadog
Agent ([gpu-deployment](../../gpu-deployment/README.md)).

Use **gateway-side proxies** on the dashboard:

- **Inference path (router + adapter)** — pool size, circuit breaker, inflight age, adapter upstream TTFT
- **Gateway latency and streaming** — request duration, TTFT/TPOT

For GPU utilization and node health, use Datadog **Infrastructure → GPU
Monitoring** on the worker Agent after `datadog.enabled=true` in the worker
profile.

## Database observability

RDS and Valkey widgets/monitors are **opt-in**. Enable in order:

| Phase | Hub field | Result |
| --- | --- | --- |
| 1 | `DATADOG_AWS_DATABASE_METRICS_ENABLED=true` | CloudWatch RDS + Valkey metrics, managed database dashboard group |
| 2 | `DATADOG_POSTGRES_DBM_PREREQUISITES_ENABLED=true` | IAM DB auth, bootstrap Job (RDS reboot in maintenance window) |
| 3 | `DATADOG_POSTGRES_DBM_ENABLED=true` | PostgreSQL DBM direct check |
| 4 | — | Valkey stays CloudWatch-only (no direct check) |
| 5 | `DATADOG_DATABASE_MONITORS_ENABLED=true` | Paging monitors (keep `DATADOG_DATABASE_MONITORS_DRAFT=true` until baselined) |

Until phase 1, the dashboard shows a note linking here instead of database
widgets.

## LLM Observability

The gateway emits **metadata-only** GenAI spans over OTLP (`gen_ai.operation.name=chat`).
It does not reconstruct full agent/tool trees (those require client-side Datadog
Agent Observability SDK instrumentation).

Session join keys (also in gateway Conversations UI):

| Field | Datadog meaning |
| --- | --- |
| `gen_ai.conversation.id` | Session / conversation id |
| `_dd.ml_obs.metadata` | JSON: `organization_id`, `coding_agent`, `correlation_source`, `turn_id`, … |

Enable in Helm: `observability.llmObs.enabled=true` and
`observability.llmObs.datadogOtlpSource=true`.

Use the dashboard **LLM Observability** group for recent LLM spans and
correlated sessions.

## Tenant debugging

Prometheus metrics are **not** tagged with `org_id` (cardinality). For per-org
signals:

- Dashboard **Tenant signals** group — error logs by `@organization_id`, limiter
  rejections, 429 log events
- Gateway dashboard **Conversations** and **Usage** — billing and token detail
- LLM Obs — filter on `@organization_id` inside `_dd.ml_obs.metadata` after
  correlation is active

## Optional Hub fields (summary)

| Field | Notes |
| --- | --- |
| `DATADOG_ENV` | Env facet for titles, monitors, pipelines |
| `DATADOG_SITE` | e.g. `datadoghq.com`, `us5.datadoghq.com` |
| `DATADOG_MONITOR_NOTIFICATION` | Inserts into every monitor message |
| `DATADOG_DASHBOARD_TAGS` | Default `team:api-gateway` |
| `DATADOG_RESOURCE_TAGS` | Extra monitor tags |
| `DATADOG_SLOS_ENABLED` | Managed availability + TTFT SLOs |

Never put `DD_API_KEY` / `DD_APP_KEY` into gateway Helm values — they are infra
Hub secrets only ([gateway-secrets.md](gateway-secrets.md)).
