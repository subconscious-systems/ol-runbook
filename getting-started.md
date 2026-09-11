# Getting started

Your Subconscious FDE leads this with your technical champion. Public docs own the full story: [onboarding](https://docs.subconscious.dev/on-prem/integration-journey/onboarding) and [compliance](https://docs.subconscious.dev/on-prem/trust-center/compliance). This page is the working sequence from that packet.

The default path is **Ryvn provisions** the gateway environment in your AWS, GCP, or Azure account. An existing-cluster variant (install the Ryvn Agent on a cluster you already operate) is described in [compliance](https://docs.subconscious.dev/on-prem/trust-center/compliance). Do not apply the gateway Helm chart yourself.

OrangeLine-only trials skip Ryvn: complete step 1, then step 6, and point your existing routing layer at the runtime.

## Prerequisites

- An AWS, Google Cloud, or Azure account for the API Gateway and admin dashboard.
- GPU compute from any provider for OrangeLine. Same cloud and region as the gateway is simpler when you have it.
- A person who can grant scoped provisioner permissions (account ID, or the cross-account role commands your FDE shares).
- A public hostname for the dashboard, if you are deploying the full system.
- Outbound HTTPS from the cluster to the Ryvn control plane and to Docker Hub (for OrangeLine image pulls).
- A named approver on your team if you choose on-approval updates.

See [How Ryvn works](https://ryvn.ai/docs/how-ryvn-works), the [Ryvn Agent](https://ryvn.ai/docs/guides/ryvn-agent), and [deployment approvals](https://ryvn.ai/docs/guides/deployment-approvals). Cloud-specific provisioner details: [AWS](https://ryvn.ai/docs/provision/aws), [Google Cloud](https://ryvn.ai/docs/provision/google-cloud), [Azure](https://ryvn.ai/docs/provision/azure).

## 1. Kickoff and security review

Walk [TRUST_MODEL.md](TRUST_MODEL.md) (canonical: [compliance](https://docs.subconscious.dev/on-prem/trust-center/compliance)). Agree on cloud provider, region, where OrangeLine GPUs will run, update mode (automatic vs on approval), and telemetry.

## 2. Create the environment

Subconscious creates a dedicated Ryvn environment and invites your approver. The approver can view the environment, review deployment previews, and approve. They cannot modify services or trigger deployments.

## 3. Provision gateway infrastructure

You grant scoped permissions through the Ryvn dashboard (your account ID, or a short set of commands to create a cross-account role). Ryvn creates a VPC with your chosen CIDR, or uses your existing VPC and private subnets, then provisions a Kubernetes cluster, networking, load balancers, and IAM roles in your account. Provisioning typically completes in 15 to 20 minutes.

AWS, GCP, and Azure follow this same path. The identifier you hand your FDE is the only cloud-specific input.

## 4. Set approval and observability policy

In environment settings, turn the approval requirement on or off to match your update mode, and enable or disable metric and log collection. You can change these later.

Telemetry is opt-in. It never includes prompts, completions, keys, or user data. See [TRUST_MODEL.md](TRUST_MODEL.md). Ryvn shows installation status and logs. Keep the monitoring stack you already run. You do not have to send production inference data to Ryvn. See [Ryvn logs](https://ryvn.ai/docs/observability/logs).

## 5. Deploy the gateway and admin dashboard

Subconscious publishes the release to your environment's release channel. If approval is required, your approver reviews the rendered manifest diff and approves. The [Ryvn Agent](https://ryvn.ai/docs/guides/ryvn-agent) applies the release over outbound HTTPS. Health checks gate traffic until every replica reports ready.

## 6. Deploy OrangeLine

Subconscious provisions a Docker Hub repository for your org and gives your team a pull-only username and access token. Your FDE supplies the repository and tag, plus launch configuration. See [gpu-deployment/README.md](gpu-deployment/README.md) for the `docker login` / `docker pull` snippet.

- **Same cloud and region as the gateway:** launch GPU instances, pull the image, and start the containers. On AWS or GCP, optional Terraform in `gpu-deployment/` publishes HTTPS worker domains so the gateway can reach those GPUs on your private network.
- **Somewhere else:** NeoCloud, inference platform, local cluster, or bare metal. Your FDE works that provider's procedure with you.

Ryvn is not required on every GPU host. Workers attach to the gateway as model routes.

## 7. Configure and validate

Your FDE walks [API Gateway setup](https://docs.subconscious.dev/on-prem/api-gateway/setup) with your admin: dashboard access, model routes to OrangeLine, a test request, and pilot keys. Then point coding agents with [`subc`](coding-agents/). Dashboard SSO (optional): [Okta](api-gateway/sso-okta.md) or [Entra ID](api-gateway/sso-entra.md).

## 8. Roll out

Release the endpoint to engineering users. Gateway updates arrive through the release channel under the mode you selected. OrangeLine updates are new Docker image tags you pull on your schedule.

Day two (upgrades, monitoring, support) is in [customer success](https://docs.subconscious.dev/on-prem/integration-journey/customer-success) and [configurations](https://docs.subconscious.dev/on-prem/deployments/configurations). Approve gateway releases in Ryvn. Ask your FDE about SSO, GPU attach, or teardown.
