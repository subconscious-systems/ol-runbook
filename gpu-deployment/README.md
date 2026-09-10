# OrangeLine

**OrangeLine** is the GPU inference runtime for the Subconscious Inference System. It runs TIMRUN on GPUs you provide.

We issue registry credentials for the OrangeLine container, plus launch configuration and recommended instance types. Your Subconscious FDE helps you deploy that image into your environment. Helper scripts cover common hyperscalers and NeoClouds.

Ryvn is not required on every GPU host. In the full inference system, workers attach to the API Gateway as model routes. GPUs can be in the same AWS, GCP, or Azure account as the gateway, or somewhere else (another hyperscaler, a NeoCloud, an inference platform, a local cluster, or bare metal). If you have GPUs we have not named, we can work with that.

For trials, or if you already have a gateway, you can run OrangeLine alone: pull the image with the credentials we issue and point your own routing layer at it. There is no Ryvn install and no Subconscious API Gateway. OrangeLine still serves models. You will not get context pruning visualization and intelligence without our gateway.

This is step 6 in [getting-started.md](../getting-started.md). Product overview: [OrangeLine](https://docs.subconscious.dev/on-prem/inference-runtime/overview). Placement relative to the gateway: [configurations](https://docs.subconscious.dev/on-prem/deployments/configurations).
