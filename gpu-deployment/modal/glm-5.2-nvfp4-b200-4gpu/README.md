# GLM-5.2 NVFP4 on 4 B200 GPUs

| Setting | Value |
| --- | --- |
| Modal app | `subconscious-glm-5-2-nvfp4-b200-4gpu` |
| GPUs / tensor parallelism | `B200:4` / `4` |
| Host CPU / memory | 32 cores / 681,575 MiB |
| Served model | `glm-5.2` |
| Draft model | `SubconsciousDev/glm-5.2-fp8-dflash-v2` (DFLASH) |
| Weights volume | `subconscious-glm-5-2-nvfp4-weights` |
| Cache volume | `subconscious-glm-5-2-nvfp4-b200-4gpu-cache` |
| Minimum / maximum containers | 1 / 1 |

Follow the [shared setup instructions](../README.md#set-up-one-profile) from
this directory. The files you edit are `.env` (credentials and image) and
`deploy.py` (resources and runtime settings).

```bash
uv sync --frozen
uv run --frozen modal setup
cp .env.example .env
# Fill in .env before continuing.
uv run --frozen python scripts/write_secrets.py
uv run --frozen modal run download_weights.py
uv run --frozen modal deploy deploy.py
```

`download_weights.py` stages both checkpoints before the serving container
starts. The GPU app serves the local model files under `/models`. Test the
endpoint with `uv run --frozen python scripts/test_endpoint.py <endpoint-url>`.

Stop this app with:

```bash
uv run --frozen modal app stop subconscious-glm-5-2-nvfp4-b200-4gpu
```

See [source and validation notes](../SOURCE.md) before treating this profile as
a live-tested deployment.
