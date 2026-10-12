# Prepare GLM 5.3 with L1 L2 and L3 on Aranya

This folder holds the storage requirements and setup plan for adding persistent
L3 caching to the Aranya GLM-5.3 deployment. **This profile is not deployable yet.**
Use [L1/L2](../l1-l2/README.md) for the currently qualified image pair and managed
Kubernetes workflow.

The intended cache tiers are GPU memory (L1), host RAM (L2), and a separately
provisioned packed cache store (L3). The existing L3 implementation uses
`packed_fs` with 3FS and a packed index. The storage topology and transport for
Aranya remain to be selected with the provider.

## Files and inputs

| File | Purpose |
| --- | --- |
| [requirements.example.yaml](requirements.example.yaml) | Fillable planning record for storage, provider capabilities, images and acceptance. This is not a Helm values file. |
| [PROVIDER-HANDOFF.md](PROVIDER-HANDOFF.md) | Additional questions for Aranya about L3 storage and its runtime requirements. |
| [Shared handoff](../PROVIDER-HANDOFF.md) | Kubeconfig, namespace, GPUs, model storage and networking needed by both profiles. |

Keep the model repositories, revision pins and TP4 layout from the L1/L2 plan.
Budget additional CPU, RAM and disk for storage and indexing before choosing
worker counts or HiCache ratios. Keep L3 data separate from model snapshots and
application-etcd state, with an explicit capacity and eviction policy.

## Why L3 needs a separate deployment

The current managed chart fixes the worker backend to `none` and rejects storage
backend overrides. Its smoke probe also expects exactly L1/L2 pressure tiers.
Adding a storage flag to its values does not create an L3 deployment.

The existing host-oriented 3FS charts depend on host networking, host PID/IPC,
host paths, FUSE devices, mount propagation and additional storage capabilities.
RDMA adds verbs-device and fabric requirements. Those charts cannot be used as
the customer-kubeconfig Aranya profile without a provider-supported storage
integration and a compatible workload design. The listed network cards alone
do not establish RDMA readiness.

Choose whether cache objects are shared across nodes or scoped to one node.
Separate local PVCs do not make a shared L3 store. A shared packed domain needs
the same storage contents, compatible keys/layout and its owning index; isolated
stores need separate domains and correct routing visibility. The current
host-oriented profile is not evidence of a working two-node shared 3FS cluster.

## Implementation and release sequence

1. Complete both provider handoffs and the requirements record. Agree on storage
   ownership, node-local or shared topology, supported transport and namespace
   permissions. Disk/runtime preparation belongs to Aranya where host access is
   needed.
2. Package a managed Kubernetes chart for the agreed storage interface, packed
   index, worker, sidecar and frontend. Express mounts, credentials, resources,
   network access and readiness ordering explicitly. Use `helm upgrade --install`
   for application releases after this chart is available.
3. Build and qualify matching worker/runtime, storage and index images. Record
   immutable image digests, engine/native-client compatibility and packed format
   version. The published L1/L2 release is not the L3 release.
4. Deploy an isolated test release with its own credentials and cache domain.
   Stage the same pinned model weights and validate storage health before
   starting index and inference workers.
5. Complete the acceptance checks below before adding gateway traffic or
   expanding to all sixteen GPUs. Retain an independent L1/L2 rollout path.

## Acceptance checks

- Write packed cache pages and restore them after clearing the test worker's
  L1/L2 state; verify actual L3 reads and correct inference output.
- Exercise L3 from a fresh worker process and, for a shared-store design, a
  second node. Local filesystem cache warmth is not a release prerequisite.
- Compare worker and Dynamo page snapshots after writes, restores and eviction;
  validate ownership, removal and index consistency.
- Check missing objects, index/storage restarts, disk pressure, eviction and
  node-loss behavior, including which cache data survives each failure.
- Report fresh L1/L2/L3 pressure with the correct per-worker identities. Extend
  the managed probe to accept and verify the L3 contract.
- Run bounded concurrency checks and a sustained workload, recording TTFT,
  restore latency, native batching time, throughput and CPU/RAM/disk use.

Only replace this folder's pending status with deployment instructions once the
matching chart, images, provider integration and validation evidence exist.
