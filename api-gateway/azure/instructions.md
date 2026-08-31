# Azure API Gateway setup instructions

End-to-end Assisted Self-Managed setup on Azure. One person can play both **FDE** (Subconscious Forward Deployed Engineer) and **Admin** (customer initial admin) during a demo.

Architecture: [README.md](README.md). Example infra env: [sample-gateway-infra.env](sample-gateway-infra.env). Bootstrap implementation: [bootstrap/](bootstrap/). SSO after install: [Entra](../sso-entra.md) or [Okta](../sso-okta.md).

The Azure path is the easiest current gateway setup: one command, four normal prompts, two startup gates, and Distr owns both the Docker agent and Kubernetes agent wiring.

## Checklist

### 1. FDE: Vendor portal entitlements

Work in the Distr **Vendor** portal for the customer org.

- [ ] Customer organization exists under **Licenses**
- [ ] Application entitlements: Azure api-gateway-infra Docker application + api-gateway Helm application
- [ ] Artifact entitlements: infra runner image, gateway chart, gateway images, and any tool images the chart pulls
- [ ] Published tags exist in `registry.distr.sh` for the versions the customer will pull
- [ ] Customer can sign in to Distr and create a PAT
- [ ] FDE gives the admin the Azure infra application id as `API_GATEWAY_INFRA_AZURE_APPLICATION_ID`

Deployment targets are created by automation. The admin should not need to create or paste agent commands in Hub.

### 2. Admin: Azure and DNS prep

- [ ] Sign in to Azure CLI on the target subscription:

  ```bash
  az login
  az account set --subscription <subscription-id-or-name>
  ```

- [ ] Confirm the gateway hostname is under an existing Azure public DNS zone, for example `api.example.com` under `example.com`.
- [ ] Confirm the setup identity can create a resource group and assign roles. Owner is simplest for day-0; Contributor plus User Access Administrator is also viable.
- [ ] Create a Distr PAT from the customer org.

### 3. Admin: Clone the runbook

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook
```

### 4. Admin: Run the one-command Azure setup

```bash
cd api-gateway/azure/bootstrap
API_GATEWAY_INFRA_AZURE_APPLICATION_ID=<vendor-provided-id> ./scripts/setup-azure.sh
```

When an FDE runs setup with a vendor PAT on behalf of a customer organization,
scope every Distr object created by the command with that organization's ID:

```bash
DISTR_CUSTOMER_ORG_ID=<customer-organization-id> \
  API_GATEWAY_INFRA_AZURE_APPLICATION_ID=<vendor-provided-id> \
  ./scripts/setup-azure.sh
```

Customer admins using their own customer PAT do not need this variable.

Normal prompts:

| Prompt | Example | Notes |
| --- | --- | --- |
| Deployment slug | `acme-prod` | Used for Azure names and the Distr deployment names |
| Gateway hostname | `api.example.com` | Must be in an Azure DNS zone the subscription can manage |
| Provider DNS suffix allowlist | `.example.com,customer.internal` | Gateway route allowlist |
| Distr PAT | masked | Stored as a Distr Hub Secret |

Optional flags:

```bash
./scripts/setup-azure.sh \
  --location eastus2 \
  --dns-zone /subscriptions/.../resourceGroups/dns-rg/providers/Microsoft.Network/dnsZones/example.com \
  --vnet-cidr 10.72.0.0/16 \
  --yes
```

Use `--dry-run` to render the local plan and verify Distr request shapes without changing Azure or Distr.

### 5. What setup creates automatically

The setup script performs two visible startup gates:

1. Azure identity: validates the active subscription and tenant.
2. Distr access: validates the infra and gateway application entitlements.

After that, the script:

- Resolves the Azure DNS zone for the hostname.
- Picks a non-overlapping private VNet CIDR unless `--vnet-cidr` is provided.
- Deploys the bootstrap foundation with Bicep.
- Creates a private bootstrap VM with a managed identity and no public IP.
- Creates the Terraform state storage account/container.
- Creates scoped Distr Hub Secrets for the PAT and initial dashboard password.
- Creates or reuses the Distr Docker target and infra Docker deployment.
- Installs the Docker agent on the VM through Azure protected CustomScript settings.
- Lets the infra runner create AKS, data services, Key Vault, Gateway API routing, the Distr Kubernetes target, and the gateway Helm deployment.

### 6. Admin: Wait for readiness

By default, `setup-azure.sh` waits for the infra deployment to become healthy in Distr. The runner’s health check includes:

- Azure Terraform apply completed
- AKS private control plane reachable from the runner
- External Secrets Operator and cert-manager ready
- Key Vault app secret present and synced
- Distr Kubernetes target connected
- Gateway Helm deployment completed
- `https://<gateway-hostname>/healthz` and `/readyz` pass

If you used `--no-wait`, watch the api-gateway-infra deployment in Distr until it reports healthy.

### 7. Admin: Dashboard login and invite

- [ ] Open `https://<gateway-hostname>/dashboard`
- [ ] Log in as `admin`
- [ ] Use the bootstrap password stored in the generated support file and mirrored in the Hub Secret shown at the end of setup
- [ ] Invite the FDE or other operators
- [ ] Optional day-2: enable Entra or Okta SSO before inviting broader users

### 8. Admin/FDE: Add worker capacity and test chat

The gateway can be deployed before customer GPUs are ready. For an end-to-end smoke test:

- [ ] Add a temporary Subconscious-hosted worker/provider key, or connect the customer GPU worker once available.
- [ ] Run a dashboard chat test.
- [ ] Confirm usage and routing look sane before wider onboarding.

## Recovery paths

Re-running the same command with the same deployment slug is intended to be safe:

- Existing Azure resources are updated in place through Bicep/Terraform.
- Existing connected Distr targets are reused.
- The generated support env file is rewritten from the latest prompt/flag values.

If the Docker target exists but is disconnected, the script stops before rotating its connection credential. Re-run with:

```bash
AZURE_DISTR_DOCKER_RECONNECT=true ./scripts/setup-azure.sh
```

If the hostname belongs to multiple matching Azure DNS zones, pass the exact zone id with `--dns-zone`.

## Final success state

Success means:

- Distr infra Docker deployment is healthy.
- Distr gateway Helm deployment is healthy.
- Azure AKS, PostgreSQL, Redis, Key Vault, and Gateway API routing exist in the customer subscription.
- `https://<gateway-hostname>/dashboard` loads.
- `https://<gateway-hostname>/v1/chat/completions` is ready for authenticated clients once a worker/provider is configured.
