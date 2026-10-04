# Dynamo workers and cache allocation

This integration is prepared in source and must be included in a reviewed
gateway/router and GPU-worker release before enabling it. It has not been
deployed to a GPU host. Follow your normal FDE/Distr release process; do not
replace a running engine just to enable this view.
The chart owns the worker pod specification; this integration does not require
Force conflicts or an out-of-band deployment patch.

## What runs with each worker

One GPU container runs SGLang, the Rust Dynamo bridge, and the Rust cache
collector. They share the same GPU allocation, cache mounts, process namespace,
and engine generation. The collector performs read-only observations and writes
an atomic JSON snapshot to a pod-local volume. The bridge publishes that
snapshot through its existing authenticated Dynamo watch. The gateway exposes
the model's allocation view only through the staff model-group page.

Tokenization remains in SGLang. Requests use native Dynamo TCP RPC.
No additional GPU allocation, Kubernetes RBAC, host PID namespace, privileged
container, or public telemetry endpoint is needed.

## Required deployment inputs

- A worker image containing both orangeline-routing and orangeline-cache-agent.
  The FDE builds this from the reviewed runtime and bridge images.
- A routable private network between the router and GPU pods, including Dynamo
  response callbacks. An HTTPS SGLang endpoint alone does not provide it.
- The same application etcd endpoint and Dynamo endpoint name as the router.
- A Kubernetes Secret containing the router's worker RPC key. This is distinct
  from the gateway API key and the optional SGLang HTTP key.
- The gateway endpoint UUID (or its explicit pool) and the exact served model
  name. Each model entry needs the matching pool. The dashboard's displayed
  router Worker ID is not the endpoint UUID.

Supply the following overrides alongside the existing model profile. Replace
the example values with the deployment's assigned values. Keep model weights,
tensor parallelism, credentials and existing engine settings from that profile.

    worker:
      dynamo:
        enabled: true
        pool: "<gateway-endpoint-uuid>"
        endpoint: "orangeline.workers.generate"
        etcdEndpoints: "http://application-etcd.private:2379"
        rpcSecret:
          name: dynamo-worker-rpc
          key: ORANGELINE_RPC_KEY
        capacity: 8
        telemetry:
          enabled: true
          sampleIntervalSeconds: 2
          diskIntervalSeconds: 10

Capacity must not exceed SGLang's maximum running requests. For models[] profiles,
worker.dynamo provides shared defaults and models[].dynamo overrides each
engine's pool and settings. Registration starts automatically with the worker;
the gateway can bind it only after the matching endpoint exists.

The chart advertises the Pod IP with request port 31002 and response port 31003.
The router's response address must also be reachable from GPU pods. Discovery
uses etcd (usually port 2379). Readiness uses pod port 31001. These are private
pod ports; the existing HTTP Service does not expose them. Remote k3s clusters
need routed pod networks or separately managed private forwards. The existing
ds8 development tunnels do not automatically make arbitrary new pod IPs reachable.

Place the RPC key in the named Secret using your deployment's secret mechanism.
The chart references it and does not render its value into configuration files.
The existing worker HTTP secret continues to supply SGLANG_WORKER_API_KEY.

## L2 measurements and allocation

Enable SGLang metrics through worker.sglang.enableMetrics. The collector reads
the existing host-used-token and host-total-token gauges, deduplicates repeated
tensor/pipeline ranks, and displays a separate logical pool per data-parallel
rank. Missing gauges remain unknown.

The reviewed L3-v3 allocator uses:

- Positive hicache-size: decimal GB per host pool, divided by bytes per token.
- Otherwise: device token capacity multiplied by hicache-ratio.
- Page alignment: one page beyond the integer page quotient.
- A 10 GiB host-memory reserve checked against available RAM when allocating.

This is a startup memory check, not a continuously enforced free-memory floor.
The pool remains allocated when cache slots are unused. The dashboard therefore
separates free cache slots from host and container memory headroom.

Exact byte capacity needs the deployment's verified bytes per logical token for
the main host pool reported by the gauges. If known, set:

    worker:
      dynamo:
        telemetry:
          l2BytesPerTokenByDp:
            "0": 131072

131072 is an illustrative value, not a model default. It must cover the physical
main-pool allocation across that DP group's tensor/pipeline ranks. Leave the
map empty until verified; the view still shows measured used/free/total slots.
Draft, indexer and other auxiliary pools are not reconstructed from a main-pool
gauge. Process RSS and rounded GPU memory are never presented as L2 byte usage.

## L3 scopes, maximum size and minimum free space

Mount the actual local cache directory and name each accounting scope. The
chart sets SGLANG_HICACHE_FILE_BACKEND_STORAGE_DIR to cache.mountPath for both
SGLang and the collector; do not duplicate that variable in extraEnv:

    worker:
      dynamo:
        cache:
          hostPath: /mnt/sglang-cache
          mountPath: /var/lib/orangeline/cache
        telemetry:
          namespaces:
            - name: main-cache
              layout: legacy
              path: /var/lib/orangeline/cache
              suffixes:
                - "<exact-storage-config-suffix>"
                - "<additional-global-head-suffix-if-this-evictor-owns-it>"

