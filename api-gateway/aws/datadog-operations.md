# Datadog operations (AWS API Gateway)

How to use the managed Datadog assets provisioned by **api-gateway-infra** when
`DATADOG_ENABLED=true`. The default path is **metrics + Conversations + error
logs**. Trace Explorer and LLM Observability stay empty unless you set
`DATADOG_APM_ENABLED=true` (and `DATADOG_LLM_OBS_ENABLED=true` for LLM spans).

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

The Overview group keeps **Gateway readiness** as a last-value card. **Active requests** (`gateway.inflight`), **Gateway RPS**, **Requests / minute**, **Requests / hour**, and **5xx error ratio** are time series. The Token usage group has input/output/total tokens per minute plus a 30-day **Tokens per day** bar chart by model.

## What pages (monitors)

Monitors are prefixed `[<DATADOG_ENV>]` and link to
[troubleshooting.md](troubleshooting.md). First checks by symptom:

| Monitor | Symptom | First checks |
| --- | --- | --- |
| Too many gateway 5xx responses | More than 30 HTTP 5xx in 30 minutes | Dashboard 5xx count, `gateway.request.completed` logs, router/adapter panels |
| Gateway readiness probe is failing | `/readyz` failing | Dependency health widget, Postgres/Valkey/Router readiness |
| A gateway dependency probe is down | Postgres, Valkey, or router probe down | Managed databases group (if enabled), dependency widget |
| Streaming first token is slow | Streaming TTFT p95 above 30s | Inference path panels, TTFT SLO (if enabled) |
| Rate-limiter checks are slow | Limiter Valkey checks slow | Limiter check latency widget, Valkey CPU/memory (if enabled) |
| Rate-limiter Redis script is failing | Limiter backend/script errors | Valkey health, limiter script error logs |
| No inference workers are registered | No workers registered | Router worker pool, model-group sync, worker route health |
| A model-group endpoint failed router registration | At least one endpoint `sync_status=error` for 5m | Staff Model groups `last_sync_error`; router may still be Ready |
| A model-group endpoint is stuck pending registration | Endpoint `sync_status=pending` for 15m | Model-group sync, router control plane, whether a roll is still exposing workers |
| A router worker circuit breaker is open | SMG isolated a registered worker after live request failures (0=closed, 1=open, 2=half-open) | Gateway dashboard CB widget; Staff Model groups for `sync_status=error`. Not the same as registration failure. See [troubleshooting](troubleshooting.md#router-worker-circuit-breaker) |
| Router requests are stuck in flight | Stuck router requests | Router inflight age, active requests |
| Router worker request count is high | Router saturation | Worker in-flight (`worker_requests_active`), worker pool size |
| Adapter wait for first token is slow | Slow adapter to worker path | Adapter upstream TTFT, router latency |
| Metering outbox is failing | Billing pipeline errors | Gateway operations / metering widgets |
| Platform usage chart is behind the gateway | Platform usage chart stale vs gateway UI | `export_usage_lag_seconds`, webhook pending/dead letters |
| Usage webhooks are not draining / stuck in dead-letter | Webhook outbox not draining | `gateway.webhook.delivery.batch` logs, webhook URL/secret |
| Usage events are not reaching the platform | Usage emitted but no delivered webhook for 15m | Webhook worker, Vercel `gateway_webhook.received` |
| ALB targets are returning 5xx | More than 30 ALB target 5xx in 30 minutes | Gateway 5xx logs, target health, RDS latency |
| Database monitors (optional) | RDS/Valkey/Postgres DBM | [Database observability](#database-observability) below |

Warn-severity monitors stay in Datadog and do not Slack. `DATADOG_MONITOR_NOTIFICATION` is inserted only on page-severity monitors. Tenant 429s (limiter rejections) and full stream duration (ALB/request p95) are dashboard signals, not pages.

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
2. Baseline 1–2 weeks; tune 5xx count, TTFT, and circuit-breaker thresholds in Datadog.
3. Publish monitors (`DATADOG_MONITORS_DRAFT=false`).
4. Enable `DATADOG_SLOS_ENABLED=true` after monitors are stable.

## Inference without worker metrics

The managed gateway dashboard does **not** scrape GPU worker OpenMetrics from the
gateway EKS cluster. Workers run on a separate host/chart with their own Datadog
Agent ([gpu-deployment](../../gpu-deployment/README.md)).

Use **gateway-side proxies** on the dashboard:

- **Inference path (router + adapter)** - pool size, worker in-flight, circuit breaker, inflight age, adapter upstream TTFT. Router load is `worker_requests_active`. Gateway admitted work is Overview **Active requests** (`gateway.inflight`). `http_connections_active` is not scraped (upstream sglang-router leak on cancelled requests).
- **Gateway latency and streaming** — request duration, TTFT/TPOT

For GPU utilization and node health, use Datadog **Infrastructure → GPU
Monitoring** on the worker Agent after `datadog.enabled=true` in the worker
profile.

## Database observability

RDS, Valkey, and ALB CloudWatch widgets/monitors ship with `DATADOG_ENABLED=true`.
Connect AWS in Datadog before expecting those series:

1. Open Datadog **Integrations → Amazon Web Services**.
2. Add or select the gateway AWS account.
3. **Set Permissions** using Datadog's default read-only AWS policy. Do not
   create `DatadogApiGatewayIntegrationRole`.
4. Enable metric collection for `AWS/RDS`, `AWS/ElastiCache`, and
   `AWS/ApplicationELB` (or leave Datadog's default namespace crawl).

A leftover Hub field `DATADOG_AWS_DATABASE_METRICS_ENABLED` is ignored.

| Phase | Hub field | Result |
| --- | --- | --- |
| 1 | `DATADOG_ENABLED=true` plus AWS connected in Datadog | CloudWatch RDS + Valkey + ALB metrics, dashboard group, IOPS/queue/latency monitors (draft) |
| 2 | `DATADOG_POSTGRES_DBM_ENABLED=true` | `datadog` role, `CREATE EXTENSION`, Agent check, query toplists |
| 3 | `DATADOG_DATABASE_MONITORS_DRAFT=false` | Publish database monitors after a traffic baseline |

RDS PostgreSQL 11+ already loads `pg_stat_statements`. Phase 2 does not reboot
RDS, change parameter groups, or set `RDS_APPLY_IMMEDIATELY`. The contract
forbids raw SQL samples in Datadog DBM. After AWS
`log_min_duration_statement=2000` and `enabled_cloudwatch_logs_exports=["postgresql"]`
apply, read slow-statement **text** in CloudWatch Logs. Usage webhooks
enqueue at insert time (one delivery row). Do not grep `NOT EXISTS` as
the hot query; that skip-scan copier is gone. Use Datadog DBM for
normalized query structure, duration, and wait events once phase 2 is on.

If the bootstrap Job is stuck, increment
`DATADOG_POSTGRES_DBM_BOOTSTRAP_REVISION` and re-apply.

### IOPS and slow queries

Phase 1 dashboard widgets chart RDS read/write IOPS, disk queue depth, and
connection count. Phase 1 also creates these monitors in draft:

| Monitor | Signal | Default threshold |
| --- | --- | --- |
| DatabaseRdsIopsHigh | Combined read+write IOPS | 2400 (80% of gp3 3000 IOPS baseline) |
| DatabaseRdsDiskQueueHigh | Disk queue depth | warn 10 / alert 20 |

To list queries by structure (literals stripped) and latency:

1. Set `DATADOG_POSTGRES_DBM_ENABLED=true` and apply.
2. Open the managed dashboard **PostgreSQL engine** group: **Slowest PostgreSQL
   queries (normalized)** and **Most frequent PostgreSQL queries (normalized)**.
3. For the full list, sort, and wait-event breakdown, open Datadog
   **APM > Database Monitoring > Query Metrics** and filter `env:<DATADOG_ENV>`.
   The `query` facet is obfuscated SQL (`query_signature` is the stable hash).
   Do not enable raw statement collection.

Tune IOPS thresholds if you raise gp3 provisioned IOPS above the 3000 baseline.

## LLM Observability (opt-in)

Off unless Hub `DATADOG_APM_ENABLED=true` and `DATADOG_LLM_OBS_ENABLED=true`.
The gateway then emits **metadata-only** GenAI spans over OTLP
(`gen_ai.operation.name=chat`). It does not reconstruct full agent/tool trees
(those require client-side Datadog Agent Observability SDK instrumentation).

Session join keys (also in gateway Conversations UI):

| Field | Datadog meaning |
| --- | --- |
| `gen_ai.conversation.id` | Session / conversation id |
| `_dd.ml_obs.metadata` | JSON: `organization_id`, `coding_agent`, `correlation_source`, `turn_id`, … |

LLM Observability stays empty on the default path. That is expected.

## Expert request and trace debugging

Start from the gateway dashboard request-detail page. Capture these values
before opening Datadog:

- request ID;
- trace ID;
- suspect layer span ID;
- request start and end time;
- request status and error type;
- provider, worker, and endpoint identifiers when present.

The request ID identifies one gateway call. The trace ID identifies the
distributed operation, but correlated gateway conversations intentionally use
the conversation UUID without dashes as their trace ID. Multiple requests can
therefore share one trace. The span ID identifies one exact operation inside
that trace.

### Find the request in Datadog

Set a narrow time range around the request, select the correct deployment
environment, and search Logs Explorer:

```text
source:subconscious-gateway env:<DATADOG_ENV> @request_id:<REQUEST_ID>
```

From a 5xx metric or the "Too many gateway 5xx responses" monitor,
use the metric tags. The managed JSON pipeline copies them onto
`gateway.request.completed` as log tags (APM is not required):

```text
source:subconscious-gateway env:<DATADOG_ENV> status_code:503
```

`@status_code:503` still works. Do not search `@http.status_code`. The log
message is only `gateway.request.completed`; the status lives on
`@status_code`, `@outcome`, and `@error_type`.

Search Logs Explorer with `@request_id:<REQUEST_ID>`. Inspect `@outcome`,
`@error_type`, `@provider_status_code`, `@provider_request_id`, and
`@provider_error_message`. Keep the request ID in the query when a
conversation trace contains many requests.

APM Trace Explorer is empty unless `DATADOG_APM_ENABLED=true`. When it is on,
trace and span IDs are reserved attributes and do not use an `@` prefix:

```text
trace_id:<32-character-hex-trace-id>
span_id:<16-character-hex-span-id>
```

Open the trace waterfall and confirm that the selected span has the same
`request_id` as the gateway request-detail page. The gateway exports the exact
hex IDs displayed by that page over OTLP.

### Read the waterfall

Follow the request from `gateway.request` through `validate`, `auth`,
`routing`, `limits`, `metering_start`, `model_call`, and `model_stream`.
Router or adapter services may add downstream proxy and worker spans.

1. Find the first span marked as an error or partial outcome.
2. Compare its duration with its parent and siblings.
3. Inspect its provider status, provider request ID, worker, endpoint, and
   error attributes.
4. Open correlated logs for that span and include a few seconds before and
   after its timestamps.
5. Check sibling requests with the same trace ID only after confirming their
   distinct request IDs.

Typical interpretations:

- `partial` with no error type means the client disconnected, the stream ended
  without final usage, or stream finalization was incomplete. It is not proof
  of a provider timeout.
- `provider_error` with `gateway_timeout`, `service_unavailable`, or
  `provider_5xx` is an explicit upstream failure.
- `provider_4xx` should be inspected for its original status and provider code.
  Payload or context-size failures require a smaller follow-up request rather
  than blind replay.
- A long `model_call` points to connection, response-header, or first-event
  latency. A long or failed `model_stream` points to an interruption after the
  provider accepted the request.

### HTTP status and streaming errors

A failure known before the first client-visible stream event can return a real
HTTP status such as `429`, `502`, `503`, or `504`, allowing compatible coding
agents to retry. Once any stream event has reached the client, HTTP `200` is
already committed. Later failures are delivered as an in-band stream error
with status, retryability, provider code, retry timing, and request ID
metadata. Client retry behavior after partial output varies by coding agent.

HTTP `413` remains a payload-size error. Reduce or compact the request instead
of treating it as a transient gateway failure.

### When Datadog has no matching trace

Check the following before treating missing APM data as a gateway defect:

- `DATADOG_APM_ENABLED=true` (OTLP is not part of the Datadog sample path);
- the Datadog environment and time range match the request;
- the span is still available under the account's indexing and retention
  policy;
- the JSON log pipeline parsed `trace_id` and `span_id` as strings and remapped
  them to Datadog's reserved correlation fields;
- trace sampling did not discard the trace while independently retaining its
  logs.

The gateway request-detail page is backed by local trace events and remains a
useful fallback when an external provider sampled out the trace.

### Equivalent OpenTelemetry backends

The IDs are standard OpenTelemetry/W3C trace-context identifiers:

- Grafana Tempo: paste the trace ID into Explore, or use
  `{ trace:id = "<TRACE_ID>" }` and `{ span:id = "<SPAN_ID>" }`.
- Honeycomb: filter on `trace.trace_id` and `trace.span_id`, then open the trace
  waterfall.
- Elastic Observability: filter on `trace.id` and `span.id` in Discover or APM.

The investigation order stays the same: request ID and time window, then trace
ID, then the exact failing span and its correlated logs.

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
| `GATEWAY_LOG_LEVEL` | Default `WARN`. `INFO` = one `request.completed` line per call |
| `DATADOG_APM_ENABLED` | Default `false`. Opt in to OTLP traces |
| `DATADOG_LLM_OBS_ENABLED` | Default `false`. Requires APM |
| `DATADOG_ENV` | Env facet for titles, monitors, pipelines |
| `DATADOG_SITE` | e.g. `datadoghq.com`, `us5.datadoghq.com` |
| `DATADOG_MONITOR_NOTIFICATION` | Inserts into page-severity monitor messages only |
| `DATADOG_DASHBOARD_TAGS` | Default `team:api-gateway` |
| `DATADOG_RESOURCE_TAGS` | Extra monitor tags |
| `DATADOG_SLOS_ENABLED` | Managed availability + TTFT SLOs |

Never put `DD_API_KEY` / `DD_APP_KEY` into gateway Helm values — they are infra
Hub secrets only ([gateway-secrets.md](gateway-secrets.md)).
