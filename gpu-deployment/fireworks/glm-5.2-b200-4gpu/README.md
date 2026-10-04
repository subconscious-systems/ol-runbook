# glm-5.2-b200-4gpu on Fireworks

Reference profile only. The helper prints guidance and exits; this platform has no SSH/k3s deployment path.

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
cd gpu-deployment/fireworks/glm-5.2-b200-4gpu
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
