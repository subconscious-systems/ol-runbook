# Aranya L3 storage handoff

Complete the [shared handoff](../PROVIDER-HANDOFF.md) first. The current candidate
uses packed cache objects, 3FS and a packed index. Please confirm which storage
interface can be supported through the customer kubeconfig.

| Item | Requested answer |
| --- | --- |
| Storage ownership | Will Aranya operate the storage/mount layer, or support an agreed customer workload through Kubernetes? |
| Cache topology | Independent local caches per GPU node, or a shared cache accessible from both nodes? If shared, what provides shared data and failure recovery? |
| Capacity | Usable cache capacity after model/image/scratch reservations, mount paths, filesystem behavior and per-node quotas. Do not assume the four NVMe devices are already one RAID volume. |
| Workload interface | Supported CSI/PVC or other mount interface, access modes, node affinity and UID/GID ownership. |
| Native client | Supported 3FS client/runtime integration, FUSE/device access, io_uring, memlock and any required mount propagation or namespace sharing. |
| Admission policy | Whether the existing storage implementation's host namespaces, host mounts and storage capabilities can be supplied by a provider-managed service or approved deployment. The L1/L2 restricted profile does not grant these. |
| Transport | TCP or RDMA; for RDMA, verified device-plugin resources, fabric/MTU configuration, verbs access and support ownership. |
| Placement | Storage and index CPU/RAM budgets on workload GPU nodes; provider control-plane nodes stay reserved. |
| Connectivity | Private storage/index endpoints, cross-node access, authentication, network policy and monitoring paths. |
| Durability | Behavior on pod/node/disk loss, replica count if any, cache rebuild procedure and responsibility for disk-full recovery. |
| Operations | Storage upgrades, compatibility guarantees, maintenance windows and escalation contacts. |

These are design inputs, not a request to install host software or change the
running cluster. An Aranya L3 deployment requires a separate implementation and
qualification after the supported interface is established.
