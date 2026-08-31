# GCP API Gateway setup instructions

This follows the AWS setup sequence: bootstrap one Docker-agent host, create
Hub secrets and the infra deployment, connect the Docker agent, create and
connect the gateway Kubernetes deployment, then trigger a second infra deploy
with gateway auto-deploy enabled.

Architecture: [README.md](README.md). Bootstrap: [bootstrap/](bootstrap/).
Secrets: [gateway-secrets.md](gateway-secrets.md). Datadog:
[datadog-operations.md](datadog-operations.md). Troubleshooting:
[troubleshooting.md](troubleshooting.md). Rollback:
[rollback.md](rollback.md). Teardown:
[teardown.md](teardown.md).

The Google-specific differences are project creation, user + ADC login, a
private IAP/OS Login host, automatic first-state migration to GCS, shared Cloud
DNS project IAM, and the IAM-protected GKE DNS endpoint.

## Interactive installer (recommended)

After cloning this runbook, start the production installer with one command:

```bash
cd ol-runbook/api-gateway/gcp/bootstrap
./scripts/install.sh
```

The CLI presents ten numbered steps. It runs tool installation, Google login,
Terraform bootstrap, agent connection, and optional smoke checks through the
existing reviewed scripts. Before each prompt it explains where to obtain the
value and whether it is an identifier or a secret. At the required Distr Hub
actions it prints the exact Secret names and fields to set, then pauses for
confirmation. Connect URLs and the Hub Kubernetes command are read with
terminal echo disabled, sent over stdin, and never put in shell history,
process arguments, or files. The CLI reads the applied bootstrap Terraform
outputs and uses one dedicated configuration step to create two ignored,
mode-0600 environments: `.generated/gateway-infra.env` for the first pass and
`.generated/gateway-infra-auto-deploy.env` for the second pass. They contain
Hub Secret references and production values ready to paste into Distr. The
second differs only by enabling gateway auto-deploy. Resolved PATs, passwords,
and API keys never enter either file.

Useful commands:

```bash
./scripts/install.sh --check          # offline local contract check
./scripts/install.sh --list-steps     # preview the workflow
./scripts/install.sh --from-step 5    # resume after completed steps 1-4
```

The CLI deliberately does not call the Distr API or store cloud/application
credentials. The detailed checklist below is the reference behind each prompt.

In the foundation step, the CLI queries resources visible to the authenticated
Google account and presents numbered choices for the organization, open billing
account, optional ADC quota project, existing DNS project, and top-level folder
when a folder parent is selected. Each choice shows the human display name and
exact saved ID. For ADC quota, `c` creates a dedicated control-plane project
under the selected parent and billing account after an explicit confirmation.
Nested folders and resources hidden by customer policy can be entered manually.
The production project ID is typed because it must be new and globally unique.
The CLI validates each answer and generates `bootstrap/terraform.tfvars`; Vim
is not part of the default flow.

## Detailed checklist

### 1. FDE: Vendor portal entitlements

In the Distr Vendor portal, confirm the customer organization can use:

- the `api-gateway-infra` Docker Application and selected GCP runner release;
- the `api-gateway` Helm Application and selected chart release;
- every runner, gateway, router, adapter, migration, and tool image pulled by
  those releases.

The customer must be able to sign in and create a PAT. Deployment targets are
not entitlements.

### 2. Admin: Naming and account prep

Choose names of at most 32 characters:

| What | Name |
| --- | --- |
| Infra Docker deployment / Terraform prefix | `{slug}-api-gateway-infra` |
| Gateway Helm deployment / namespace / release | `{slug}-api-gateway` |
| New production GCP project | globally unique project ID |

Also choose:

- one existing shared Cloud DNS project and managed zone for `DOMAIN_NAME`;
- one canonical, non-overlapping RFC1918 `/16` for the platform;
- one separate canonical RFC1918 `/24` for the bootstrap host;
- organization or folder, billing account, budget, and operator principals.

