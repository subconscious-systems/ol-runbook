"""Download this profile's main and draft checkpoints into its Modal Volume."""
import os
from pathlib import Path


def _hf_secret() -> str:
    value = os.environ.get("HF_TOKEN_SECRET")
    if value:
        return value
    path = Path(__file__).resolve().parent / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                if key.strip() == "HF_TOKEN_SECRET" and value.strip():
                    return value.strip().strip('"').strip("'")
    return "SUBCONSCIOUS_HF_TOKEN"

import modal

WEIGHTS_VOLUME = "subconscious-glm-5-2-fp8-weights"
WEIGHTS_MOUNT = "/models"
HF_SECRET = _hf_secret()

MODELS = [
    {
        "repo_id": "zai-org/GLM-5.2-FP8",
        "revision": None,
        "local_dir": "/models/glm-5.2-fp8",
    },
    {
        "repo_id": "SubconsciousDev/glm-5.2-fp8-dflash-v2",
        "revision": None,
        "local_dir": "/models/glm-5.2-fp8-dflash-v2",
    },
]

image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install("huggingface_hub")
    .env({"HF_XET_HIGH_PERFORMANCE": "1"})
)

app = modal.App("subconscious-glm-5-2-fp8-b200-8gpu-weights")
vol = modal.Volume.from_name(WEIGHTS_VOLUME, create_if_missing=True)


@app.function(
    image=image,
    volumes={WEIGHTS_MOUNT: vol},
    secrets=[modal.Secret.from_name(HF_SECRET, required_keys=["HF_TOKEN"])],
    timeout=14400,
    cpu=8.0,
    memory=64 * 1024,
)
def download():
    from huggingface_hub import snapshot_download

    for spec in MODELS:
        rev = spec["revision"]
        label = f"{spec['repo_id']}" + (f"@{rev}" if rev else "")
        print(f"Downloading {label} -> {spec['local_dir']} ...")
        kwargs = {
            "repo_id": spec["repo_id"],
            "local_dir": spec["local_dir"],
            "repo_type": "model",
        }
        if rev:
            kwargs["revision"] = rev
        snapshot_download(**kwargs)
        vol.commit()
        print(f"  committed {spec['local_dir']}")
    print(f"Done. Weights on volume '{WEIGHTS_VOLUME}'.")


@app.local_entrypoint()
def main():
    download.remote()
