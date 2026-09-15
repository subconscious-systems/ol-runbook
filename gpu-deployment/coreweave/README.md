# CoreWeave deployment profiles

Contains a CLI-based Virtual Server provisioning path, followed by SSH host preparation. The CLI contract still needs validation.

## Choose a profile

Each model/GPU subfolder contains a `deploy.sh` entry point. The same 29
[shared model profiles](../profiles/README.md#choose-a-model-and-gpu-layout)
are available here. A listed profile does not certify that this provider
supports its GPU layout; review the
[provider capabilities](../profiles/README.md#provider-helpers) first.

From the runbook root, inspect a profile without creating resources:

```bash
cd gpu-deployment/coreweave/qwen36-27b-h100-80gb-2gpu
./deploy.sh --help
```

Configuration to review: `COREWEAVE_FLAVOR`, `COREWEAVE_IMAGE`, `COREWEAVE_REGION`

For an existing general-purpose GPU host, after reviewing the shared setup
instructions:

```bash
SSH_USER=ubuntu SSH_KEY="$HOME/.ssh/id_ed25519" \
  ./deploy.sh --instance-ip 203.0.113.10
```

Replace the address, user, and key with your host's details. Host preparation
stages model files and downloads weights. Continue with your FDE to deploy
the runtime and register its endpoint. See the
[full host-preparation workflow](../profiles/README.md#what-host-preparation-does).

## Files used by this profile

- [Launch settings](../profiles/qwen36-27b-h100-80gb-2gpu/values.yaml) and
  [weight download](../profiles/qwen36-27b-h100-80gb-2gpu/weights.sh) remain under `profiles/`.
- [Provider implementation](../profiles/_providers/coreweave.sh) supplies
  the cloud-specific behavior and environment-variable help.
- [Shared host setup](../profiles/_deploy.sh) performs the common steps.

The earlier `profiles/<profile>/coreweave/deploy.sh` paths remain available.
