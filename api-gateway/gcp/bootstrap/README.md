# GCP project and Docker-agent bootstrap

This directory is the day-0 foundation for the GCP gateway runbook. It creates
only the enabled environment foundations, including required APIs, budget
alerts, a private keyless GCE VM, and the service-scoped roles needed by the
`api-gateway-infra` runner. `enabled_environments` starts with `sandbox`; add
`prod` only after the sandbox rebuild evidence receives explicit approval.

It does **not** create GKE, Cloud SQL, Redis, ingress, application secrets, or
the gateway. Those remain the responsibility of the versioned Distr
`api-gateway-infra` and `api-gateway` Applications.

> Release gate: the currently published/private implementation may still have
> `CLOUD=gcp` runner stages stubbed. Do not run a customer deployment until the
> selected infra Application release notes explicitly say that the complete GCP
> path is enabled and the release passed the sandbox dress rehearsal in
> [../instructions.md](../instructions.md).

## Security properties

- Separate sandbox and production projects and Terraform state buckets.
- Region locked to `us-east1`.
- Bootstrap VMs have **no public IP**.
- Outbound package, registry, Distr, and Google API access uses Cloud NAT.
- Interactive and scripted access uses IAP TCP forwarding and OS Login.
- VMs use attached service accounts with the `cloud-platform` OAuth scope;
  IAM roles provide authorization.
- Terraform creates no service-account key, SSH metadata key, password, PAT,
  Datadog key, database credential, or Redis AUTH string.
- GCS state buckets use uniform access, public-access prevention, and
  versioning.
- Project deletion and VM deletion protection are enabled by default.

The global [repository `.gitignore`](../../../.gitignore) excludes Terraform
state, tfvars, plans, generated backend files, kubeconfigs, and common cloud
credential files.

## Local prerequisites

- Terraform 1.11.4 or newer.
- `gcloud` and `gke-gcloud-auth-plugin`.
- A human Google identity; do not download a service-account JSON key.
- Rights to create projects below the selected organization/folder, attach the
  billing account, enable APIs, and set project IAM.

Typical day-0 rights for the human bootstrap identity are:

- `roles/resourcemanager.projectCreator` on the target folder or organization;
- `roles/billing.user` on the billing account;
- `roles/billing.costsManager` on the billing account for budget alerts;
- `roles/serviceusage.serviceUsageAdmin` and
  `roles/resourcemanager.projectIamAdmin` on the newly created projects (an
  organization bootstrap role may grant the equivalent permissions);
- `roles/serviceusage.serviceUsageAdmin` and
  `roles/serviceusage.serviceUsageConsumer` on `quota_project_id`, when used.

These are rights for the **human foundation apply**, not the long-lived VM.
Remove temporary parent-level grants after each approved project foundation
passes preflight.

### Install and configure gcloud

macOS (Homebrew) or Debian/Ubuntu:

```bash
cd api-gateway/gcp/bootstrap
bash scripts/install-gcloud.sh
bash scripts/setup-gcloud.sh --quota-project <EXISTING_ADMIN_PROJECT>
```

