# GPU profiles

Launch profiles and host-preparation helpers used by Subconscious FDEs.
For customer deployment, start with [the GPU deployment guide](../README.md):
your FDE supplies Docker Hub pull credentials and helps you run the image.

These files retain the existing k3s/Helm profile format, including Distr image
and secret references. They are not a complete self-serve Docker Hub installer.
Your FDE must adapt the runtime image and credentials before starting workers.

## Choose the deployment path

| What you need | Starting point | Result |
| --- | --- | --- |
| Run the runtime on GPUs you already have | [GPU deployment guide](../README.md) | FDE-assisted deployment of your Docker Hub image |
| Prepare a k3s GPU host | Provider helpers below, or `install.sh` on the host | Drivers/toolkit, k3s, and staged model weights |
| Give an existing AWS worker an HTTPS endpoint | [AWS worker routing](../terraform/aws-private-workers/README.md) | Private HTTPS routing to a healthy worker |
| Give an existing GCP worker an HTTPS endpoint | [GCP worker routing](../terraform/gcp-workers/README.md) | Internal or public HTTPS routing to a healthy worker |
| Deploy on a managed inference platform | A platform-specific deployment configuration | A platform-managed inference endpoint |

## Choose a model and GPU layout

Each profile contains `values.yaml` (launch settings) and `weights.sh` (model
downloads). Provider folders contain editable copies alongside environment
examples and profile-specific instructions; deploy helpers use those local copies. The directory name identifies the model, GPU type, and GPU count.
For example, `qwen36-27b-h100-80gb-2gpu` requires two H100 80 GB GPUs.

| Model | Profile directory |
| --- | --- |
| GLM-5.2 NVFP4 + DFLASH, four B200s | `glm-5.2-nvfp4-b200-4gpu` |
| GLM-5.2 FP8 + DFLASH, four or eight B200s | `glm-5.2-b200-{4,8}gpu` |
| Qwen3.6-27B FP8 | `qwen36-27b-{gpu}-{count}gpu` |
| Qwen3-8B FP8, one L4 | `qwen3-8b-l4-1gpu` |

The legacy `qwen36-27b` and `qwen3-8b` profiles describe multiple workers on
one host. Inspect their values before selecting a worker layout.

## Provider helpers

Provider directories beside `profiles/` contain `<profile>/deploy.sh` entry
points, for example `../azure/qwen36-27b-h100-80gb-2gpu/deploy.sh`.
The earlier `<profile>/<provider>/deploy.sh` paths remain available. The table
describes code present in this branch; it is not a certification of live cloud
deployment. Verify the provider API, GPU type/count, memory, region, image, and
quota before creating resources. Some current defaults and API calls still
need validation and correction.

| Provider | What the helper implements | Configuration to review |
| --- | --- | --- |
| AWS | EC2 creation, then SSH host preparation | `AWS_REGION`, `AWS_INSTANCE_TYPE`, `AMI_ID`, `KEY_NAME`, `SUBNET_ID`, `SG_ID` |
| GCP | Compute Engine creation, then host preparation through `gcloud` | `GCP_PROJECT`, `GCP_ZONE`, `GCP_MACHINE_TYPE`, `GCP_NETWORK` |
| Azure | VM creation and NVIDIA extension, then SSH host preparation | `AZ_RESOURCE_GROUP`, `AZ_LOCATION`, `AZURE_VM_SIZE` |
| OCI | Instance creation, then SSH host preparation | `OCI_COMPARTMENT`, `OCI_SHAPE`, `OCI_SUBNET`, `OCI_IMAGE`, `OCI_AD` |
| Lambda | API-based instance creation, then SSH host preparation | `LAMBDA_API_KEY`, `LAMBDA_REGION`, `LAMBDA_INSTANCE_TYPE`; launch API needs correction |
| Crusoe | CLI-based VM creation, then SSH host preparation | `CRUSOE_INSTANCE_TYPE`, `CRUSOE_LOCATION`, `CRUSOE_IMAGE`; verify CLI flags |
| CoreWeave | CLI-based Virtual Server creation, then SSH host preparation | `COREWEAVE_FLAVOR`, `COREWEAVE_IMAGE`, `COREWEAVE_REGION`; verify CLI flags |
| Nebius | Prints manual provisioning instructions; can prepare an existing SSH host | `SSH_KEY`, `SSH_USER`, `SSH_PORT` |
| Together | Prints manual provisioning instructions; can prepare an existing SSH host | `SSH_KEY`, `SSH_USER`, `SSH_PORT` |
| Baseten | Directs you to the [native Truss configs and push helper](../baseten/README.md) | Select the Baseten config explicitly; it may differ from this Helm profile |
| Fireworks | Prints platform guidance; no deployment implementation | Use a compatible managed endpoint separately |
| Modal | [Native deployment profiles](../modal/README.md), each in its own folder | Select FP8 on four/eight B200s or NVFP4 on four B200s |

Baseten and Modal run the serving container through their own deployment APIs.
Their platform configurations must carry the image, model paths, launch flags,
GPU resources, and endpoint settings. The SSH/k3s helper is not that deployment.

### Inspect the selected helper

From this directory:

```bash
cd ../azure/qwen36-27b-h100-80gb-2gpu
./deploy.sh --help
```

Help prints the selected profile and provider-specific environment variables.
It does not create resources. After your FDE has checked the configuration,
running without `--help` starts the provider's provisioning path and can incur
cloud charges. AWS, GCP, and Azure helpers currently create public SSH and
worker-port ingress by default; review that networking before use.

### Continue on an existing GPU host

For a provider that supplies a general-purpose SSH host:

```bash
SSH_USER=ubuntu SSH_KEY="$HOME/.ssh/id_ed25519" \
  ./deploy.sh --instance-ip 203.0.113.10
```

Replace the example address and SSH user with your host's details. This skips
VM creation, prepares the host, stages the profile, and starts the interactive
weight download. It does not launch the inference runtime. If driver setup
requests a reboot, reboot the host and rerun with the same address and SSH
settings. Baseten and Fireworks do not use this host-preparation path.

### What host preparation does

1. Connects to the GPU host and copies `values.yaml`, `weights.sh`, and the
   shared downloader.
2. Runs `install.sh` to prepare NVIDIA tooling, Docker, k3s, and the device
   plugin. Rocky/RHEL hosts must already have a working NVIDIA driver.
3. Runs `weights.sh`, which prompts for a Hugging Face token without echoing it.
   GLM profiles download both the main checkpoint and the DFLASH draft.
4. Prints the remaining FDE-assisted runtime and endpoint setup steps.

Keep the default weight paths unless you also update the model, draft, and
mount paths in the runtime configuration. On SELinux hosts the downloader
labels its selected root for container access. It does not relabel the parent
mount. Weights are mounted read-only by the profiles.

After the runtime starts, verify its health before configuring AWS/GCP routing
and adding the endpoint to the gateway dashboard. Host preparation alone does
not establish a healthy inference endpoint.