Keep deployment names at most 32 characters. Greenfield uses the same string
for the Hub Kubernetes target, namespace, and Helm release
(`GATEWAY_DISTR_DEPLOYMENT_NAME`). If the Hub target is later renamed, set
`GATEWAY_DISTR_PORTAL_NAME` to that Hub name and leave the cluster identity
unchanged. See [FAQ.md](../../FAQ.md).

Verify N4A quota and capacity in `us-east1-b` and `us-east1-c` before starting.

### 3. Admin: Clone the runbook

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook
```

### 4. Admin: Bootstrap the Docker agent VM

```bash
cd api-gateway/gcp/bootstrap
./scripts/install.sh
```

The guided foundation step requires exactly one organization/folder parent, an
open billing account, a new project ID and display name, an existing public-DNS
project, a budget alert amount, a non-overlapping private `/24`, and at least
one operator user or Google Group. An ADC quota project is optional and can be
selected, created as a dedicated control-plane project, or skipped when policy
already provides one; region, VM sizing, and deletion protections are fixed to
production-safe values. Organizations are also visible under **IAM & Admin > Manage Resources**,
billing IDs under **Billing > Manage billing accounts**, and projects/DNS zones
under **Manage Resources** and **Network services > Cloud DNS**. The installer
shows the matching accessible resources and allows selection by number.

It then plans, asks for the production project ID, applies the project and
private VM, migrates state to the new versioned GCS bucket, runs preflight, and
repairs Docker/Compose/kubectl on the host. Re-running with
`./scripts/install.sh --from-step 3` offers to reuse a valid completed foundation
file. The VM has no public IP; access uses IAP and OS Login. Authentication uses
a human Google identity and Application Default Credentials; it never creates
or downloads a service-account key.

### 5. Admin: Configure all Distr variables and Hub Secrets

The guided installer performs all customer-specific Distr environment setup in
this one step. It prompts for deployment names, DNS, CIDR, provider suffixes,
gateway version, Datadog, dashboard identity, optional OIDC, and optional
webhook delivery. It then renders both rollout environments from the same
validated inputs. Later steps apply the prepared files; they do not invent new
environment values.

Create the same Hub Secrets used by the AWS install:

| Hub secret key | Notes |
| --- | --- |
| `DISTR_TOKEN` | Required. Customer PAT from the customer Distr account—not a vendor publish token. |
| `DD_API_KEY` | Required only when Datadog is enabled; create in that customer's Datadog organization/site. |
| `DD_APP_KEY` | Required only when Datadog is enabled; use a dedicated application key with the permissions in [datadog-operations.md](datadog-operations.md). |
| `<GW>_GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD` | Required for day-0. Generate 20+ random characters in the customer password manager. `<GW>` is the uppercase/underscore gateway deployment name printed by the CLI. |
| `<GW>_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET` | Required only when OIDC is enabled; copy from the Okta/Entra Web OIDC application. |
| `<GW>_GATEWAY_WEBHOOK_SIGNING_SECRET` | Required only when webhook delivery is enabled; generate a unique 32-byte HMAC secret and set the same value on the approved receiver. |

Paste resolved values only into Hub's masked Secret value fields. The generated
environment contains references to those Secret names. Do not add Google access
keys, ADC, or a service-account JSON file to Hub.

### 6. Admin: api-gateway-infra Docker deployment

- Create the `api-gateway-infra` Docker deployment in Hub.
- Paste `.generated/gateway-infra.env` for the first pass. The installer has
  already prepared `.generated/gateway-infra-auto-deploy.env` for the second
  pass. For a manual install, adapt
  [sample-gateway-infra.env](sample-gateway-infra.env).
- Keep `GATEWAY_AUTO_DEPLOY=false` for the first deployment.
- Keep `DISTR_DRY_RUN=0` for the normal installation.
- Leave `GATEWAY_LOG_LEVEL=WARN` unless request-completion logs are required.
- Leave `DATADOG_APM_ENABLED` and `DATADOG_LLM_OBS_ENABLED` false unless both
  features are intentionally enabled.
- Copy the Docker target connect URL.

Compare the sample with the selected release's own environment template. Every
required field must be recognized by that release; unknown fields or a stub
message are a hard stop.

### 7. Admin: Connect the Distr Docker agent

```bash
cd api-gateway/gcp/bootstrap
./scripts/run-agent.sh
```

Trigger the first infra deployment. As on AWS, the runner creates the complete
cloud platform with gateway auto-deploy disabled. Internally, the GCP runner
creates the cloud foundation first so it can reach the new GKE DNS endpoint,
then completes the normal un-targeted reconciliation in the same deployment.

Do not continue until the Docker target is healthy and GKE exists.

### 8. Admin: Create the api-gateway Helm deployment

- Create the `api-gateway` Helm deployment in Hub.
- Deployment target name = `GATEWAY_DISTR_PORTAL_NAME` when set; otherwise use
  `GATEWAY_DISTR_DEPLOYMENT_NAME`.
- Namespace and Helm release = `GATEWAY_DISTR_DEPLOYMENT_NAME`, even if the Hub
  target is later renamed.
- Leave Helm values empty; the infra runner generates them.
- Deploy and copy the Hub `kubectl apply -n … -f "https://…"` command.

### 9. Admin: Connect the Distr Kubernetes agent

```bash
cd api-gateway/gcp/bootstrap
./scripts/connect-k8s-agent.sh <INFRA_DEPLOY_NAME>
```

Both scripts prompt with terminal echo disabled so the `targetSecret` does not
enter shell history or a process argument. The Kubernetes script runs kubectl
on the private bootstrap VM through IAP and uses only the GKE DNS endpoint.
Agent pods run in GKE, not on the VM.

### 10. Admin: Second infra deploy (gateway auto-deploy)

- Replace the infra deployment Environment with the complete
  `.generated/gateway-infra-auto-deploy.env` prepared in step 5.
- Confirm its only rollout change is `GATEWAY_AUTO_DEPLOY=true` and its
  `GATEWAY_CHART_VERSION` is the version selected in that configuration step.
- Trigger the second `api-gateway-infra` deployment.

The runner reapplies Terraform idempotently, regenerates Helm values, ensures
Secret Manager/ESO application secrets, and updates the gateway deployment.

### 11. Admin: Dashboard login and invite

- Open `https://<DOMAIN_NAME>/dashboard`.
- Sign in with the optional bootstrap administrator or configured OIDC.
- Invite the required users.

