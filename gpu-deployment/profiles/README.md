# GPU profiles

Run host preparation and weight downloads from this directory, then paste the
selected YAML into Distr as the complete Helm values document.

```bash
cd gpu-deployment/profiles
./install.sh
./weights.sh <profile.yaml>
```

`install.sh` prepares NVIDIA drivers, Docker, k3s, kubectl, and the NVIDIA
device plugin. It may request a reboot; rerun it afterward.

`weights.sh` securely prompts for a Hugging Face token and a download root. It
reads every `hfRepo` and `targetPath` declared by the selected profile and runs
the Hugging Face CLI downloads on the host. For example:

```bash
./weights.sh glm-5.2-nvfp4-b200-4gpu.yaml
```

Accept the default download root unless you also update `worker.modelPath`, any
draft-model path in `worker.sglang.extraArgs`, and `worker.weights.hostPath` in
the YAML. The script creates each model directory beneath the chosen root. It
passes the token through the `HF_TOKEN` environment variable, never echoes it,
and never places it in the process command line.

Each YAML begins with its exact `install.sh` and `weights.sh` commands. Profile
families are:

| Model | Profile YAML | Weight repositories |
|---|---|---|
| GLM-5.2 NVFP4, 4×B200 | `glm-5.2-nvfp4-b200-4gpu.yaml` | `nvidia/GLM-5.2-NVFP4` |
| GLM-5.2 FP8 + DFLASH, 4×B200 | `glm-5.2-b200-4gpu.yaml` | `zai-org/GLM-5.2-FP8`, then `SubconsciousDev/glm-5.2-fp8-dflash-v2` |
| GLM-5.2 FP8 + DFLASH, 8×B200 | `glm-5.2-b200-8gpu.yaml` | Same two repositories |
| Qwen3.6-27B-FP8 | `qwen36-27b-{gpu}-{count}gpu.yaml` | `Qwen/Qwen3.6-27B-FP8` |
| Qwen3-8B-FP8 | `qwen3-8b-l4-1gpu.yaml` | `Qwen/Qwen3-8B-FP8` |

The legacy `qwen36-27b.yaml` and `qwen3-8b.yaml` files remain available for
existing multi-worker installs. New installs should use topology-specific
filenames.

All profiles mount downloaded weights read-only. Kubernetes does not download
models during Helm Apply; a worker remains pending or fails to start if its
configured host path was not populated first.
