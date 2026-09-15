# glm-5.2-b200-4gpu on Azure

No default instance type is configured for this topology. Use a matching existing host or supply an explicit provider instance type after checking its resources.

## Model and resources

| Setting | Value |
| --- | --- |
| Model | `glm-5.2` |
| Host GPUs | 4 × b200 |
| Workers / GPUs per worker | 1 / 4 |
| Tensor parallelism per worker | 4 |
| CPU / RAM requested per worker | 32 / 681575Mi |
| CPU / RAM limit per worker | 32 / 681575Mi |
| Image | `registry.distr.sh/subconscious/timrun:sm_100-v1` |
| Model path | `/models/hf/GLM-5.2-FP8` |
| Worker NodePorts | 30001 |
| Helper instance default | Explicit selection or existing host required |

Host capacity must cover all workers plus the operating system and k3s.
The values below retain the existing runtime tuning and image path.

## Files

- `values.yaml`: local model, GPU, image, runtime flags, and mount settings.
- `weights.sh`: downloads the checkpoints listed below.
- `.env.example`: provider and SSH configuration; copy to `.env` to customize.
- `deploy.sh`: reads this folder's settings and invokes the provider helper.

| Checkpoint | Host destination |
| --- | --- |
| `zai-org/GLM-5.2-FP8` | `/models/hf/GLM-5.2-FP8` |
| `SubconsciousDev/glm-5.2-fp8-dflash-v2` | `/models/hf/glm-5.2-fp8-dflash-v2` |

## Configure and inspect

From the runbook root:

```bash
cd gpu-deployment/azure/glm-5.2-b200-4gpu
cp .env.example .env
# Fill in the account settings and an absolute SSH key path as needed.
./deploy.sh --help
```

The helper reads `.env` as literal assignments, without shell expansion.
Exported nonempty environment variables take precedence. Keep model/runtime
changes in this folder's `values.yaml`; keep download and mount paths aligned.

## Prepare the host

For an existing host, replace this example address:

```bash
./deploy.sh --instance-ip 203.0.113.10
```

The helper copies this folder's `values.yaml` and `weights.sh`, prepares the
host, and runs the interactive weight download. It prompts for a Hugging Face
token on the host. The shared downloader handles the required local tooling.

To create a VM instead, fill the provider settings, confirm a matching
instance type and sufficient host memory, then run `./deploy.sh` without
`--instance-ip`. This creates cloud resources.

## Start and verify the runtime

Host preparation stops after downloading weights. Follow the
[runtime deployment guide](../../README.md) with your FDE to supply image
access and worker credentials and apply this folder's `values.yaml`.
The existing Helm values retain Distr secret references; adapt credentials
for your deployment. Verify `/health` and `/health_generate` on the configured
worker port(s) (30001) before registering the endpoint with the gateway.

See the [provider guide](../README.md) and [source/validation notes](../../profiles/PROVIDER-SOURCES.md). These profiles have not been exercised on live cloud GPUs.
