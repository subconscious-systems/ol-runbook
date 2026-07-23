# Private AWS worker routing

This Terraform root connects an existing API gateway VPC to an existing GPU
host and creates private HTTPS endpoints for every SGLang worker.

It creates:

- same-account VPC peering and routes in both directions;
- a reusable NLB security group and the GPU NodePort ingress rule;
- one internal Network Load Balancer and target group per worker;
- HTTP `/health` target checks against each worker NodePort;
- an ACM wildcard certificate, unless an existing certificate is supplied;
- Route 53 aliases such as `8b-a.workers.example.com`;
- a gateway Helm values snippet allowing worker-VPC HTTPS egress.

It does not create the gateway VPC, EKS cluster, GPU instance, k3s, SGLang
deployment, gateway Helm release, or gateway dashboard records.

## Prerequisites

- Terraform 1.6 or newer.
- AWS credentials able to manage EC2 networking, ELBv2, ACM, and Route 53.
- Existing gateway and worker VPCs with non-overlapping CIDRs.
- A running GPU EC2 instance with healthy SGLang NodePorts.
- A public Route 53 hosted zone.

Check a worker locally before applying:

```bash
curl -i http://127.0.0.1:30003/health
```

Do not continue until it returns HTTP 200.

## Find the required IDs

Identify the gateway VPC and worker VPC:

```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[].{Id:VpcId,Cidr:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

List the gateway private subnets and worker subnets:

```bash
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=vpc-REPLACE_GATEWAY \
  --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock}' \
  --output table

aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=vpc-REPLACE_WORKER \
  --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock}' \
  --output table
```

Terraform derives each subnet's effective route table, including implicit main
route-table associations. The worker subnet list must include the GPU
instance's availability zone.

Get the GPU instance and attached security groups:

```bash
aws ec2 describe-instances \
  --instance-ids i-REPLACE_GPU \
  --query 'Reservations[0].Instances[0].{Vpc:VpcId,Subnet:SubnetId,SecurityGroups:SecurityGroups}' \
  --output json
```

Audit every security group attached to that instance for public NodePort rules:

```bash
aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values=sg-REPLACE_GPU \
  --query 'SecurityGroupRules[?IsEgress==`false` && (CidrIpv4==`0.0.0.0/0` || CidrIpv6==`::/0`)].{Id:SecurityGroupRuleId,From:FromPort,To:ToPort,Cidr4:CidrIpv4,Cidr6:CidrIpv6}' \
  --output table
```

Remove any public rule overlapping `30000-32767`. AWS combines ingress from
every security group attached to the instance; adding the Terraform-managed
NLB-source rule does not cancel a broader existing rule.

## Configure and apply

```bash
cd gpu-deployment/terraform/aws-private-workers
cp terraform.tfvars.example terraform.tfvars
```

Replace every placeholder in `terraform.tfvars`. The default 8B worker map is:

```hcl
workers = {
  "8b-a" = { node_port = 30003 }
  "8b-b" = { node_port = 30004 }
  "8b-c" = { node_port = 30005 }
  "8b-d" = { node_port = 30006 }
}
```

For the 27B profile use:

```hcl
workers = {
  "27b-a" = { node_port = 30001 }
  "27b-b" = { node_port = 30002 }
}
```

Initialize and review the plan:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
```

The plan should show:

- one peering connection;
- one route per effective gateway-route-table/worker-CIDR pair;
- one reverse route per effective worker-route-table/gateway-CIDR pair;
- one reusable NLB security group;
- one target group, attachment, NLB, TLS listener, and DNS record per worker;
- optionally one wildcard certificate.

Apply:

```bash
terraform apply
```

Certificate creation may take several minutes while ACM validates the Route 53
CNAME. Terraform waits for validation before creating TLS listeners.

If the validation CNAME already exists from another certificate/state, do not
overwrite it blindly. Reuse the existing issued certificate, import the record
into this state, or remove it only after confirming it is stale and not needed
for certificate renewal.

