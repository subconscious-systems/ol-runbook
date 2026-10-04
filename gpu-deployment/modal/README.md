# Modal deployments

Each subfolder is a complete model/GPU profile with its own serving app,
weight-download job, environment example, and endpoint test. The profiles
share the Python dependency lockfile in this directory.

| Profile | GPUs | CPU cores / host RAM | Configuration source |
| --- | --- | --- | --- |
| [GLM-5.2 FP8, eight B200s](glm-5.2-fp8-b200-8gpu/README.md) | `B200:8` | 64 / 1,363,149 MiB | Existing Modal deployment |
| [GLM-5.2 FP8, four B200s](glm-5.2-fp8-b200-4gpu/README.md) | `B200:4` | 32 / 681,575 MiB | Modal deployment with the existing four-GPU profile's resources |
| [GLM-5.2 NVFP4, four B200s](glm-5.2-nvfp4-b200-4gpu/README.md) | `B200:4` | 32 / 681,575 MiB | Modal deployment mechanics with the existing NVFP4 profile's launch settings |

All three use a DFLASH draft model. The eight-GPU FP8 app comes from the
existing Modal repo; the four-GPU apps are adaptations that still need live
validation. See [SOURCE.md](SOURCE.md) for provenance.

## Folder layout

```text
modal/
  pyproject.toml
  uv.lock
  glm-5.2-fp8-b200-8gpu/
    README.md
    .env.example
    deploy.py
    download_weights.py
    scripts/write_secrets.py
    scripts/test_endpoint.py
  glm-5.2-fp8-b200-4gpu/
    ...
  glm-5.2-nvfp4-b200-4gpu/
    ...
```

`deploy.py` keeps GPU resources, model paths, image settings, and the complete
SGLang command together. Change a profile in its own directory.

## Set up one profile

Install [uv](https://docs.astral.sh/uv/getting-started/installation/), then run
these commands from the runbook root. Choose a different subfolder for another
profile:

```bash
cd gpu-deployment/modal/glm-5.2-fp8-b200-8gpu
uv sync --frozen
uv run --frozen modal setup
cp .env.example .env
```

Edit `.env` with the runtime image, registry credentials, and Hugging Face
token provided for your deployment. Each profile reads its own `.env`.
The image must include the custom SGLang runtime, DFLASH/fa4 support, and the
GLM chat template at `/sgl-workspace/sglang/deploy/chat_templates/glm5.2.jinja`.
The FP8 examples require an image to be supplied. The NVFP4 example retains
the image path from the existing four-GPU profile; use credentials for that
registry, or select an equivalent image your organization can pull.

```bash
# Store the configured registry and Hugging Face credentials as Modal secrets.
uv run --frozen python scripts/write_secrets.py

# Download the main and draft checkpoints with a CPU job.
uv run --frozen modal run download_weights.py

# Deploy the selected GPU serving app.
uv run --frozen modal deploy deploy.py
```

The secret helper uses a temporary file with mode 0600 and removes it after
the CLI completes. It updates the two secret names in `.env`; profiles using
the same names share those credentials. Do not commit `.env`.

## Apps, weights, and caches

Each profile has a distinct app name and cache volume. The two FP8 profiles
share the same FP8 weights volume, so the checkpoints need to be downloaded
only once. NVFP4 has a separate weights volume. Each download job stages both
the main model and DFLASH draft under `/models`; the serving command reads
those local paths.

The examples retain one minimum and one maximum serving container. Deploying
a profile therefore keeps its GPU container warm and can incur charges even
when it is idle. Starting a second profile creates a separate serving app.
Adjust those settings in `deploy.py` for your intended lifecycle.

These are new profile-specific app/cache names. They do not rename or stop
an existing Modal deployment or migrate its volumes.

## Verify and operate

After Modal reports the app ready, use the endpoint URL it returns:

```bash
uv run --frozen python scripts/test_endpoint.py https://<your-endpoint>.modal.run
```

The test sends a streaming request for the served model name `glm-5.2`.
Verify the response before adding the endpoint to the gateway. The copied
web-server setup does not enable Modal proxy authentication; configure your
deployment's access controls before sharing the endpoint.

From the selected profile directory:

```bash
uv run --frozen modal app list
uv run --frozen modal app logs <app-name>
uv run --frozen modal app stop <app-name>
```

The exact app name is in that profile's README and `APP_NAME` in `deploy.py`.
For an ephemeral development run, use `uv run --frozen modal serve deploy.py`.

Modal references: [GPU allocation](https://modal.com/docs/guide/gpu),
[web servers](https://modal.com/docs/guide/webhooks#non-asgi-web-servers), and
[volumes](https://modal.com/docs/guide/volumes).
