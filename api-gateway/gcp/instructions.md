# GCP API Gateway setup instructions

This follows the AWS setup sequence: bootstrap one Docker-agent host, create
Hub secrets and the infra deployment, connect the Docker agent, create and
connect the gateway Kubernetes deployment, then trigger a second infra deploy
with gateway auto-deploy enabled.

Architecture: [README.md](README.md). Bootstrap details:
[bootstrap/](bootstrap/). Secrets: [gateway-secrets.md](gateway-secrets.md).
Troubleshooting: [troubleshooting.md](troubleshooting.md).

The Google-specific differences are project creation, user + ADC login, a
private IAP/OS Login host, automatic first-state migration to GCS, shared Cloud
DNS project IAM, and the IAM-protected GKE DNS endpoint.

## Checklist

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

Verify N4A quota and capacity in `us-east1-b` and `us-east1-c` before starting.

### 3. Admin: Clone the runbook

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook
```

### 4. Admin: Bootstrap the Docker agent VM

```bash
cd api-gateway/gcp/bootstrap
./scripts/install-gcloud.sh
./scripts/setup-gcloud.sh
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
./scripts/bootstrap.sh
```

Like the AWS bootstrap, this is one command. It plans, asks for the production
project ID, applies the project and private VM, migrates state to the new
versioned GCS bucket, runs preflight, and repairs Docker/Compose/kubectl on the
host. Re-running it is idempotent. The VM has no public IP; access uses IAP and
OS Login. Authentication uses a human Google identity and Application Default
Credentials; it never creates or downloads a service-account key.

### 5. Admin: Distr Hub Secrets

Create the same Hub Secrets used by the AWS install:

| Hub secret key | Notes |
| --- | --- |
| `DISTR_TOKEN` | Customer PAT |
| `DD_API_KEY` | Required when Datadog is enabled |
| `DD_APP_KEY` | Required when Datadog is enabled |
| `GATEWAY_DASHBOARD_BOOTSTRAP_PASSWORD` | Optional initial admin; 12+ characters |
| `GCP_GATEWAY_DASHBOARD_OIDC_CLIENT_SECRET` | Optional when OIDC is enabled |

Do not add Google access keys or a service-account JSON file to Hub.

### 6. Admin: api-gateway-infra Docker deployment

- Create the `api-gateway-infra` Docker deployment in Hub.
- Paste [sample-gateway-infra.env](sample-gateway-infra.env), adapting names,
  project, DNS, CIDR, routes, and optional Datadog/dashboard settings.
- Keep `GATEWAY_AUTO_DEPLOY=false` for the first deployment.
- Keep `DISTR_DRY_RUN=0` for the normal installation.
- Copy the Docker target connect URL.

### 7. Admin: Connect the Distr Docker agent

```bash
cd api-gateway/gcp/bootstrap
./scripts/run-agent.sh \
  'https://app.distr.sh/api/v1/connect?targetId=…&targetSecret=…'
```

Trigger the first infra deployment. As on AWS, the runner creates the complete
cloud platform with gateway auto-deploy disabled. Internally, the GCP runner
creates the cloud foundation first so it can reach the new GKE DNS endpoint,
then completes the normal un-targeted reconciliation in the same deployment.

Do not continue until the Docker target is healthy and GKE exists.

### 8. Admin: Create the api-gateway Helm deployment

- Create the `api-gateway` Helm deployment in Hub.
- Deployment and target name = `GATEWAY_DISTR_DEPLOYMENT_NAME`.
- Namespace and Helm release = that same name.
- Leave Helm values empty; the infra runner generates them.
- Deploy and copy the Hub `kubectl apply -n … -f "https://…"` command.

### 9. Admin: Connect the Distr Kubernetes agent

```bash
cd api-gateway/gcp/bootstrap
./scripts/connect-k8s-agent.sh \
  <INFRA_DEPLOY_NAME> \
  'kubectl apply -n <GATEWAY_DISTR_DEPLOYMENT_NAME> -f "https://app.distr.sh/api/v1/connect?…"'
```

The script runs kubectl on the private bootstrap VM through IAP and uses only
the GKE DNS endpoint. Agent pods run in GKE, not on the VM.

### 10. Admin: Second infra deploy (gateway auto-deploy)

- Set `GATEWAY_AUTO_DEPLOY=true`.
- Select `GATEWAY_CHART_VERSION=latest`, `nochange`, or an approved version
  name using the same rules as AWS.
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
