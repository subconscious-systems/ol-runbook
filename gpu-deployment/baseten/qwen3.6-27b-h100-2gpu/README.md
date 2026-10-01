# qwen3.6-27b-h100-2gpu

| Setting | Value |
| --- | --- |
| Baseten model name | `Braintree-1` |
| Example request model | `Qwen/Qwen3.6-27B` |
| Accelerator | `H100:2` |
| Image | `subconsciouslabs/sglang-baseten:h100-v0` |
| Prediction concurrency | 48 |
| Health endpoint | `/health` |
| Prediction endpoint | `/v1/chat/completions` |

`config.yaml` is the existing Truss configuration, with its image, launch
command, and weight revisions preserved. Review it before changing resources.

## Required secrets

- `DOCKER_REGISTRY_https://index.docker.io/v1/`
- `hf_access_token`

Configure these through your Baseten account as described in the
[shared Baseten guide](../README.md).

## Preview and deploy

From this profile directory:

```bash
./deploy.sh --dry-run
./deploy.sh
```

The first command performs local checks and prints the Truss push command.
The second creates or updates this configuration's Baseten deployment.
See the [setup and verification guide](../README.md) for credentials,
dependencies, source caveats, and endpoint checks.
