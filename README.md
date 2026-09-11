# Subconscious Inference System customer runbook

Customer-facing companion for deploying and operating the **Subconscious Inference System** with your Subconscious FDE.

The API Gateway runs in your AWS, GCP, or Azure account via Ryvn. **OrangeLine**, the inference runtime, runs on GPUs anywhere you can run a Docker container, including the same cloud, a NeoCloud, your own local cluster, or bare metal. For trials or if you already have a gateway, you can run OrangeLine alone.

Public on-prem docs are the source of truth for architecture, methods, compliance, and onboarding. This repo keeps a local security packet, the deployment steps your FDE walks with you, and product how-tos those pages do not own.

- [On-prem overview](https://docs.subconscious.dev/on-prem/overview)
- [How it works](https://docs.subconscious.dev/on-prem/how-it-works)
- [Methods](https://docs.subconscious.dev/on-prem/deployments/methods)
- [Compliance](https://docs.subconscious.dev/on-prem/trust-center/compliance)

## What you are deploying

| Component | Role |
| --- | --- |
| **API Gateway** | Agent traffic, authentication, API keys, routing, usage, and context pruning visualization and intelligence |
| **OrangeLine** | GPU inference runtime (TIMRUN) on compute you provision |
| **Ryvn** | Deploys and updates the gateway in your AWS, GCP, or Azure account |

There are two ways to run it:

- **Full inference system (default):** Ryvn deploys the API Gateway into your cloud. OrangeLine attaches as model routes. This path includes gateway features such as API keys, routing, usage, and context pruning visualization and intelligence.
- **OrangeLine only:** we provision a Docker Hub repository and give you a pull-only username and token; you run the container on your GPUs. No Ryvn and no Subconscious API Gateway. You will not get context pruning visualization and intelligence without our gateway.

A Subconscious FDE leads the work with your technical champion. You grant cloud permissions (account ID or a cross-account role), approve releases, and point coding agents at the endpoint. You do not apply the gateway Helm chart yourself.

## Contents

| Doc | Description |
| --- | --- |
| [getting-started.md](getting-started.md) | Kickoff through rollout: the eight deployment steps |
| [TRUST_MODEL.md](TRUST_MODEL.md) | Security packet: data boundary, updates, telemetry, support access |
| [FAQ.md](FAQ.md) | Common questions, plus SSO and coding-agent pointers |
| [gpu-deployment/README.md](gpu-deployment/README.md) | OrangeLine Docker Hub pull and AWS/GCP worker routing Terraform |
| [coding-agents/](coding-agents/) | Point Cursor, Claude Code, Codex, Copilot, OpenCode, and Pi at the gateway with `subc` |
| [supported-agent-apis.md](supported-agent-apis.md) | OpenAI / Anthropic / Codex / Claude Code API contract |
| [api-gateway/cost-estimates.md](api-gateway/cost-estimates.md) | Gateway-only AWS, GCP, and Azure planning estimates |
| [api-gateway/sso-okta.md](api-gateway/sso-okta.md) | Dashboard OIDC SSO with Okta |
| [api-gateway/sso-entra.md](api-gateway/sso-entra.md) | Dashboard OIDC SSO with Microsoft Entra ID |

Before setup, review [TRUST_MODEL.md](TRUST_MODEL.md) with your security team, then follow [getting-started.md](getting-started.md) with your FDE.
