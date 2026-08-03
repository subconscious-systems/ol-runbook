# GCP API Gateway cost estimate

> **Planning estimate only — verify live pricing before approval.** Prices,
> regional availability, discounts, support tiers, quotas, and Datadog contracts
> change. Rebuild this estimate in the
> [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator)
> with the actual project inputs and obtain a Datadog quote before committing.

Use approximately **$1,000 per month per always-on environment**, or
**$2,000 per month for separate production-parity sandbox and production**, as
an initial budget. This is not a quote.

Estimate checked August 3, 2026 for `us-east1`. It excludes GPUs, inference
workers, AWS migration, Distr subscription, support plans, taxes, negotiated
discounts, and material traffic/log volume.

## Per-environment assumptions

- 730 hours/month, USD, on-demand/list pricing, no free-tier credit or
  commitment discount.
- One regional GKE Standard cluster.
- Two `n4a-standard-4` ARM64 nodes (4 vCPU/16 GiB each), min/desired 2.
- Two 100 GiB balanced node boot disks.
- Cloud SQL PostgreSQL 16 Enterprise, 2 vCPU/7.5 GiB, regional HA, 50 GiB SSD,
  backups/PITR.
- Memorystore Redis 7 Standard HA, 5 GiB, AUTH/TLS.
- One `e2-standard-2` private bootstrap VM with 40 GiB balanced disk.
- One Cloud NAT for the platform VPC and one for the isolated bootstrap VPC;
  low data processing.
- One global external GCE Application Load Balancer/static IP and managed
  certificate; low traffic.
- Low Cloud DNS, Secret Manager, and GCS state operations.
- Datadog annual-list assumptions: two Infrastructure Pro hosts, two APM hosts,
  and one Database Monitoring host.

## Illustrative monthly breakdown

| Resource | Estimate | Planning basis |
| --- | ---: | --- |
| GKE cluster management | $73 | $0.10/cluster-hour |
| Two N4A nodes | $225 | 2 × about $112.42/month (`$0.154/hour`) |
| GKE node disks | $20 | 200 GiB `pd-balanced` at about $0.10/GiB-month |
| Cloud SQL PostgreSQL HA | $220 | Approximate HA compute + 50 GiB SSD + baseline backup/PITR; must be calculator-verified |
| Memorystore Redis Standard HA | $197 | 5 GiB × about $0.054/GiB-hour × 730 |
| Bootstrap VM | $49 | `e2-standard-2` at about $0.067/hour |
| Bootstrap disk | $4 | 40 GiB `pd-balanced` |
| Two Cloud NAT gateways | $15 | Small VM count, NAT IP hours, and about 50 GiB processed |
| External HTTPS load balancer | $20 | Forwarding/load-balancer base plus low data processing |
| DNS, Secret Manager, GCS state | $3 | Low-volume placeholder |
| Logging/Monitoring variable usage | $10 | Small placeholder; exclusions/retention can dominate |
| Datadog Infrastructure Pro | $30 | 2 hosts × $15 annual list |
| Datadog APM | $62 | 2 hosts × $31 annual list |
| Datadog Database Monitoring | $70 | 1 database host × $70 annual list |
| **Illustrative total** | **$998** | Round to **$1,000/environment/month** |

The two-project production-parity baseline is therefore approximately
**$1,996/month** before usage-variable charges. Keep sandbox parity during
qualification/upgrade rehearsals. Any plan to reduce sandbox capacity changes
the tested topology and must be documented.

## Important pricing risks

### N4A availability and commitments

`n4a-standard-4` is ARM64/Google Axion and was approximately $0.154/hour in
`us-east1` at the check date. Capacity is not guaranteed merely because the
SKU is priced. Verify two-zone capacity and quota. Do not budget Spot for the
production baseline.

Committed-use discounts can reduce compute cost but introduce term/usage risk.
Apply them only after measured steady-state demand.

### GKE support tier

Standard GKE cluster management is approximately $0.10/hour. Extended support
can add approximately $0.50/hour (total around $0.60/hour), increasing one
cluster by roughly **$365/month**. Confirm the selected version/release channel
and support dates during every upgrade.

### Cloud SQL

Cloud SQL is the least reliable hand estimate because price varies by edition,
vCPU/memory, HA, storage/IO, backup retention, PITR logs, and egress. Model
exactly:

- PostgreSQL 16, Enterprise;
- `us-east1`;
- 2 vCPU/7.5 GiB;
- regional HA;
- 50 GiB SSD and auto-growth;
- expected backup/PITR retention;
- maintenance, egress, and any read replica.

Storage growth cannot be reversed in place and raises the monthly baseline.

### Redis

The estimate uses the 5–10 GiB Standard capacity band at approximately
$0.054/GiB-hour. Confirm that Standard HA, Redis 7, AUTH, and TLS are selected.
A blue/green AUTH rotation temporarily doubles Redis cost.

### Networking

Cloud NAT charges include gateway hours based on attached VM count, NAT IP
hours, and per-GiB processing. Internet egress is additional. Load balancing
adds forwarding/load-balancer and data-processing charges; attached forwarding
rule static IPs may not have a separate hourly IP charge, while an unused
reserved IP does.

Long responses, cross-region providers, log export, and container pulls can
make network costs materially higher than this low-traffic placeholder.

### Datadog

The estimate uses public annual list prices only. It excludes:

- log ingestion/indexing/retention;
- APM indexed-span or ingestion overages;
- custom metrics;
- synthetics, RUM, security products, LLM Observability usage, and support;
- negotiated minimums/discounts and high-watermark billing effects.

Confirm whether Cloud SQL DBM is billed as one database host and whether the
GCP integration changes the customer's contract.

## Excluded costs

- GPU instances, model workers, worker networking, or model storage.
- AWS exports/imports, data transfer, or migration tooling.
- Distr licensing/subscription.
- Corporate parent DNS zone, centralized logging/SIEM, backup archive, KMS/CMEK
  operations, organization security tooling, and Premium Support.
- Quota reservations, additional surge nodes during GKE upgrades, blue/green
  Cloud SQL/Redis rotations, disaster-recovery replicas, and retained teardown
  resources.
- Taxes and private pricing.

## Live verification checklist

Before finance/change approval:

1. Export the exact Terraform plan inputs and node/data-service counts.
2. Build one saved calculator estimate per project in `us-east1`.
3. Verify live
   [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing),
   [Compute pricing](https://cloud.google.com/compute/vm-instance-pricing),
   [Cloud SQL pricing](https://cloud.google.com/sql/pricing),
   [Memorystore pricing](https://cloud.google.com/memorystore/docs/redis/pricing),
   [Cloud NAT pricing](https://cloud.google.com/nat/pricing), and
   [load-balancer pricing](https://cloud.google.com/load-balancing/pricing).
4. Confirm GKE version support/extended-support dates.
5. Add expected request egress, NAT processing, logs, traces, backups, and
   upgrade/rotation overlap.
6. Verify current [Datadog list pricing](https://www.datadoghq.com/pricing/list/)
   against the customer's contract.
7. Record calculator URLs/date, approver, currency/tax assumptions, and at least
   a 20% usage contingency.
