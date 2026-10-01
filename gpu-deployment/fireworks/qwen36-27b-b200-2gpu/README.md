# qwen36-27b-b200-2gpu on Fireworks

Reference profile only. The helper prints guidance and exits; this platform has no SSH/k3s deployment path.

## Model and resources

| Setting | Value |
| --- | --- |
| Model | `qwen3.6-27b` |
| Host GPUs | 2 × b200 |
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
cd gpu-deployment/fireworks/qwen36-27b-b200-2gpu
cp .env.example .env
# Fill in the account settings and an absolute SSH key path as needed.
./deploy.sh --help
```

The helper reads `.env` as literal assignments, without shell expansion.
Exported nonempty environment variables take precedence. Keep model/runtime
changes in this folder's `values.yaml`; keep download and mount paths aligned.

Running `./deploy.sh` prints guidance and exits with an error. The local
values and download script describe the model's requirements; they are not a
Fireworks deployment configuration. Do not run the host installer against a
managed endpoint. A compatible native platform configuration is still needed.

See the [provider guide](../README.md) and [source/validation notes](../../profiles/PROVIDER-SOURCES.md). These profiles have not been exercised on live cloud GPUs.