## Configure the gateway

Print the endpoint map:

```bash
terraform output worker_endpoints
```

Add the emitted suffix to the gateway Helm values:

```yaml
gateway:
  routeAllowedHostSuffixes:
    - workers.example.com
```

Print and merge the worker-egress snippet into the gateway Helm values:

```bash
terraform output -raw gateway_worker_egress_helm_values_yaml
```

The snippet populates `networkPolicy.egress.additionalRules`. When gateway
egress policy enforcement is enabled, the chart adds worker-VPC TCP 443 to its
existing DNS, database, Kubernetes API, telemetry, and provider rules. When
egress enforcement is disabled, pod egress is already unrestricted and the
additional rule has no effect. No standalone NetworkPolicy is applied.

Create one SGLang-worker dashboard endpoint per Terraform output:

```text
8b-a | https://8b-a.workers.example.com
8b-b | https://8b-b.workers.example.com
8b-c | https://8b-c.workers.example.com
8b-d | https://8b-d.workers.example.com
```

Use the same gateway-issued worker key that was supplied to the worker Helm
deployment.

## Verify

Check the target groups:

```bash
for arn in $(terraform output -json worker_endpoints | jq -r '.[].target_group_arn'); do
  aws elbv2 describe-target-health \
    --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[].{Target:Target,Health:TargetHealth.State}' \
    --output table
done
```

Every target must become `healthy`.

From a pod in the gateway namespace:

```bash
kubectl run worker-route-test \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 \
  --labels app.kubernetes.io/instance=REPLACE_GATEWAY_RELEASE,app.kubernetes.io/component=gateway \
  -- curl -i https://8b-a.workers.example.com/health
```

Expected result: HTTP 200 with successful certificate validation.

## Add or remove workers

Edit only the `workers` map, then run:

```bash
terraform plan
terraform apply
```

Adding a map entry creates its target group, NLB, listener, and DNS record.
Removing an entry destroys those per-worker resources but keeps the shared
peering, routes, certificate, and security group.

## Reusing existing infrastructure

Supply existing shared resources:

```hcl
existing_vpc_peering_connection_id = "pcx-..."
existing_nlb_security_group_id      = "sg-..."
certificate_arn                    = "arn:aws:acm:REGION:ACCOUNT:certificate/..."
```

For a temporary adoption plan, set these to false if the matching routes and
security-group rules already exist and have not yet been imported:

```hcl
manage_vpc_routes           = false
manage_security_group_rules = false
```

Do not leave them false for a new environment. Existing per-worker target
groups, NLBs, listeners, and Route 53 records should be imported into their
matching `for_each` addresses before including those workers in the map.

Set explicit names when adopting resources that predate the generated,
replacement-safe target-group suffix:

```hcl
workers = {
  "8b-a" = {
    node_port         = 30003
    target_group_name = "8b-a"
    nlb_name          = "8b-a-NLB"
  }
}
```

Example addresses:

```text
aws_lb_target_group.worker["8b-a"]
aws_lb_target_group_attachment.worker["8b-a"]
aws_lb.worker["8b-a"]
aws_lb_listener.worker_tls["8b-a"]
aws_route53_record.worker["8b-a"]
```

Always run `terraform plan` after imports and confirm it does not propose
replacing a live NLB.

## Important behavior

- NLBs are internal; public internet clients cannot reach them.
- Route 53 records are public aliases that resolve to private NLB addresses.
- TLS terminates at each NLB and plaintext HTTP is forwarded to the NodePort.
- Target groups use `/health`, not `/`.
- Cross-zone load balancing defaults to enabled so a multi-subnet NLB can reach
  a GPU target in another enabled availability zone.
- The generated wildcard is `*.worker_domain` and can be reused by every worker.
- VPC peering is non-transitive. Terraform derives effective route tables from
  the supplied gateway, NLB, and GPU-instance subnets.
- New peering is auto-accepted only for VPCs in the current AWS account. For
  cross-account routing, create and accept peering first, then supply its ID.
