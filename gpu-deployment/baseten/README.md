# Baseten deployment

Deploy the Subconscious Inference System runtime with a native Baseten Truss
configuration. Choose one of the configurations below, review it, then push it
to your Baseten account.

These six configurations are the accepted starting copies from the existing
SGLang deployment checkout. GPU counts, image tags, model revisions, paths,
and launch flags are preserved. They have not been verified against a live
Baseten deployment in this PR. Replace them when newer configurations arrive.

## Choose a configuration

| Configuration directory | Model and GPUs | Speculation | Image tag |
| --- | --- | --- | --- |
| `glm-5.2-nvfp4-b200-8gpu-dflash` | GLM-5.2 NVFP4, 8 × B200 | DFLASH | `sm_100-v0.9` |
| `glm-5.2-nvfp4-b200-8gpu-eagle` | GLM-5.2 NVFP4, 8 × B200 | EAGLE | `sm_100-v0.8` |
| `glm-5.2-nvfp4-b200-4gpu-eagle` | GLM-5.2 NVFP4, 4 × B200 | EAGLE | `sm_100-v0.1` |
| `glm-5.2-fp8-b200-8gpu-eagle` | GLM-5.2 FP8, 8 × B200 | EAGLE | `b200-v0` |
| `qwen3.6-27b-h100-2gpu` | Qwen3.6-27B, 2 × H100 | As specified in config | `h100-v0` |
| `qwen3.6-27b-b200-1gpu` | Qwen3.6-27B, 1 × B200 | As specified in config | `sm_100-v0` (Distr registry) |

Directory names identify the model and hardware. These configurations are selected
independently of `../profiles/`: its GLM DFLASH and Qwen FP8 Helm profiles are
not interchangeable with these Baseten variants.

## Inspect before pushing

From the runbook root, with Python 3.10+ installed:

```bash
cd gpu-deployment/baseten
./deploy.sh --list
./deploy.sh glm-5.2-nvfp4-b200-8gpu-dflash --dry-run
```

`--dry-run` checks that the named config and image field exist, checks the
Distr registry-secret declaration when applicable, and prints the exact push
command. It does not install dependencies, contact Baseten, validate the full
Truss schema, or check credentials, GPU availability, or runtime health.

Open the chosen `config.yaml` and review these fields:

- `model_name`: the copies use `Braintree-1` or `Braintree-2`. Choose a distinct
  name for a separate deployment; several variants target the same model name.
- `base_image.image`: the image tag and registry your account can pull.
- `resources.accelerator`: the exact GPU type and count.
- `weights`: checkpoint revision and mount path.
- `docker_server.start_command`: runtime settings and any draft-model path.
- `runtime`: concurrency and health-check timing.

## Set up access

Install [uv](https://docs.astral.sh/uv/getting-started/installation/), then use
the copied lockfile to install Truss 0.18.6 and its dependencies:

```bash
uv sync --frozen
uv run --frozen truss login
```

In your Baseten account, create the secrets referenced by the chosen config:

| Secret | Used for |
| --- | --- |
| `hf_access_token` | Access to the gated Hugging Face checkpoint in `weights` |
| `DOCKER_REGISTRY_https://index.docker.io/v1/` | Private Docker Hub image pulls where declared |
| `DOCKER_REGISTRY_registry.distr.sh` | The Distr image used by `qwen3.6-27b-b200-1gpu` |

Use the registry credentials supplied for your deployment. Follow Baseten's
[private-registry instructions](https://docs.baseten.co/development/model/private-registries)
for the secret value format. Keep credential values in Baseten and your local
CLI configuration; the checked-in YAML contains secret names only.

Two source details need review for the selected account:

- The FP8 `glm-5.2-fp8-b200-8gpu-eagle` config does not declare a Docker Hub
  registry secret. If that image is private for your deployment, add the
  Docker Hub secret declaration used by the other Docker Hub configs.
- The DFLASH config mounts the main model through Baseten's weight cache but
  references its draft by Hugging Face repository name. It does not declare a
  draft weight mount or an `HF_TOKEN` runtime environment variable. Ensure the
  serving container can access that gated draft, or supply an updated config
  that mounts it and uses its local path.

Chat-template paths refer to files already inside the serving image under
`/sgl-workspace/sglang/deploy/chat_templates/`. The Truss push does not build the
SGLang image or install those files into it.

## Push the selected configuration

```bash
./deploy.sh glm-5.2-nvfp4-b200-8gpu-dflash
```

The helper calls `uv run --frozen --directory <config-directory> truss push`
and returns its exit status. The original Python entry point is also available:

```bash
uv run --frozen python push_truss.py glm-5.2-nvfp4-b200-8gpu-dflash
```

This command creates or updates a Baseten model deployment and can allocate
billable GPUs. It runs the serving container through Baseten. It does not run
the SSH/k3s installer, the host `weights.sh`, or AWS/GCP routing Terraform.

For account/environment options beyond this helper, use the installed CLI's
`uv run --frozen truss push --help` from the chosen config directory.
The [Truss push reference](https://docs.baseten.co/reference/cli/truss/push)
describes the platform deployment operation; flags may differ in the copied
Truss version.

## Verify the endpoint

Use the model/deployment URL and API key from Baseten. These configs bind the
server to port 8000, use `/health` for health checks, and map prediction to
`/v1/chat/completions`. Follow Baseten's
[custom-server endpoint mapping](https://docs.baseten.co/development/model/custom-server#endpoint-mapping)
to send a streaming chat request through its external URL. Verify the selected
model and streaming response before registering the endpoint with your gateway.

## Replace a configuration later

Replace the relevant `<configuration>/config.yaml`, review its image and
secret requirements, then run `./deploy.sh <configuration> --dry-run` again.
Keep the internal and runbook copies synchronized. Source paths and import
revision are recorded in [SOURCE.md](SOURCE.md).
