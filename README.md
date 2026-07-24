# Subconscious Inference System - Customer Runbook

Customer-facing runbook for deploying and operating the **Subconscious Inference System**.

This repository captures onboarding instructions, bootstrap scripts, troubleshooting notes, FAQ, and setup guidance for deploying the API Gateway and Inference Runtime in different variations - for example Assisted vs Fully Self-Managed with Distr, platform-only vs full stack, and with or without GPU workers.

## What you are deploying

You deploy two runtime components into your cloud. You do not deploy the distribution platform itself. **Distr** is the distribution platform you work with to receive software, version updates, and patches - you opt in to revisions for the API Gateway or Inference Runtime.


| Component             | Role                                                                           |
| --------------------- | ------------------------------------------------------------------------------ |
| **API Gateway**       | Agent traffic, authentication, API key management, routing, and usage controls |
| **Inference Runtime** | GPU-backed model execution on your infrastructure                              |


Implementation artifacts (platform Terraform, gateway Helm chart, worker deployments) are delivered through Distr entitlements. This runbook is where deployment variation and day-0 / day-2 procedures live.

## Contents


| Doc                                                                                  | Description                                                            |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| [api-gateway/aws/README.md](api-gateway/aws/README.md)                               | AWS architecture, dual Distr apps, system diagram, prerequisites       |
| [api-gateway/aws/instructions.md](api-gateway/aws/instructions.md)                   | End-to-end FDE + customer admin setup checklist                        |
| [api-gateway/aws/eks-upgrade.md](api-gateway/aws/eks-upgrade.md)                     | Staged EKS 1.31→1.32 operation, health gates, soak, and rollback       |
| [api-gateway/aws/cost-estimate.md](api-gateway/aws/cost-estimate.md)                 | Monthly AWS gateway estimate without GPU workers                       |
| [api-gateway/aws/bootstrap/](api-gateway/aws/bootstrap/)                             | Day-0 Docker agent EC2 bootstrap (canonical)                           |
| [api-gateway/aws/gateway-secrets.md](api-gateway/aws/gateway-secrets.md)             | AWS Secrets Manager + ESO cluster secrets                              |
| [api-gateway/aws/secret-rotation.md](api-gateway/aws/secret-rotation.md)             | Rotate csrf / encryption, RDS/Valkey, org and worker keys              |
| [api-gateway/aws/troubleshooting.md](api-gateway/aws/troubleshooting.md)             | Common hiccups, rollback notes                                         |
| [api-gateway/aws/sample-gateway-infra.env](api-gateway/aws/sample-gateway-infra.env) | Example Assisted Self-Managed AWS infra env                            |
| [gpu-deployment/README.md](gpu-deployment/README.md)                                 | GPU host bootstrap + Distr worker deploy (27B / 8B, NLB exposure)      |
| [TRUST_MODEL.md](TRUST_MODEL.md)                                                     | Security / platform trust model - Distr Assisted vs Fully Self-Managed |
| [FAQ.md](FAQ.md)                                                                     | Naming deployments, namespaces, releases, and related day-0 guidance   |

Before you start setup, **review the [Trust Model](TRUST_MODEL.md)** to confirm your organization's preferred deployment approach:  
- **Assisted Self-Managed (ASM)** (recommended): Distr agents you install handle platform setup and automations with egress-only access, minimizing manual integration but retaining your cloud boundary.
- **Fully Self-Managed (FSM)**: You maintain full control, applying Terraform and Helm yourself with no ongoing vendor agents.

Discuss with your platform and security teams which model fits your requirements and entitlements. Details and diagrams are in [`TRUST_MODEL.md`](TRUST_MODEL.md).

---

Once you confirm your approach, **proceed to the platform runbook for your cloud** to get started with setup instructions.  
For AWS, follow the step-by-step guide in [`api-gateway/aws/README.md`](api-gateway/aws/README.md).
