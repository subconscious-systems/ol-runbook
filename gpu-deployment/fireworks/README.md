# Fireworks deployment profiles

Prints managed-platform guidance. There is no native deployment implementation or SSH host-preparation path.

## Choose a profile

Each model/GPU subfolder contains `deploy.sh`, `values.yaml`, `weights.sh`,
`.env.example`, and a profile README. The same 29
[shared model profiles](../profiles/README.md#choose-a-model-and-gpu-layout)
are available here. A listed profile does not certify that this provider
supports its GPU layout; review the
[provider capabilities](../profiles/README.md#provider-helpers) first.

From the runbook root, inspect a profile without creating resources:

```bash
cd gpu-deployment/fireworks/qwen36-27b-h100-80gb-2gpu
./deploy.sh --help
```

Configuration to review: No provider environment variables are used by this guidance helper.

Running `./deploy.sh` prints the existing platform guidance and exits with
an error because deployment is not implemented. `--instance-ip` is rejected.
Use the [GPU deployment guide](../README.md) with your FDE to select a
compatible deployment path.

## Profile files

Choose a subfolder below for its model, GPU layout, image, checkpoint paths,
provider environment settings, and setup steps. `deploy.sh` stages that
folder's `values.yaml` and `weights.sh`; it reads optional `.env` assignments
without evaluating shell code. Process environment variables take precedence.

The earlier `profiles/<profile>/<provider>/deploy.sh` paths select the same
provider-local files. [Source notes](../profiles/PROVIDER-SOURCES.md) record
known provisioning limitations and corrected instance mappings.

## Profiles

- [glm-5.2-b200-4gpu](glm-5.2-b200-4gpu/README.md)
- [glm-5.2-b200-8gpu](glm-5.2-b200-8gpu/README.md)
- [glm-5.2-nvfp4-b200-4gpu](glm-5.2-nvfp4-b200-4gpu/README.md)
- [qwen3-8b](qwen3-8b/README.md)
- [qwen3-8b-l4-1gpu](qwen3-8b-l4-1gpu/README.md)
- [qwen36-27b](qwen36-27b/README.md)
- [qwen36-27b-a100-80gb-1gpu](qwen36-27b-a100-80gb-1gpu/README.md)
- [qwen36-27b-a100-80gb-2gpu](qwen36-27b-a100-80gb-2gpu/README.md)
- [qwen36-27b-a100-80gb-4gpu](qwen36-27b-a100-80gb-4gpu/README.md)
- [qwen36-27b-a100-80gb-8gpu](qwen36-27b-a100-80gb-8gpu/README.md)
- [qwen36-27b-b200-1gpu](qwen36-27b-b200-1gpu/README.md)
- [qwen36-27b-b200-2gpu](qwen36-27b-b200-2gpu/README.md)
- [qwen36-27b-b200-4gpu](qwen36-27b-b200-4gpu/README.md)
- [qwen36-27b-b200-8gpu](qwen36-27b-b200-8gpu/README.md)
- [qwen36-27b-h100-80gb-1gpu](qwen36-27b-h100-80gb-1gpu/README.md)
- [qwen36-27b-h100-80gb-2gpu](qwen36-27b-h100-80gb-2gpu/README.md)
- [qwen36-27b-h100-80gb-4gpu](qwen36-27b-h100-80gb-4gpu/README.md)
- [qwen36-27b-h100-80gb-8gpu](qwen36-27b-h100-80gb-8gpu/README.md)
- [qwen36-27b-h200-1gpu](qwen36-27b-h200-1gpu/README.md)
- [qwen36-27b-h200-2gpu](qwen36-27b-h200-2gpu/README.md)
- [qwen36-27b-h200-4gpu](qwen36-27b-h200-4gpu/README.md)
- [qwen36-27b-h200-8gpu](qwen36-27b-h200-8gpu/README.md)
- [qwen36-27b-l4-2gpu](qwen36-27b-l4-2gpu/README.md)
- [qwen36-27b-l4-4gpu](qwen36-27b-l4-4gpu/README.md)
- [qwen36-27b-l4-8gpu](qwen36-27b-l4-8gpu/README.md)
- [qwen36-27b-l40s-1gpu](qwen36-27b-l40s-1gpu/README.md)
- [qwen36-27b-l40s-2gpu](qwen36-27b-l40s-2gpu/README.md)
- [qwen36-27b-l40s-4gpu](qwen36-27b-l40s-4gpu/README.md)
- [qwen36-27b-l40s-8gpu](qwen36-27b-l40s-8gpu/README.md)
