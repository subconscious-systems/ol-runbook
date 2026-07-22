# GPU deployment

Install path for SGLang workers on a customer GPU host. Profiles, host bootstrap,
and private AWS routing automation live in this directory.

## Prerequisites

| Requirement | Notes |
|---|---|
| GPU EC2 instance | Ubuntu/Debian, 4× GPU for profiles below |
| [api-gateway](https://github.com/subconscious-systems/api-gateway) | Deployed and reachable |
| [Distr](https://app.distr.sh) account | Subconscious provisions the SGLang worker Helm application |

## Step 1 — GPU host

Download with **`curl`** — do not copy/paste the script into vim; pasted files often get corrupted (`apt-get` → `apget`, broken lines).

```bash
curl -fsSL https://raw.githubusercontent.com/subconscious-systems/ol-runbook/main/gpu-deployment/dependencies.sh -o ~/dependencies.sh
chmod +x ~/dependencies.sh
~/dependencies.sh
```

Or clone the runbook (includes profiles for step 4):

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/gpu-deployment
chmod +x dependencies.sh
./dependencies.sh
```

May reboot once for NVIDIA drivers. Then verify:

```bash
nvidia-smi
kubectl get nodes
kubectl get namespace sglang
```

---

## Step 2 — Connect Distr

1. Log into [Distr](https://app.distr.sh/) and click on the secrets page.
2. Add a secret called WORKER_API_KEY, go to gateway dashboard to generate value, store this somewhere safe, will need it to configure path.
3. Navigate to the deployments page and click on New Deployment.
4. Select 27b-deployment as the application.
5. Enter deployment name and set Kubernetes Namespace to "sglang".
6. Leave default Application Config, go to [profiles](profiles/) and find the correct profile. Copy and paste exactly from the profile file into the Helm Values section in the App Config section of Distr.
7. Click Customize Helm options and set watcher to 2h.
8. Click create deployment.
9. Go back to GPU host and run the command Distr provides, should look like:

```bash
kubectl apply -n sglang -f "https://app.distr.sh/api/v1/connect?..."
```

---

## Step 3 — AWS: NLB per worker

Each worker gets a **NodePort** on the GPU instance (see table). Repeat for every worker.

### Preferred: Terraform

The reusable Terraform setup creates the VPC peering, bidirectional routes,
security-group rules, target groups, internal NLBs, wildcard certificate,
Route 53 aliases, and outputs the scoped gateway worker-egress NetworkPolicy:

```bash
cd terraform/aws-private-workers
cp terraform.tfvars.example terraform.tfvars
# Fill in the existing gateway VPC, GPU VPC/instance, private subnets,
# Route 53 zone, worker domain, namespace, and gateway Helm release name.
terraform init
terraform plan
terraform apply
terraform output worker_endpoints
```

Follow the complete setup and verification guide in
[`terraform/aws-private-workers/README.md`](terraform/aws-private-workers/README.md).

### Manual fallback

If Terraform cannot be used:

1. Peer the gateway and worker VPCs.
2. Add gateway-to-worker and worker-to-gateway routes.
3. Allow TLS 443 from the gateway VPC into a reusable NLB security group.
4. Allow the GPU NodePort range only from that NLB security group.
5. Create an **Instances/TCP** target group per NodePort.
6. Set its health check to **HTTP**, traffic port, path `/health`, matcher `200`.
7. Create an **internal** NLB with a TLS 443 listener and wildcard ACM certificate.
8. Create a Route 53 alias such as `8b-a.workers.example.com`.
9. Permit gateway, router, and adapter pod egress to the worker VPC on TCP 443.

Never expose the NodePorts to the public internet.

---

## Step 4 — Dashboard worker pool

Model group from step 3 → **Create worker pool**. One line per worker; same `WORKER_API_KEY` for all.

**27B** (`qwen3.6-27b`):

```text
27b-a | https://27b-a.<worker-domain> | <WORKER_API_KEY>
27b-b | https://27b-b.<worker-domain> | <WORKER_API_KEY>
```

**8B** (`qwen3-8b`):

```text
8b-a | https://8b-a.<worker-domain> | <WORKER_API_KEY>
8b-b | https://8b-b.<worker-domain> | <WORKER_API_KEY>
8b-c | https://8b-c.<worker-domain> | <WORKER_API_KEY>
8b-d | https://8b-d.<worker-domain> | <WORKER_API_KEY>
```

Add `<worker-domain>` (for example `workers.example.com`) to the gateway
`routeAllowedHostSuffixes`, then wait for each endpoint to report `registered`.

---
