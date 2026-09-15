# GLM-5.2 FP8 on 8 B200 GPUs

| Setting | Value |
| --- | --- |
| Modal app | `subconscious-glm-5-2-fp8-b200-8gpu` |
| GPUs / tensor parallelism | `B200:8` / `8` |
| Host CPU / memory | 64 cores / 1,363,149 MiB |
| Served model | `glm-5.2` |
| Draft model | `SubconsciousDev/glm-5.2-fp8-dflash-v2` (DFLASH) |
| Weights volume | `subconscious-glm-5-2-fp8-weights` |
| Cache volume | `subconscious-glm-5-2-fp8-b200-8gpu-cache` |
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
uv run --frozen modal app stop subconscious-glm-5-2-fp8-b200-8gpu
```

See [source and validation notes](../SOURCE.md) before treating this profile as
a live-tested deployment.