For legacy storage, suffixes are the exact filename suffixes before .bin owned
by one evictor. Do not combine independent per-rank caps into a single scope.
Remove placeholder suffixes and supply the actual storage contract.

For segmented storage, each scope points directly at its namespace directory:

    worker:
      dynamo:
        telemetry:
          namespaces:
            - name: main-segments
              layout: segmented
              path: /var/lib/orangeline/cache/.hicache_segmented_v1/objects/<namespace-digest>

The digest is the first 20 hex characters of SHA-256 of the exact store suffix.
Despite the directory name, the supported SQLite schema version is 2.
Shared namespaces must be listed once, not once per tensor rank.

The collector reads effective engine configuration from the local /server_info
API and inherits the same SGLANG_HICACHE_FILE_BACKEND_* environment as SGLang.
Explicit backend JSON settings take precedence over environment values. It
supports inline JSON and @file.json configuration; other file formats leave
limits unknown. Thus max_size, min_free_space, eviction_ratio and
file_free_space_headroom are not independently configured in the collector.
The collector checks configured paths against the engine's storage root and
layout. A mismatch shows unknown capacity instead of an empty cache. In the
segmented backend, explicit JSON null disables a limit, and soft free-space
headroom is unused; the legacy backend falls back to environment values for
null limits. Optional legacy named-file scopes in a segmented store belong
under .hicache_segmented_v1/named and have no separate eviction cap or floor.

The view separates:

- Logical stored bytes, compared with the namespace's effective size cap.
- Physically allocated payload blocks, which differ for sparse files and
  segmented/preallocated storage.
- Available filesystem space measured using statvfs.f_bavail.
- The hard minimum-free-space floor and optional soft eviction headroom.
- Reusable segmented slots.
- Headroom for new allocation: the smaller of logical cap headroom and
  filesystem availability above the floor.

That headroom is an upper bound. Pending writer reservations, alignment,
filesystem metadata, unrelated writers and delayed block reclamation can
reduce actual admission. Slot reuse may avoid new physical allocation.
Filesystem capacity is displayed once per filesystem within a worker and is
not added across workers sharing a disk.

Legacy scans inspect only the configured suffixes and do not follow symlinks.
Segmented observation uses read-only SQLite transactions and reads committed
logical-byte accounting. Scans have a 2-second shared work budget and a
100,000-directory-entry bound; interrupted or inaccessible measurements remain
unknown. Large legacy stores may require a larger-scale accounting exporter
before precise occupancy is available. No observer writes cache payloads,
refreshes LRU recency, evicts data, or takes the engine's file-store lock.

## NUMA and memory pressure

The dashboard shows:

- Each NUMA node's CPUs, total RAM, MemFree, hugepage counts and distance row.
- GPU UUID / PCI locality for the GPUs visible to this worker.
- SGLang's configured rank-to-node list.
- The engine and descendant processes' allowed CPUs/nodes, process RSS,
  OS-locked bytes, observed NUMA policies and resident bytes by node.
- Host MemAvailable and cgroup-v2 memory usage, limit and remaining headroom.

Requested hugepages and NUMA bindings can differ from observed placement.
For example, a runtime can fall back when hugepages or memory-policy permissions
are unavailable. The integration does not grant new capabilities or change
binding policy. Keep the model profile's NUMA settings; use the observed rows
to verify them when deployment is later authorized.

Per-process resident bytes include shared mappings and non-cache memory, so
summing processes does not give unique physical RAM. Node MemFree is not the
same as host MemAvailable. OS-locked bytes do not measure every CUDA-pinned
allocation. Unreadable proc/sysfs/cgroup data stays unavailable.

## Cache-aware routing

Allocation telemetry does not prove that a particular request's KV pages are
resident. For L1/L2/L3-aware placement also provide the existing verified storage
profile ConfigMap (key storage.json), the local cache mount, and SGLang's KV
event/replay publisher:

    worker:
      dynamo:
        storageProfileConfigMap: verified-cache-profile
        kvEvents: tcp://127.0.0.1:5557
        kvReplay: tcp://127.0.0.1:5558
        kvTopic: kv-events

The storage profile must enumerate the model's complete restore components and
match its page size, namespace, serialization and rank ownership. Do not infer
it from the files currently present. Independent DP schedulers still require
separate bridge identities for cache-aware placement.

## Lifecycle and freshness

Every worker container start publishes a fresh engine generation. Engine or
bridge exit restarts the worker container; the old generation is removed before
shutdown. Normal termination drains admitted bridge calls before stopping
SGLang. A telemetry-collector failure does not restart healthy inference; its
snapshot is removed and the supervisor retries the collector.

The dashboard retains its one-second refresh. Collection defaults to every two
seconds (configurable from one to five), with disk scans every ten seconds
(configurable from five to twenty). Transport rejects mismatched engine
generations and samples older than 15 seconds. Disk counters older than 30
seconds become unavailable. Increase scan intervals only with corresponding
freshness changes; refresh frequency does not turn an old disk scan into a
new measurement.

## Validation status

CPU-only tests cover parsing, accounting bounds, SQLite eviction observations,
transport freshness, dashboard rendering and process supervision. A live GPU
deployment and a full SGLang cache workload have not been run for this change.