The setup performs user login and Application Default Credentials (ADC) login.
ADC is stored in the normal user config directory, never in this repository.
When a quota project is provided, the setup also enables the Billing Budgets,
Cloud Billing, Cloud Resource Manager, IAM, and Service Usage APIs required by
the foundation provider calls.
For other Linux distributions, follow the official
[Google Cloud CLI install guide](https://cloud.google.com/sdk/docs/install),
then run `setup-gcloud.sh`.

Install Terraform separately:

```bash
# macOS
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Linux: use HashiCorp's signed package repository
# https://developer.hashicorp.com/terraform/install
```

## First apply and state migration

The state bucket cannot be the backend until it exists, so the first apply is
intentionally local.

```bash
cd api-gateway/gcp/bootstrap
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# Static validation and plan only:
bash scripts/bootstrap.sh --plan

# Review the plan, budget, and IDs, then explicitly create sandbox only:
bash scripts/bootstrap.sh --apply

# Move the local state into the versioned production GCS bucket:
bash scripts/migrate-state.sh

# A post-migration plan must be empty:
terraform plan
```

`migrate-state.sh` writes ignored `backend.tf` and `.backend.hcl` files and runs
`terraform init -migrate-state`. Do not delete the local state/backup until
`terraform state list` and a no-change plan succeed against GCS. Keep a secured
offline copy of the state during the migration change.

The sandbox bucket is used for this staged foundation stack.
The Distr runner uses each environment's own bucket and a deployment-specific
prefix for platform state; sandbox and production platform states never share
a key.

Do not add production during the sandbox rehearsal. After the sandbox platform
has been destroyed and rebuilt, its evidence has been reviewed, and production
creation is explicitly approved, change:

```hcl
enabled_environments = ["sandbox", "prod"]
```

Run `bootstrap.sh --plan`, review the production project/VM/budget additions,
and only then run `bootstrap.sh --apply`. Existing sandbox resources must be
unchanged.

## APIs enabled in each project

The Terraform stack enables the APIs needed for:

- Compute Engine, VPC, IAP, OS Login, Cloud NAT, and load balancing;
- GKE and Artifact Registry;
- Cloud SQL, Service Networking, and Memorystore for Redis;
- Secret Manager, IAM Credentials, STS, and Workload Identity Federation;
- Cloud DNS and Certificate Manager/managed certificate dependencies;
- Cloud Logging, Monitoring, and Cloud Asset Inventory;
- Cloud Storage and Service Usage.

Verify the result and the keyless posture:

```bash
bash scripts/preflight.sh sandbox
# After production is explicitly enabled and applied:
# bash scripts/preflight.sh prod
```

Preflight fails if an API is missing, billing is disabled, the VM has a public
IP, OS Login is off, a user-managed key exists on the VM service account, NAT
is missing, or host setup did not finish.

## Long-lived VM service-account roles

The attached `gateway-{environment}-platform` account receives no Owner or
Editor role. Terraform grants service-specific administration for GKE
(`container.admin`), networking/firewalls/load balancing/static IPs, Cloud SQL,
Redis, Secret Manager, DNS, required API lifecycle, and service-account
creation/attachment. It does
not grant Artifact Registry Admin, Logging Admin, Monitoring Admin, or
Certificate Manager Admin. The platform still receives:

- project IAM administration, required to create reviewed WIF/ESO and Datadog
  STS bindings;
- IAM security administration, required for service-account IAM policies;
- object administration plus bucket-read metadata **only on that environment's
  state bucket**.

Project IAM administration is the highest-risk permission in the set. Use IAM
Conditions or a reviewed custom role if your organization can enumerate the
exact released Terraform permissions. Do not replace this set with Owner or
Editor, and do not create a key for the account.

`operator_principals` receive object administration and bucket-read metadata on
each enabled state bucket so an authorized human can migrate/read Terraform state.
They do not receive bucket IAM/policy administration from this stack.

## Day-0 and day-2 scripts

| Script | Purpose |
| --- | --- |
| `install-gcloud.sh` | Install/check local gcloud and GKE auth plugin |
| `setup-gcloud.sh` | Human user + ADC login without service-account keys |
| `bootstrap.sh` | Format, validate, plan, and explicitly apply enabled foundations |
| `migrate-state.sh` | Move first local state into versioned GCS |
| `preflight.sh` | Read-only billing/API/IAM/network/VM security checks |
| `repair-host.sh` | Reapply Docker, Compose, gcloud, auth plugin, and kubectl over IAP |
| `run-agent.sh` | Send a Docker-agent connect URL over IAP stdin |
| `connect-k8s-agent.sh` | Install the K8s agent using the IAM-protected GKE DNS endpoint |
| `connect.sh` | Interactive IAP/OS Login break-glass shell |
| `rotate-app-secret.sh` | GCP Secret Manager CSRF/encryption rotation via the released runner image |
| `smoke-checks.sh` | GKE/data/ESO/ingress/Datadog/public endpoint checks |

All scripts take `sandbox` or `prod`; they resolve project, region, zone, and VM
from Terraform outputs. Connect URLs and optional smoke API keys travel over
stdin and are never written by the scripts.

## Host repair and break-glass

Cloud-init runs host setup once. Reapply the checked-in idempotent setup without
replacing a VM:

```bash
bash scripts/repair-host.sh sandbox
bash scripts/repair-host.sh prod
```

Open a shell and optionally refresh root's kubeconfig:

```bash
bash scripts/connect.sh prod <PROD_INFRA_DEPLOY_NAME>
```

The kubeconfig is built with `gcloud container clusters get-credentials
--dns-endpoint`. The released GKE stack must enable the DNS endpoint, allow
external traffic through that endpoint, grant `container.clusters.connect`, and
disable IP-based control-plane endpoints.

## Bootstrap-only teardown

Do not destroy these foundations while either Distr agent or platform stack is
still running. Follow [../rollback-teardown.md](../rollback-teardown.md) in
reverse dependency order. For an approved final project deletion:

1. Preserve/export required audit evidence and state.
2. Set `protect_bootstrap_vms = false` and apply.
3. Empty or preserve the state buckets according to retention policy.
4. Set `project_deletion_policy = "DELETE"` and apply that policy change.
5. Run the reviewed destroy from the remote backend.

Project deletion is asynchronous and has organization-level consequences.
`terraform destroy` is intentionally blocked by the default protections.
