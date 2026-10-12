# Aranya deployment handoff

Please supply or confirm the following for a GLM-5.3 deployment through the
customer kubeconfig. Initial serving uses four B200s on each GPU node; the target
is two independent TP4 workers per node, sixteen GPUs total. All application
components run on GPU nodes. The three CPU control-plane nodes remain reserved
for provider services.

| Item | Requested answer |
| --- | --- |
| Access | Cluster/context name, customer namespace, kubeconfig delivery and credential expiry/renewal procedure. |
| Namespace permissions | Read/write/watch application Pods, Services, ConfigMaps, Secrets, PVCs, Deployments, StatefulSets, ReplicaSets, Jobs and NetworkPolicies; read events, quotas, limits and pod logs; pod exec and port-forward. No customer node writes or cluster-admin role required. |
| GPU nodes | Exact hostname labels, taints, architecture, allocatable CPU/RAM and eight exclusive `nvidia.com/gpu` resources per node; confirm no time slicing or unexpected MIG partitioning. |
| Runtime | NVIDIA runtime class name, or confirmation that no runtime class is needed; B200-compatible driver/container stack. |
| Memory | Adequate container memlock, memory-backed `/dev/shm`, and support for the chart's non-root UID/GID, fsGroup, dropped capabilities and RuntimeDefault seccomp. |
| Quotas | Initial eight-GPU and eventual sixteen-GPU allocation, plus CPU/RAM/PVC/ephemeral-storage quotas and rollout headroom. Each worker requests 32 CPUs/900 GiB RAM and has a 1,000 GiB RAM limit; sidecars and control services add overhead. |
| Model storage | A local StorageClass with WaitForFirstConsumer and node affinity, or prebound PV names. Start with one 1 TiB ReadWriteOnce model claim per GPU node, usable by two pods on that same node. Confirm capacity and ownership handling. |
| Application etcd | A separate 4 GiB local PVC on GPU node A; this is not access to Kubernetes control-plane etcd. |
| Image and scratch space | Capacity for compressed and unpacked worker/runtime images and disk-backed scratch up to 128 GiB per worker, separate from model PVC budgeting. |
| Network | DNS, pod interface name (the example assumes eth0), enforced NetworkPolicies and bidirectional cross-node pod TCP connectivity for discovery and native Dynamo messaging. This TP4-per-node profile does not require cross-node NCCL/RDMA. |
| Download access | HTTPS access to the supplied image registry and layer storage, model repositories and their download endpoints; any proxy or allowlist requirements. |
| Private ingress | Supported private gateway route/ingress/VPN, DNS/TLS ownership and gateway source addresses as seen by the CNI. |
| Storage recovery | Actual disk layout, free capacity, reclaim policy and node/disk replacement procedure. Local models can be downloaded again; application state and credentials need an agreed recovery plan. |
| Operations | Support contact, maintenance notices, kubeconfig renewal and provider-supported registry credential renewal/mirroring. |

Please confirm any additional namespace admission policies before deployment.
The application uses Kubernetes resources only; host access, privileged pods,
driver installation and customer changes to clusterdOS are not part of setup.
