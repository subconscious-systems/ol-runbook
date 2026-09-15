#!/usr/bin/env python3
"""Select and push a copied Baseten Truss config, or preview its push command."""
# uv run python push_truss.py tim-1.5-27b-b200

from __future__ import annotations

import argparse
import re
import shlex
import subprocess
import sys
from pathlib import Path


DISTR_HOST = "registry.distr.sh"
DISTR_SECRET = f"DOCKER_REGISTRY_{DISTR_HOST}"
DEPLOY_DIR = Path(__file__).resolve().parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run `truss push` for a bundled Baseten config. If the base image is on "
            f"{DISTR_HOST}, require secrets.{DISTR_SECRET}."
        )
    )
    parser.add_argument(
        "truss_dir",
        nargs="?",
        choices=sorted(path.parent.name for path in DEPLOY_DIR.glob("*/config.yaml")),
        help="Bundled config directory; use --list to see the available names",
    )
    parser.add_argument("--list", action="store_true", help="List configs without deploying")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Check the local config and print the push command without running Truss",
    )
    return parser.parse_args()


def image_from_config(config: str) -> str | None:
    match = re.search(r"(?m)^  image: (.+)$", config)
    return match.group(1).strip() if match else None


def has_secret(config: str, secret_name: str) -> bool:
    return bool(
        re.search(
            rf"(?m)^  {re.escape(secret_name)}: null$",
            config,
        )
    )


def validate_config(config_path: Path) -> str | None:
    config = config_path.read_text()
    image = image_from_config(config)
    if image is None:
        raise ValueError(f"No base_image.image found in {config_path}")

    if image.startswith(f"{DISTR_HOST}/"):
        if not has_secret(config, DISTR_SECRET):
            raise ValueError(
                f"Distr image {image} requires secrets.\n"
                f"  {DISTR_SECRET}: null\n"
                f"in {config_path}"
            )
        return (
            "Distr registry secret reminder:\n"
            f"  echo -n '-:<DISTR_PAT>' | base64\n"
            f"  Baseten secret name: {DISTR_SECRET}"
        )
    return None


def main() -> int:
    args = parse_args()
    deploy_dir = DEPLOY_DIR
    if args.list:
        for config_path in sorted(deploy_dir.glob("*/config.yaml")):
            print(f"{config_path.parent.name}: {image_from_config(config_path.read_text())}")
        return 0
    if args.truss_dir is None:
        print("Choose a config directory, or use --list to see the options.", file=sys.stderr)
        return 2
    truss_dir = deploy_dir / args.truss_dir
    config_path = truss_dir / "config.yaml"

    if not config_path.is_file():
        print(f"Truss config not found: {config_path}", file=sys.stderr)
        return 1

    try:
        reminder = validate_config(config_path)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if reminder:
        print(reminder)
        print()

    command = ["uv", "run", "--frozen", "--directory", str(truss_dir), "truss", "push"]
    print(f"Config: {config_path}", flush=True)
    print(f"Image: {image_from_config(config_path.read_text())}", flush=True)
    print(f"Command: {shlex.join(command)}", flush=True)
    if args.dry_run:
        print("Dry run: Truss was not invoked; credentials, image access, and runtime health were not checked.")
        return 0

    try:
        result = subprocess.run(command, cwd=deploy_dir, check=False)
    except FileNotFoundError:
        print("uv is required to push. Install uv and run `uv sync --frozen` first.", file=sys.stderr)
        return 1
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
