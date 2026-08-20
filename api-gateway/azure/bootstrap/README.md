# Azure bootstrap

This folder contains the customer-facing Azure bootstrap for the API Gateway.

The bootstrap is deliberately small: it creates the private runner VM, managed identity, network, and Terraform state account, then hands the rest of the deployment to Distr and the infra runner.

## Normal use

```bash
cd api-gateway/azure/bootstrap
API_GATEWAY_INFRA_AZURE_APPLICATION_ID=<vendor-provided-id> ./scripts/setup-azure.sh
```

The command asks for deployment slug, gateway hostname, provider DNS suffixes, and Distr PAT.

## Files

| File | Purpose |
| --- | --- |
| `scripts/setup-azure.sh` | One-command guided setup |
| `scripts/lib.sh` | Azure, Distr, DNS, and agent helper functions |
| `main.bicep` | Subscription-scope wrapper that creates the resource group and DNS role assignments |
| `resources.bicep` | Resource-group foundation: VM, identity, VNet/subnet, storage account/container |
| `cloud-init.sh` | Installs Docker and base tools on the private runner VM |
| `scripts/tests/test-static.sh` | Static contract checks for the easy-path flow |

Generated support files are written under `api-gateway/azure/.generated/<deployment-slug>/` and are intentionally ignored by Git.

## Security posture

- The VM has no public IP.
- The network security group denies inbound traffic.
- Docker agent installation uses Azure VM CustomScript protected settings so the Distr connect URL is not placed in normal command output.
- Terraform runs as the VM user-assigned managed identity.
- Azure service credentials are not stored in Distr.
- Application/runtime secrets live in Azure Key Vault and sync into AKS through External Secrets Operator.

## Advanced flags

```bash
./scripts/setup-azure.sh \
  --location eastus2 \
  --dns-zone /subscriptions/.../resourceGroups/dns-rg/providers/Microsoft.Network/dnsZones/example.com \
  --infra-application-id <uuid> \
  --infra-version-id <uuid> \
  --gateway-application-id <uuid> \
  --vnet-cidr 10.72.0.0/16 \
  --yes
```

Use `--no-wait` when another operator will monitor Distr. Use `--dry-run` for local shape checks without changing Azure or Distr.
