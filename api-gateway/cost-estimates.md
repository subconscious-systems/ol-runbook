# API Gateway cost estimates

Planning estimates for the **API Gateway only** when Ryvn provisions the environment in your cloud. GPU instances, OrangeLine workers, and worker load balancers are excluded.

These are not quotes. Prices, regions, discounts, and support tiers change. Rebuild in the cloud calculator with your actual inputs before finance approval.


| Cloud             | Planning baseline                         | Checked          |
| ----------------- | ----------------------------------------- | ---------------- |
| AWS (`us-east-2`) | about **$680/month**                      | July–August 2026 |
| GCP (`us-east1`)  | about **$780/month**                      | August 2026      |
| Azure             | no published numbered estimate; see below | n/a              |


## AWS

Assumptions: 730 hours/month, on-demand list, US East (Ohio), two `m7g.xlarge` EKS nodes, Kubernetes 1.35 in standard support, Multi-AZ `db.m7g.large` RDS PostgreSQL with 50 GB gp3, two `cache.t4g.small` ElastiCache for Valkey nodes, one NAT Gateway, one public ALB.


| Resource                                           | Monthly estimate |
| -------------------------------------------------- | ---------------- |
| EKS control plane                                  | $73              |
| Two EKS nodes                                      | $238             |
| RDS PostgreSQL                                     | $249             |
| ElastiCache for Valkey                             | $37              |
| NAT Gateway                                        | $33              |
| Public ALB                                         | $22              |
| Public IPv4, EBS, Secrets Manager, Route 53, state | $23              |
| **Rounded total**                                  | **$680**         |


Verify in the [AWS Pricing Calculator](https://calculator.aws/), [EKS pricing](https://aws.amazon.com/eks/pricing/), and [EKS version lifecycle](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).

## GCP

Assumptions: 730 hours/month, on-demand list, `us-east1`, one regional GKE Standard cluster, two `n4a-standard-4` ARM64 nodes, Cloud SQL PostgreSQL 16 Enterprise HA (2 vCPU / 7.5 GiB, 50 GiB SSD), Memorystore Redis 7 Standard HA 5 GiB, Cloud NAT, global HTTPS load balancer.


| Resource                                      | Monthly estimate |
| --------------------------------------------- | ---------------- |
| GKE cluster management                        | $73              |
| Two N4A nodes + disks                         | $245             |
| Cloud SQL PostgreSQL HA                       | $220             |
| Memorystore Redis Standard HA                 | $197             |
| Cloud NAT + HTTPS load balancer               | $35              |
| DNS, Secret Manager, GCS, logging placeholder | $13              |
| **Rounded total**                             | **$780**         |


Verify in the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator), [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing), [Cloud SQL pricing](https://cloud.google.com/sql/pricing), and [Memorystore pricing](https://cloud.google.com/memorystore/docs/redis/pricing).

## What is not in these numbers

- GPU instances, OrangeLine workers, worker networking, or model storage
- Ryvn or Subconscious subscription pricing
- NAT/egress data processing, internet transfer, and extra logging volume
- Taxes, support plans, reserved/spot/committed discounts

