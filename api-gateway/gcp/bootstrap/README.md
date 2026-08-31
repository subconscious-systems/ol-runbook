# Docker agent host bootstrap

Terraform and scripts for the GCP host that runs the Distr Docker agent and
`api-gateway-infra` runner. This is the GCP equivalent of
[`../../aws/bootstrap/`](../../aws/bootstrap/): the VM supplies cloud identity,
and no long-lived cloud access key is stored in Distr Hub.

End-to-end source of truth: [../instructions.md](../instructions.md).

## Recommended install command

```bash
./scripts/install.sh
```

This interactive CLI walks through the complete production install, explains
where every Google ID, Hub Secret, provider value, and agent command comes from,
delegates to the scripts documented below, and pauses for the required Distr
Hub actions. All customer-specific Distr environment variables and Secret
references are collected in one dedicated step.
Use `--list-steps` to preview it, `--check` for an offline contract check, or
`--from-step N` to resume without repeating completed cloud operations. It does
not persist connect URLs or resolved secrets. It generates the ignored
`../.generated/gateway-infra.env` and
`../.generated/gateway-infra-auto-deploy.env` from the same Terraform outputs
and prompted production values. The first is pasted for the foundation pass;
the second is already prepared for the gateway auto-deploy pass.

Branch changes do not replace an ignored local `terraform.tfvars`. If the CLI
finds the retired multi-environment schema, it requires an explicit `replace`
confirmation and moves the old values to a private temporary archive. The CLI
then discovers accessible GCP resources, lets the operator select numbered
existing production-project and DNS-project candidates, reads the production
project's attached billing account, and generates a fresh production-only
file. ADC quota uses that same selected project automatically. A text editor is
only an optional final review. Delete the temporary archive after verifying the
generated file.

ADC quota uses the selected existing production project automatically. There
is no second project selection, and the CLI does not create GCP projects.

## What the one bootstrap command does

```bash
./scripts/install-gcloud.sh
./scripts/setup-gcloud.sh
# Guided required/optional GCP input questionnaire
# Generates mode-0600 terraform.tfvars
./scripts/bootstrap.sh
```

The questionnaire says whether each value is required, optional, or fixed and
where to find it in Google Cloud Console. It lists resources visible to the
active account and saves the exact selected ID, not the display name. Manual ID
entry remains available when customer policy hides a resource from list APIs.
Re-running step 3 offers to reuse an already-valid production file:

```bash
./scripts/install.sh --from-step 3
```

`bootstrap.sh`:

1. initializes and validates Terraform;
2. displays the bootstrap plan for the selected existing project;
3. asks for that project ID as confirmation;
4. applies APIs, state bucket, private network/NAT,
   service account/IAM, IAP firewall, and private VM;
5. migrates the first local state into the versioned GCS bucket;
6. verifies billing, APIs, private access, Shielded VM, OS Login, NAT, and the
   absence of user-managed service-account keys;
7. reapplies the idempotent host setup.

Re-running the command keeps the same VM and remote state. `--yes` is available
for an already-approved non-interactive recovery run.

## Security properties

- One selected existing production project, outside Terraform ownership.
- Private VM with no public IP; egress through Cloud NAT.
- IAP TCP forwarding and OS Login for operator access.
- Attached service account with scoped platform roles; no service-account key.
- GCS state bucket with uniform access, public-access prevention, and
  versioning.
- Existing project lifecycle remains outside Terraform; VM deletion protection
  is enabled by default.
- DNS administration granted only in the selected existing DNS project.

## Agent commands

These intentionally match the AWS command shape:

```bash
./scripts/run-agent.sh

./scripts/connect-k8s-agent.sh <INFRA_DEPLOY_NAME>
```

Each command securely prompts for the corresponding one-time Hub credential
with terminal echo disabled. The credential travels over stdin/IAP and is not
placed in shell history, a process argument, or a file. The Docker agent runs
on the VM. The Kubernetes agent runs as pods in GKE; the VM only executes
kubectl through IAP using the GKE DNS endpoint.

## Layout

| Path | Role |
| --- | --- |
| `scripts/install.sh` | Guided end-to-end production install and resume checkpoints |
| `scripts/install-gcloud.sh` | Install/check local gcloud and the GKE auth plugin |
| `scripts/bootstrap.sh` | One-command project/VM bootstrap, state migration, preflight, and host repair |
| `scripts/setup-gcloud.sh` | Human user and ADC login |
| `scripts/migrate-state.sh` | Recover or manually complete the first-state migration to GCS |
| `scripts/preflight.sh` | Read-only billing/API/IAM/network/VM security checks |
| `scripts/repair-host.sh` | Idempotent Docker/Compose/kubectl repair |
| `scripts/run-agent.sh` | Connect the Distr Docker target through IAP |
| `scripts/connect-k8s-agent.sh` | Connect the Distr Kubernetes target through the GKE DNS endpoint |
| `scripts/connect.sh` | Break-glass IAP/OS Login shell |
| `scripts/smoke-checks.sh` | Read-only platform and gateway checks |
| `scripts/rotate-app-secret.sh` | Rotate application secrets using the runner image |
| `scripts/teardown-platform.sh` | Destroy platform Terraform via IAP and the runner image |
| `*.tf` | Production project and private bootstrap foundation |

## Break-glass access

```bash
./scripts/connect.sh <INFRA_DEPLOY_NAME>
./scripts/connect.sh
```

The first form refreshes root's DNS-endpoint kubeconfig before opening the
shell. The second opens an IAP shell only.

## State recovery

`migrate-state.sh` is normally called automatically. Use it directly only when
the project/VM apply succeeded but bootstrap stopped before state migration.
Generated `backend.tf` and `.backend.hcl` are ignored by git.

The kubeconfig is built with `gcloud container clusters get-credentials
--dns-endpoint`. The released GKE stack must enable the DNS endpoint, allow
external traffic through that endpoint, grant `container.clusters.connect`, and
disable IP-based control-plane endpoints.

## Platform teardown

Do not destroy these foundations while either Distr agent or platform stack is
still running. Undeploy the gateway Helm app in Hub first. Then, from this
directory:

```bash
./scripts/teardown-platform.sh --yes <INFRA_DEPLOY_NAME> <GATEWAY_DEPLOY_NAME>
```

Full procedure: [../teardown.md](../teardown.md). After the
platform is gone, undeploy the infra Docker app, then optionally destroy this
foundation.

## Bootstrap-only teardown

Do not destroy these foundations while either Distr agent or platform stack is
still running. Complete platform teardown first
([../teardown.md](../teardown.md)). The selected existing project is never
deleted by this stack. For an approved foundation teardown:

1. Preserve/export required audit evidence and state.
2. Set `protect_bootstrap_vms = false` and apply.
3. Empty or preserve the state buckets according to retention policy.
4. Run the reviewed destroy from the remote backend.

Project deletion is a separate customer-owned action outside this runbook.
`terraform destroy` is intentionally blocked by the default VM protections
until step 2 is completed.
