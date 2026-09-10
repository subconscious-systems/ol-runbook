# Deployment trust model

Security review packet for the customer-hosted Subconscious Inference System: the API Gateway (cache-aware router and admin dashboard) and **OrangeLine** (the inference runtime). Customers deploying OrangeLine alone follow a simpler procedure, noted at the end of [getting-started.md](getting-started.md).

Canonical public packet: [Compliance](https://docs.subconscious.dev/on-prem/trust-center/compliance). Ryvn trust center: [trust.ryvn.ai](https://trust.ryvn.ai).

Prepared for security, compliance, platform, and engineering teams.

## Customer-hosted architecture

Subconscious deploys into infrastructure you own. Every production component runs inside a VPC you control, on the hyperscaler you already use. Your VPC standards define the security and compliance boundary.

The product has two components.

**API Gateway.** The entry point for agent traffic. Includes the cache-aware router, the admin dashboard, authentication, API key management, and usage controls.

**OrangeLine.** The GPU-backed execution layer, deployed as a Docker image on GPU compute you provision.

The gateway and admin dashboard are delivered through [Ryvn](https://docs.subconscious.dev/on-prem/ryvn/overview), a deployment platform built for customer-cloud software. A small [Ryvn Agent](https://ryvn.ai/docs/guides/ryvn-agent) runs in your cluster and pulls approved releases over outbound HTTPS. It accepts no inbound connections. OrangeLine ships as a Docker image and runs on GPU compute you provision, whether on-premises, in a hyperscaler, or in a NeoCloud. See [How Ryvn works](https://ryvn.ai/docs/how-ryvn-works) and [getting-started.md](getting-started.md).

Subconscious never accesses customer data. The only information that leaves your environment is opt-in operational telemetry ([Telemetry](#telemetry)).

## Data flow

No customer data leaves your cloud environment. Prompts, completions, inference requests and responses, API keys, user records, and application logs remain inside your VPC at all times.

Three flows cross the boundary, all outbound-initiated.

**Releases.** The Ryvn Agent pulls signed gateway releases from the Subconscious release channel, automatically or after your approval. The OrangeLine image is pulled from the Docker Hub repository we provision for your org, on your schedule.

**Deployment status.** The agent reports heartbeat and task status to the Ryvn control plane so deployments can be tracked. This is operational metadata only.

**Telemetry, opt-in.** Operational metrics and logs, if you enable them. Never customer or user data.

## Shared responsibility

Subconscious delivers stable, scalable, rigorously tested software. You provide the infrastructure it runs on and keep that infrastructure available.

Tell us which framework governs your review and we will provide a control-by-control mapping.

| Area | Subconscious | Customer |
| --- | --- | --- |
| Software quality | Delivers stable, scalable, rigorously tested software for the gateway, admin dashboard, and OrangeLine. | Validates releases against internal requirements before rollout. |
| Vulnerability management | Scans every release for vulnerabilities and malware. Remediates severe vulnerabilities within customer-agreed SLA. | Scans the deployed environment under its own security program. Applies patched releases. |
| Data | Never accesses customer data. Receives opt-in operational telemetry only. | Owns all prompts, completions, keys, user records, and application data, including storage, backup, and retention. |
| Monitoring | Monitors system health through opt-in telemetry when enabled. | Monitors the deployed environment. Owns alerting and incident response when telemetry is not opted-in. |
| Infrastructure | Provides provisioning packaging, sizing guidance, and deployment support. | Provisions and operates the cloud account, cluster, and GPU compute. Keeps the account in good standing, including billing and quotas. |

## Software supply-chain controls

Subconscious software runs in your environment, so the relevant risk category is software supply chain.

- A software bill of materials accompanies every release.
- Vulnerability and malware scans run against the SBOM on every deploy.
- Severe vulnerabilities are remediated within customer-agreed SLA.
- Release artifacts are signed and scanned before publication to your release channel.
- Material security issues trigger direct customer notification and a published advisory with the remediation path.
- You may scan release artifacts and deployed components with your own tooling before approving deployment.

You remain responsible for scanning and monitoring the deployed environment under your own security program. Subconscious assists with interpretation, remediation planning, and patch coordination.

## Release and update process

All Subconscious software is version controlled. Every release passes through a defined procedure that verifies compliance and confirms the build has no critical vulnerabilities. Before a release reaches any customer environment, Subconscious deploys and tests it on its own infrastructure. Only then is it published to the release channel your environment subscribes to.

### Update modes

For the gateway and admin dashboard, you select how releases enter your environment. The setting is enforced by Ryvn at the environment level. OrangeLine updates are new Docker images, pulled and deployed on your own schedule.

**Automatic.** Your environment subscribes to the release channel and deploys new releases as they are published, within any maintenance window you set.

**On approval.** Each release generates a preview showing the exact manifest diff that will be applied. A reviewer on your team approves it from the Ryvn dashboard, with an optional reason recorded in the audit trail. Nothing changes until approval.

In both modes you can review release notes before deployment, schedule maintenance windows, and roll back to a prior version. When approval is required, rollbacks and force deploys generate their own previews and wait for approval too. Subconscious cannot push a change into your environment outside the policy you select.

See [deployment approvals](https://ryvn.ai/docs/guides/deployment-approvals), [maintenance windows](https://ryvn.ai/docs/configure/maintenance-windows), and [release channels](https://ryvn.ai/docs/configure/release-channels).

## Support access

Subconscious provides 24/7 support through a dedicated member of our team.

Subconscious requires no persistent access to your cloud environment. When access is needed to resolve an issue, you grant it under your own policy: approved by you, scoped to the task, logged by you, time-bound, and revoked on completion.

Typical access models include live screen-share sessions you drive, temporary credentials you issue, break-glass access for urgent issues, and diagnostics you export from your own tooling. When telemetry is enabled, most issues can be diagnosed from metrics and logs without any access grant.

Any material shared during support is initiated by you, limited to the issue under investigation, and redacted where appropriate.

## Telemetry

Telemetry is the set of operational signals Subconscious can observe about the running software. It exists so our team can confirm the system is healthy, catch degradation before you notice it, and resolve support requests without asking for access.

Telemetry is off unless you turn it on. Subconscious recommends enabling it.

### What is collected

| Category | What is collected |
| --- | --- |
| Queue and load | Request queue depth, in-flight request counts, and throughput per runtime replica. |
| Latency | Time-to-first-token and end-to-end request timing, as aggregated distributions. |
| Health | Liveness and readiness events, restarts, GPU memory pressure, and cache hit rates from the router. |
| Errors | Error codes, counts, and stack traces from the gateway and runtime. |
| Version | Running version of each component, so support can match behavior to a known release. |

### What is never collected

Telemetry never includes prompts, completions, source code, API keys, secrets, user identities, request bodies, or any other customer or user data. Metrics are aggregated counts and timings. Logs are limited to gateway and runtime events.

### How it leaves your environment

Telemetry is collected inside your environment and forwarded over outbound HTTPS. No inbound connection is opened.

### Your controls

- Enable or disable metric collection and log collection independently.
- Turn telemetry off at any time through your deployment settings, with no involvement from Subconscious.

## How the Ryvn Agent works

A single Kubernetes operator, the [Ryvn Agent](https://ryvn.ai/docs/guides/ryvn-agent), runs in your cluster. It establishes outbound HTTPS connections to the Ryvn control plane and polls for pending tasks. It never accepts inbound connections, so no ingress rules, port forwarding, or public endpoints are required.

The agent runs unprivileged: non-root, read-only root filesystem, all Linux capabilities dropped. It holds no persistent state. Communication uses mutual TLS with scoped, auto-refreshing tokens. Secrets are encrypted per environment before transmission and decrypted in memory only. Every task the agent runs is recorded in an audit trail visible to your team.

Ryvn is not required on every GPU host. An OrangeLine worker on a NeoCloud, local cluster, or other provider is a worker the gateway calls, not a second Ryvn environment.

## FAQ

### Does Subconscious process or store our data?

No. Inference requests, prompts, completions, logs, keys, and operational data remain in your environment. Nothing is shared unless you choose to share specific material during support.

### Does Subconscious or Ryvn require access to our cloud account?

No inbound access is required by either. The Ryvn Agent connects outbound only and holds Kubernetes permissions within your cluster. Any support access from Subconscious is approved by you, scoped, logged, time-bound, and revoked after use.

### Who controls updates?

You do. Subconscious publishes releases to your release channel. You either enable automatic deployment or review each release preview and approve it. Approval is enforced at the environment level and cannot be bypassed by a force deploy or rollback.

### Is telemetry enabled by default?

No. Telemetry is opt-in. It carries operational metrics and logs only, never customer or user data. [Telemetry](#telemetry) lists exactly what is collected and how to control it.