### 12. FDE: Cloud-hosted GPU worker key

Obtain an approved provider or cloud-hosted GPU key and configure it in the
gateway so inference can be tested before customer GPU workers are connected.

### 13. Admin: Test chat

- Run a test chat in the dashboard.
- Success verifies the dual-Application gateway path and temporary provider.
- Run the read-only platform smoke checks if deeper verification is needed:

```bash
./scripts/smoke-checks.sh \
  <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME> <DOMAIN_NAME> \
  <CLOUDSQL_INSTANCE> <REDIS_INSTANCE>
```

### 14. Admin: Final secrets verification

Confirm Secret Manager contains the generated `rds`, `valkey`, and `app`
bundles and ESO has synchronized `gateway-secrets`, `router-secrets`, and
`worker-secrets` into `GATEWAY_DISTR_DEPLOYMENT_NAME`.

## User work compared with AWS

The Hub and agent steps are deliberately the same. GCP adds only:

1. Google user and ADC login;
2. project/billing/DNS-parent inputs in `terraform.tfvars`;
3. a private IAP connection instead of AWS SSM;
4. automatic initial state migration to GCS;
5. a GKE DNS endpoint instead of the EKS endpoint path.

Gateway deployment, secrets, version selection, and the two Hub deployment
cycles otherwise follow the AWS procedure.

## Handoff

Record:

- project IDs/numbers, region/zones, CIDRs, DNS zone/hostname/static IP;
- state buckets/prefixes and owners;
- pinned Distr Application versions and image digests;
- GKE version/release channel, node pool, Cloud SQL and Redis names;
- WIF principals, service accounts, and IAM reviewers;
- Datadog integration/account IDs, env tags, dashboards, and monitor state;
- smoke/soak evidence, rotation owners, upgrade window, rollback owners;
- explicit statement that AWS migration and GPU provisioning were not part of
  this deployment.
