# Provider configuration sources

The environment examples expose settings used by the checked-in provider
helpers. Blank account IDs, regions, images, and instance types require values
from the target account. A populated instance type describes a helper default,
not verified capacity or a live-tested deployment.

## Corrections checked on 2026-09-15

- AWS P4de lists `p4de.24xlarge` with eight A100 80 GB GPUs. Removed the
  nonexistent one- and two-GPU P4de defaults; those profiles require an
  explicit matching instance override or an existing host.
  Single-L4 and single-L40S defaults use `g6.4xlarge` and `g6e.2xlarge`,
  respectively, with 64 GiB host RAM so the example worker memory limits
  leave room for host services.
  [EC2 specifications](https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html).
- GCP B200 uses `a4-highgpu-8g`. A4 requires an appropriate capacity or
  provisioning mode; the existing basic VM helper does not implement that
  complete flow. Provision the host through GCP's supported workflow and use
  `--instance-ip` for this profile.
  [GPU machine types](https://docs.cloud.google.com/compute/docs/gpus).
- Azure's eight-A100 80 GB size is `Standard_ND96amsr_A100_v4`.
  [NDm A100 v4 sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/ndma100v4-series).
- OCI's eight-A100 80 GB shape is `BM.GPU.A100-v2.8`.
  [Compute shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm).

Lambda launch requests and CoreWeave/Crusoe CLI contracts still require
correction or validation. Nebius and Together use manual provisioning;
Fireworks has guidance only. See [provider capabilities](README.md#provider-helpers).

Named single-worker L4 profiles use their stated GPU count. The legacy
`qwen3-8b` and `qwen36-27b` examples retain their four-GPU multi-worker layouts.
