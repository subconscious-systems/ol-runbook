# Regional pods

This describes the regional-router deployment model for the Subconscious
Inference System. A regional pod contains a router, GPU nodes, and shared L3
storage in the same region; it is not a Kubernetes Pod. Your FDE supplies the
reviewed gateway, regional-router, and worker releases before enabling it.

The gateway authenticates requests, enforces model access and limits, binds
session IDs to regional routers, and balances new sessions using reported load.
The regional router selects GPUs and processes cache events locally. GPU cache
pages and cache-event streams are not sent to the gateway.

## Deployment inputs

Provide a private regional router URL, a bearer key, the served model name, and
the region. The regional deployment needs its own application etcd and Redis,
a worker RPC key, and a list of model/worker-pool memberships. The regional
router and GPU bridges need bidirectional private connectivity on their configured
Dynamo request and response ports. The gateway needs only the regional HTTP API.
Use TLS when traffic crosses network trust boundaries.

The shared L3 volume must be mounted on every participating worker and match the
reviewed engine's cache layout and component manifest. Sharing a region or a
storage-domain name alone does not grant a worker access to another GPU's data.
The regional router only credits cache that a worker can verify locally.

## Register a regional router

In the staff model-group page, add an endpoint and choose **Regional router
(pod)**. Enter the regional router's base URL, region, priority and bearer key.
The router must expose the model under the same served model name. Its bearer
key is distinct from the client API key and the worker RPC key.

For administrative integrations, send `routing_target: "pod"` with the route
and its saved `credential_id`. Existing endpoints retain HTTP behavior after
the schema migration. Convert them only after the regional service is ready.
Choose **HTTP provider** for an ordinary compatible-provider URL.

The gateway's outbound host allowlist and network rules must permit the regional
URL. The gateway no longer needs application-etcd access or native GPU RPC ports.
Apply Deployment and networking changes through the supported release system;
this change does not require Force conflicts or an out-of-band Kubernetes patch.

## Health, load, and session eviction

The gateway polls authenticated regional reports every two seconds. A report
contains available capacity, current load, node health and versioned session
eviction notices. Reports older than ten seconds make that endpoint unavailable
for new requests. Node removal is reflected by absence from a later complete
snapshot; a restarted node has a new generation.

An eviction removes affinity for the affected session admission without aborting
an active response. The next turn may choose another regional router. A regional
router restart or loss of its bounded eviction history changes its affinity
epoch, allowing older mappings to expire conservatively. Transport failures and
interrupted generations are not automatically replayed.

The initial regional chart runs one router per pod. Plan a service interruption
for its replacement; multiple gateway dispatcher replicas do not make the regional
router itself highly available. Validate GPU restores and shared storage with the
actual engine build before switching production endpoints.
