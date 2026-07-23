# AWS API Gateway cost estimate

This estimate covers the Subconscious Inference System **API Gateway only**.
GPU instances, inference workers, and private worker NLBs are excluded.

Use **approximately $680 per month** as the planning baseline for a gateway
running a standard-support EKS version with Datadog Infrastructure Pro and APM.
The AWS-only portion is approximately **$588 per month**.

## Assumptions

- Prices checked July 23, 2026.
- AWS Region: US East (Ohio), `us-east-2`.
- 730 runtime hours per month.
- On-Demand pricing with no free-tier, Spot, Reserved Instance, Savings Plan,
  private-pricing, tax, or AWS Support adjustments.
- Two `m7g.xlarge` EKS nodes.
- An EKS Kubernetes version in standard support.
- Multi-AZ `db.t4g.medium` RDS for PostgreSQL with 50 GB gp3 storage.
- Two `cache.t4g.small` ElastiCache for Valkey nodes.
- One always-on `t3.large` bootstrap/Distr agent host.
- One NAT Gateway and one public ALB spanning two Availability Zones.
- Datadog annual-list pricing for two EKS hosts: Infrastructure Pro and APM.
- Low traffic: one average ALB LCU per hour and negligible Secrets Manager,
  Route 53, and Terraform-state activity.

## Estimated monthly breakdown

| Resource | Monthly estimate | Basis |
| --- | ---: | --- |
| EKS control plane | $73.00 | Standard support at $0.10/hour |
| Two EKS nodes | $238.27 | 2 × `m7g.xlarge` |
| RDS PostgreSQL | $100.65 | Multi-AZ `db.t4g.medium` plus 50 GB gp3 |
| Bootstrap/Distr host | $60.74 | `t3.large` |
| ElastiCache for Valkey | $37.38 | 2 × `cache.t4g.small` |
| NAT Gateway | $32.85 | Hourly charge; processing excluded |
| Public ALB | $22.27 | Hourly charge plus one average LCU/hour |
| Public IPv4 addresses | $14.60 | Bootstrap host, NAT, and two ALB addresses |
| EBS gp3 volumes | $6.40 | Approximately 80 GB |
| Secrets Manager, Route 53, and Terraform state | $1.80 | Low-volume estimate |
| Datadog Infrastructure Pro | $30.00 | 2 hosts × $15/host |
| Datadog APM | $62.00 | 2 hosts × $31/host |
| **Estimated total** | **$679.96** | Before usage-variable charges |

Round the estimate to **$680 per month** for planning.

## EKS version cost warning

EKS charges more when a Kubernetes version enters extended support. EKS 1.31
entered extended support on November 26, 2025:

- Standard-support control plane: $0.10/hour, or about $73/month.
- Extended-support control plane: $0.60/hour, or about $438/month.
- Difference: **$365/month** or **$4,380/year** per cluster.

Using EKS 1.31 raises the estimate from approximately **$680 to $1,045 per
month**, without adding capacity. The current
[`sample-gateway-infra.env`](sample-gateway-infra.env) sets
`KUBERNETES_VERSION=1.31`, so applying it unchanged incurs that premium.
Before deployment, select a compatible EKS version that remains in standard
support and plan regular upgrades. Do not choose a version solely by number;
check its current support dates first.

## Usage-variable and excluded costs

The estimate does not include:

- GPU instances, inference workers, worker NLBs, or worker traffic.
- Distr subscription or entitlement pricing.
- Datadog logs, indexed events, trace overages, negotiated discounts, or an
  existing customer commitment.
- NAT data processing, currently $0.045/GB in `us-east-2`.
- Internet data transfer after AWS's account-level free allowance; the first
  paid tier is typically $0.09/GB.
- ALB capacity above one average LCU/hour.
- Cross-AZ transfer, additional backups or snapshots, unusually high DNS or
  Secrets Manager API volume, taxes, and AWS Support.
- The fixed cost of an existing Route 53 hosted zone.

Useful planning increments:

- Each additional always-on `m7g.xlarge` node: approximately $119/month.
- Each additional sustained ALB LCU: approximately $5.84/month.
- Each additional Datadog host with the same Infrastructure Pro and APM
  assumptions: approximately $46/month.

## Verify before approval

Cloud and observability prices change. Before approving a budget:

1. Confirm the deployment inputs, especially EKS version, node count, Region,
   RDS topology, and Datadog products.
2. Recreate the estimate in the
   [AWS Pricing Calculator](https://calculator.aws/).
3. Check the [Amazon EKS pricing](https://aws.amazon.com/eks/pricing/) and
   [EKS version lifecycle](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).
4. Check current [Datadog list pricing](https://www.datadoghq.com/pricing/list/)
   or the customer's contract.
5. Add expected traffic, log, trace, and support-plan usage.
