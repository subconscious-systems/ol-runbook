# Aranya deployment profiles

Choose a cache profile for GLM-5.3 NVFP4 with DFlash2 on Aranya's two B200 GPU
nodes. Both profiles use the provider-issued kubeconfig and keep application
services on GPU nodes. Aranya operates the Kubernetes control plane.

| Folder | Cache tiers | Deployment status |
| --- | --- | --- |
| [l1-l2](l1-l2/README.md) | GPU memory and host RAM | Qualified image pair and Helm deployment guide available; actual Aranya acceptance remains pending. |
| [l1-l2-l3](l1-l2-l3/README.md) | GPU memory, host RAM and persistent cache storage | Requirements and setup plan; a managed-cluster L3 chart and qualified image set are still required. |

Start the provider conversation with the shared
[handoff checklist](PROVIDER-HANDOFF.md). The L3 folder adds storage-specific
questions. Aranya supplies local disks, not a shared filesystem or object store;
L3 storage must be explicitly provisioned and integrated.

The L1/L2 release bundle includes its chart, Python helpers and digest-pinned
images. The L3 folder does not reuse that image pair as evidence of L3 support.
Each profile's README describes its files, required inputs and acceptance steps.
