# FAQ

Common questions about the Subconscious Inference System. Canonical public FAQ: [on-prem FAQ](https://docs.subconscious.dev/on-prem/faq).

Working docs in this repo: [getting started](getting-started.md) · [trust model](TRUST_MODEL.md) · [OrangeLine](gpu-deployment/README.md) · [coding agents](coding-agents/) · [Okta SSO](api-gateway/sso-okta.md) · [Entra SSO](api-gateway/sso-entra.md).

## Why use this over Claude Code or Codex?

Closed hosted tools can send prompts, code, and engineering context outside your trust boundary. The Subconscious Inference System gives your team frontier-level coding-agent intelligence while keeping API Gateway traffic, OrangeLine execution, and deployment policy inside infrastructure you control.

See [TRUST_MODEL.md](TRUST_MODEL.md) and [compliance](https://docs.subconscious.dev/on-prem/trust-center/compliance).

## Why use Subconscious instead of hosting the models ourselves?

You can rent GPUs and host open models yourself, but serving coding-agent workloads efficiently is the hard part. Subconscious provides the API Gateway, OrangeLine, upgrades, and support. OrangeLine is designed to serve teams of engineers with roughly half the GPUs compared with off-the-shelf runtimes like vLLM.

See [how it works](https://docs.subconscious.dev/on-prem/how-it-works).

## What are the two ways to run it?

**Full inference system:** Ryvn deploys the API Gateway into your AWS, GCP, or Azure account. OrangeLine runs on GPUs anywhere you can run a Docker container and attaches to the gateway. This path includes context pruning visualization and intelligence.

**OrangeLine only:** we issue registry credentials and you run the container on your GPUs. Use this for trials or if you already have a gateway. You will not get context pruning visualization and intelligence without our gateway.

See [methods](https://docs.subconscious.dev/on-prem/deployments/methods) and [getting-started.md](getting-started.md).

## How does this fit into our security review?

For the full system, the API Gateway runs in your AWS, GCP, or Azure account. A customer-installed Ryvn Agent pulls updates over outbound HTTPS. Subconscious does not need inbound access. You approve production changes through Ryvn approvals and your change-management process.

OrangeLine-only is a thinner review: you run our container on your GPUs; we are an image vendor, not the operator of your gateway.

See [TRUST_MODEL.md](TRUST_MODEL.md).

## Where does it run?

The API Gateway runs in your AWS, GCP, or Azure account. OrangeLine GPUs can be in that same account, on a NeoCloud or inference platform, on your own local cluster, or on bare metal. They do not have to match the gateway's cloud.

See [configurations](https://docs.subconscious.dev/on-prem/deployments/configurations).

## What data does Subconscious access?

By default, production prompts, completions, source code, API keys, gateway logs, OrangeLine logs, and operational data stay in your environment. You may choose to share selected diagnostics for support.

See [TRUST_MODEL.md](TRUST_MODEL.md).

## How are upgrades delivered?

Gateway updates go through Ryvn: you review the release, then approvals, maintenance windows, and release channels decide when the agent applies it. OrangeLine on other GPU hosts is a new image tag.

See [Ryvn](https://docs.subconscious.dev/on-prem/ryvn/overview) and [getting-started.md](getting-started.md).

## Can we control when updates are deployed?

Yes. Production gateway updates are customer-approved. Use Ryvn [deployment approvals](https://ryvn.ai/docs/guides/deployment-approvals) and [maintenance windows](https://ryvn.ai/docs/configure/maintenance-windows).

## Do you support vulnerability scanning?

Subconscious can provide release evidence such as scan results, SBOMs, image digests, checksums, and release notes. You can also scan artifacts and running components with your own tools.

See [TRUST_MODEL.md](TRUST_MODEL.md).

## Do we need to bring our own GPUs?

Usually yes, or you use a GPU cloud or platform. We can help you source capacity. OrangeLine runs anywhere you can run a GPU Docker container.

See [gpu-deployment/README.md](gpu-deployment/README.md).

## If a new model comes out, can we deploy it?

Yes, if OrangeLine supports the architecture and you have GPU capacity. You may need more GPUs or to replace an existing route.

See [customer success](https://docs.subconscious.dev/on-prem/integration-journey/customer-success).

## Which coding agents are supported?

The API Gateway exposes OpenAI- and Anthropic-compatible endpoints, so teams can connect Claude Code, Cursor, Codex, OpenCode, Pi, and internal tools that speak those APIs.

See [coding-agents/](coding-agents/), [supported-agent-apis.md](supported-agent-apis.md), and [API Gateway setup](https://docs.subconscious.dev/on-prem/api-gateway/setup).

## How do I enable dashboard SSO?

Dashboard login supports OpenID Connect. Inference APIs still use org API keys. Invite users before first SSO login; there is no open JIT provisioning.

Create the IdP application (Okta or Microsoft Entra ID), then your FDE wires OIDC on the gateway.

- Okta: [api-gateway/sso-okta.md](api-gateway/sso-okta.md)
- Microsoft Entra ID: [api-gateway/sso-entra.md](api-gateway/sso-entra.md)

Password login remains available as break-glass for the bootstrap admin.

## What happens if the deployment has an incident?

You own incident response for the gateway and OrangeLine in your environment. Subconscious supports investigation when you ask, using access or diagnostics you approve.

See [customer success](https://docs.subconscious.dev/on-prem/integration-journey/customer-success).
