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


| Doc | Description |
| --- | --- |
| [gpu-deployment/README.md](gpu-deployment/README.md) | GPU host bootstrap + Distr worker deploy (27B / 7B, NLB exposure) |
| [TRUST_MODEL.md](TRUST_MODEL.md) | Security / platform trust model - Distr Assisted vs Fully Self-Managed, and the two deployment gates for your team |
| [FAQ.md](FAQ.md) | Common questions (naming deployments, namespaces, releases, and related day-0 guidance) |
| [api-gateway/aws/sample-gateway-infra.env](api-gateway/aws/sample-gateway-infra.env) | Example Assisted Self-Managed AWS infra env (paste into the Distr Docker deployment) |
| *Getting started* | Coming soon - end-to-end bootstrap by role |
| *Troubleshooting* | Coming soon - failure modes and recovery notes |


## Where detail lives

Use this repo for customer-facing procedures and decision framing. Product and application repositories remain the source of truth for chart values, Terraform modules, and runtime internals once you are entitled to those artifacts via Distr.