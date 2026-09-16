# Dynamo routing migration

This guide accompanies the Dynamo implementation branch. Use it with a reviewed
release containing the Rust router and worker bridge; it is not a change to an
already published application version.

The Subconscious Inference System places a Rust routing service between the
gateway and GPU workers. Each GPU pod runs a Rust bridge beside SGLang. Requests
travel as ordinary JSON over Dynamo RPC, then pod-local HTTP. SGLang performs
tokenization, chat templating and cache operations.

Add endpoints through the gateway's normal **Add endpoint / Create worker pool**
screen. An ordinary SGLang URL works through the HTTP adapter with its saved
credentials. Native RPC and KV-aware placement activate when a bridge advertises
the matching model and pool. Once discovered, the router retains native transport
through pod loss and restarts; it does not bypass an unavailable bridge via HTTP.
Plain HTTP endpoints have no verified KV telemetry and use round-robin selection
within endpoint priority.

## Required configuration

The FDE supplies the following for the installation:

- A reviewed router image, used for both the router service and worker bridge.
- A private application etcd discovery service. Configure its address in both
  applications. Do not use the Kubernetes control-plane etcd.
- The existing Redis/Valkey connection for shared session ownership and endpoint
  membership. The gateway and router must use the same deployment configuration.
- The same worker credential in the gateway and worker applications' existing
  `SGLANG_WORKER_API_KEY` secret. It also authenticates the bridge's RPC requests.
- A worker pool matching the pool on the dashboard endpoint, plus the matching
  served model name. Every replica in that pool registers itself with Dynamo.
- Routable pod addresses: router → worker TCP `31002`, worker → router TCP
  `31003`, and access to the discovery service. An existing HTTP NodePort alone
  does not establish native Dynamo connectivity across separate clusters.

Gateway Helm values:

```yaml
router:
  dynamo:
    endpoint: customerdeployment.workers.generate
    etcdEndpoints: http://etcd.example.internal:2379
```

Worker Helm values, merged into the existing model/GPU profile:

```yaml
worker:
  dynamo:
    enabled: true
    image: registry.example.internal/reviewed-router@sha256:REVIEWED_DIGEST
    endpoint: customerdeployment.workers.generate
    etcdEndpoints: http://etcd.example.internal:2379
    pool: deployment-gpu-pool
    capacity: 32
```

`capacity` is the bridge's hard concurrent-request limit; choose it with the
model's SGLang running-request capacity. Multi-model charts can override
`dynamo` under each `models[]` entry. The process-generation file is managed by
the worker launcher, including container restarts.

## Enable cache-aware placement

Initially the bridge can run without a storage profile and use load balancing.
The FDE then supplies `worker.dynamo.storageProfile`, matching the exact L3-v3
worker build, model weights, templates, pruning settings and tensor layout.
The manifest must include every required target/draft/indexer component and
parallel rank with its expected page length.

Set `cacheHostPath` to the prepared local cache directory on the GPU node and
`cacheMountPath` to its container path. `storageProfile.root` must match that
container path. The worker mounts it for writes; the bridge mounts it read-only.
Set `worker.dynamo.runAsUser` to the SGLang process UID (default `0` for the
current worker image): L3-v3 writes private files, so a different UID cannot
read its committed mappings and segments.
Keep the model's existing hierarchical/file-cache flags in its runtime profile.

The bridge observes L1/L2 events and committed L3 files, then pushes cache
metadata to the router. A disk eviction removes disk credit on the next scan.
Missing or stale evidence results in normal load-based placement. Known text
OpenAI Chat histories can receive cache-aware placement before tokenization; arbitrary new
token prefixes and unsupported histories use load balancing.

L3 currently lives on attached local disk. If a spot node disappears, another
node cannot reuse that disk through this implementation. Its sessions are
placed again using cache evidence from surviving workers and current load.

## Session and endpoint behavior

Sessions stay on their prior healthy GPU only while the relevant cache is
present and the worker has capacity. Ownership expires after five idle minutes
or thirty minutes of absolute lifetime by default. Overlapping turns for one
session return `409`; applications should serialize turns for that session.

Use the dashboard endpoint controls to add, disable or remove pools. The gateway
reconciles those changes to the router. Disabling/removing a pool prevents new
turns while admitted requests can finish. Worker discovery cannot re-enable a
deleted endpoint. Expired sessions and lost workers use normal placement.

An admitted request is not retried automatically on another GPU after a
connection failure. This prevents duplicate inference; the calling application
decides whether to submit a new request.

## Rollout and verification

Apply reviewed worker and gateway versions through their Distr Applications.
The Helm changes do **not** require Force conflicts. RBAC changes are outside
this migration. Roll back by selecting the previous compatible Distr
Application versions.

Before enabling customer traffic, the FDE verifies the actual GPU model/profile:

1. Register the pool and confirm worker bridge readiness.
2. Send a normal request, then a follow-up with the same session id and cached
   history. Confirm the selected GPU and streaming usage accounting.
3. Exercise cache eviction, hard capacity, endpoint disable and process restart.
4. Terminate a disposable spot worker and confirm subsequent turns select a
   surviving worker without attempting to use the lost node's disk.
5. Verify cancellation and an active stream during the planned upgrade.

Router metrics include `orangeline_router_requests_total`,
`orangeline_router_session_hits_total`, `orangeline_router_cache_hits_total`,
`orangeline_router_unavailable_total` and `orangeline_router_workers`.
