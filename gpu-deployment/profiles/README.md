# GPU profiles

Run host preparation and weight downloads from this directory, then paste the
selected YAML into Distr as the complete Helm values document.

```bash
cd gpu-deployment/profiles
./install.sh
cd <profile>
./weights.sh
```

`install.sh` prepares NVIDIA drivers, Docker, k3s, kubectl, and the NVIDIA
device plugin on Debian/Ubuntu and Rocky/RHEL-family hosts. Rocky/RHEL requires
a working host driver before installation (`nvidia-smi` must succeed); the
script does not replace RPM-family GPU drivers. It preserves active
`firewalld`, adding the k3s network rules and profile NodePorts `30001-30006`.
On enforcing SELinux hosts it labels the supported model directories for
container access. The NVFP4 + DFLASH profile mounts `/mnt` read-only so both
profile directories are visible to the worker.
On enforcing RPM-family SELinux hosts, only the NVIDIA device-plugin DaemonSet
runs privileged so it can register GPUs with the k3s kubelet; inference workers
remain unprivileged.
Rocky/RHEL 8 cgroup v1 hosts receive the kubelet compatibility setting needed
by current k3s releases; future images should use cgroup v2.
The script pins k3s to `v1.36.0+k3s1` and replaces a mismatched installed
version; override `K3S_VERSION` only when validating a newer runtime against
the Distr registry image.
It may request a reboot for Debian/Ubuntu driver installation; rerun it
afterward.

Each profile directory contains its own `values.yaml` and `weights.sh`. The
script declares only that profile's repositories and target paths, securely
prompts for a Hugging Face token and download root, and runs the Hugging Face
CLI downloads on the host. It verifies Python 3.9+, installs the distro Python
and venv packages when needed, and verifies the resulting `hf` command before
requesting a token. For example:

```bash
cd glm-5.2-nvfp4-b200-4gpu
./weights.sh
```

Accept the default download root unless you also update `worker.modelPath`, the
selected chart runtime preset's draft-model path, and `worker.weights.hostPath`.
The script creates each model directory beneath the chosen root. It
passes the token through the `HF_TOKEN` environment variable, never echoes it,
and never places it in the process command line.

Each YAML begins with its exact `install.sh` and `weights.sh` commands. Profile
families are:

| Model | Profile YAML | Weight repositories |
|---|---|---|
| GLM-5.2 NVFP4 + DFLASH, 4×B200 | `glm-5.2-nvfp4-b200-4gpu/` | `nvidia/GLM-5.2-NVFP4`, then `SubconsciousDev/glm-5.2-fp8-dflash-v2` |
| GLM-5.2 FP8 + DFLASH, 4×B200 | `glm-5.2-b200-4gpu/` | `zai-org/GLM-5.2-FP8`, then `SubconsciousDev/glm-5.2-fp8-dflash-v2` |
| GLM-5.2 FP8 + DFLASH, 8×B200 | `glm-5.2-b200-8gpu/` | Same two repositories |
| Qwen3.6-27B-FP8 | `qwen36-27b-{gpu}-{count}gpu/` | `Qwen/Qwen3.6-27B-FP8` |
| Qwen3-8B-FP8 | `qwen3-8b-l4-1gpu/` | `Qwen/Qwen3-8B-FP8` |

The NVFP4 profile uses `registry.distr.sh/subconscious/timrun:sm_100-v0.13`,
serves `glm-5.2`, and exposes the existing `glm-52` route on NodePort `30001`.
It serves `/mnt/model-test/glm-5.2-nvfp4` with the DFLASH draft at
`/mnt/model-test/glm-5.2-fp8-dflash-v2`. Its concise YAML selects the
chart-owned `glm-5.2-nvfp4-dflash-b200-4gpu` runtime preset, which follows the
Baseten `Braintree-2` settings with tensor parallelism reduced from 8 to 4.

The legacy `qwen36-27b/` and `qwen3-8b/` directories remain available for
existing multi-worker installs. New installs should use topology-specific
filenames.

All profiles mount downloaded weights read-only. The chart contains no model
downloader or Hugging Face secret; a worker fails to start if its
configured host path was not populated first.
