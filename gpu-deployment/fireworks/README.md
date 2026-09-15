# Fireworks deployment profiles

Prints managed-platform guidance. There is no native deployment implementation or SSH host-preparation path.

## Choose a profile

Each model/GPU subfolder contains a `deploy.sh` entry point. The same 29
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

## Files used by this profile

- [Launch settings](../profiles/qwen36-27b-h100-80gb-2gpu/values.yaml) and
  [weight download](../profiles/qwen36-27b-h100-80gb-2gpu/weights.sh) remain under `profiles/`.
- [Provider implementation](../profiles/_providers/fireworks.sh) supplies
  the cloud-specific behavior and environment-variable help.
- [Shared host setup](../profiles/_deploy.sh) performs the common steps.

The earlier `profiles/<profile>/fireworks/deploy.sh` paths remain available.
