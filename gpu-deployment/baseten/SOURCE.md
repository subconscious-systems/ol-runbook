# Baseten source snapshot

Imported on 2026-09-15 from `SubconsciousCache-SGLang/deploy/`, branch
`hi-transfer`, checkout commit `c15e65f7a9ab48f57c5d67a6b90367d15fd4e018`.
The last commit touching that deployment directory was `4d013ea5e`
(2026-08-25). The user selected these local configurations as the starting
point and will supply replacements if needed.

The six `*/config.yaml` files, `pyproject.toml`, and `uv.lock` were copied
byte-for-byte. Configuration directories are named by model, precision, GPU
layout, and speculative decoder. The lockfile selects Truss
0.18.6. No credential values were copied.

`push_truss.py` comes from the same source, with a named-config selector,
`--list`, `--dry-run`, command display, and frozen dependency resolution added.
`deploy.sh` is a small entry point for that Python helper. Runtime settings in
the YAML were not translated to or from the Helm profiles.

When replacing a file, record its new source/revision here and mirror it to
both repositories. New configurations can be added as `<name>/config.yaml`;
the helper discovers those directories automatically.
