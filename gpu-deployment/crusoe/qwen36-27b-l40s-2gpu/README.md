# qwen36-27b-l40s-2gpu on Crusoe

Use an existing host with `--instance-ip`. The provisioning API/CLI path still needs correction or validation.

## Model and resources

| Setting | Value |
| --- | --- |
| Model | `qwen3.6-27b` |
| Host GPUs | 2 × l40s |
| Workers / GPUs per worker | 1 / 2 |
| Tensor parallelism per worker | 2 |
| CPU / RAM requested per worker | 4 / 32Gi |
| CPU / RAM limit per worker | 16 / 80Gi |
| Image | `registry.distr.sh/subconscious/timrun:sm_89-v2` |
| Model path | `/models/hf/Qwen3.6-27B-FP8` |
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
| `Qwen/Qwen3.6-27B-FP8` | `/models/hf/Qwen3.6-27B-FP8` |

## Configure and inspect

From the runbook root:

```bash
cd gpu-deployment/crusoe/qwen36-27b-l40s-2gpu
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

## Start and verify the runtime

Host preparation stops after downloading weights. Follow the
[runtime deployment guide](../../README.md) with your FDE to supply image
access and worker credentials and apply this folder's `values.yaml`.
The existing Helm values retain Distr secret references; adapt credentials
for your deployment. Verify `/health` and `/health_generate` on the configured
worker port(s) (30001) before registering the endpoint with the gateway.

See the [provider guide](../README.md) and [source/validation notes](../../profiles/PROVIDER-SOURCES.md). These profiles have not been exercised on live cloud GPUs.
