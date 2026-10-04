# Modal profile sources

Imported on 2026-09-15 from the `modal-deploy` repository at commit
`3ac6187f8264041fb341deba2bc6a2c350d4de4f`. The source provided the serving
image setup, SGLang command, weight/cache volumes, weight downloader,
credential helper, and streaming endpoint test.

- `glm-5.2-fp8-b200-8gpu` preserves the source's eight-GPU resources and
  SGLang tuning.
- `glm-5.2-fp8-b200-4gpu` uses the four-GPU CPU/RAM/TP settings from
  `profiles/glm-5.2-b200-4gpu/values.yaml` in the GPU deployment repo.
- `glm-5.2-nvfp4-b200-4gpu` uses the model and runtime flags from
  `profiles/glm-5.2-nvfp4-b200-4gpu/values.yaml` in the GPU deployment repo.
  Its model and draft paths are adapted to Modal's `/models` volume mount.

The Helm source revision is `694b9ec7c91cded12fe88bf5e4568435db889223`.
All serving profiles explicitly publish the model name `glm-5.2`. App and
cache names now identify each profile; FP8 profiles share checkpoint storage.
The downloader has an explicit local entry point that calls the remote job.
Credential helpers use configurable secret names and generic registry keys.

The source `uv.lock` and Python version are retained (Modal SDK 1.5.4).
The project description and user instructions are updated for these profiles.
No personal account setup, credential values, or legacy image-build scripts
were copied. Existing published image paths are retained where referenced.

These changes were checked locally without provisioning Modal resources.
The four-GPU variants have not been validated on live Modal GPUs.
