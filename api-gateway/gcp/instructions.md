# GCP production installation

Use the guided installer for every new GCP gateway. The operator supplies one
reviewed JSON file, authenticates once, enters secrets through hidden prompts,
and makes five typed approvals. The installer creates the Distr targets and
deployments, connects both agents, waits for each stage, and resumes safely
after interruption.

Architecture: [README.md](README.md). Foundation internals:
[bootstrap/](bootstrap/). Troubleshooting:
[troubleshooting.md](troubleshooting.md).

## Before starting

Do not create cloud resources until all are true:

- The selected `api-gateway-infra` release supports complete `CLOUD=gcp`
  operation and the selected gateway release supports ARM64 and GCE Ingress.
- Exact infra and gateway version names are approved and entitled in Distr.
- The project ID, organization or folder, billing account, hostname, existing
  shared Cloud DNS project/zone, operator principals, and non-overlapping CIDRs
  are approved.
- N4A quota/capacity is available in `us-east1-b` and `us-east1-c`.
- The installing human can create the project, attach billing, administer the
  budget, enable services, set project IAM, and change the selected DNS zone.
- A customer Distr PAT can manage secrets, targets, and deployments.
- Current Google Cloud and optional Datadog pricing has been reviewed.

This procedure creates one dedicated production project. It does not migrate
AWS state/data or provision GPU hosts. The design has no secondary test
environment and no public bootstrap VM or GKE IP endpoint.

## 1. Fill in one configuration file

Keep each Distr deployment name at most 32 characters. `zoneName` is the Cloud
DNS managed-zone resource name, not the DNS suffix.

```bash
git clone git@github.com:subconscious-systems/ol-runbook.git
cd ol-runbook/api-gateway/gcp
cp guided-install.json.example guided-install.json
$EDITOR guided-install.json
```

The file contains no credentials. It records:

- the production project, parent, billing account, budget, and operators;
- the bootstrap `/24`, platform `/16`, and `us-east1` bootstrap zone;
- the existing shared Cloud DNS project/zone and production hostname;
- Distr Application IDs, exact pinned version names, and deployment names;
- allowed inference route suffixes and optional Datadog/dashboard choices.

Use exactly one of `organizationId` or `folderId`. The two CIDRs must not
overlap each other or any connected network. The platform derives node, Pod,
Service, private-service, and control-plane ranges from the `/16`.
`dns.projectId` must differ from the new gateway project: the zone has to exist
before Gate 1. That gate grants the keyless platform service account
`roles/dns.admin` only in this selected DNS project.

## 2. Run or resume the installer

```bash
cd bootstrap
bash scripts/guided-install.sh --config ../guided-install.json
```

The installer installs/checks gcloud and the GKE authentication plugin, then
opens human user and Application Default Credentials login only when needed.
It never creates or downloads a service-account key.

Enter the customer Distr PAT at the hidden confirmation prompt. If enabled,
Datadog keys and the first dashboard administrator password are prompted the
same way. The installer creates project-prefixed masked secret keys so another
gateway installation cannot overwrite them. Values are sent directly through
`https://app.distr.sh`; they are not arguments, config values, Terraform
variables, or installer state. Short-lived mode-0600 API request files are
deleted immediately and again by the installer exit trap.

If the process or terminal stops, run the same command again. Progress and
non-secret resource IDs live in
`bootstrap/.guided-install/<PROJECT_ID>/state.json`. The installer reuses
existing named Hub resources and continues from the last completed stage. It
rejects any configuration change after cloud work begins; restore the reviewed
file before resuming.

## The five approvals

Each gate shows the material being approved and requires typing
`APPROVE GATE N <PROJECT_ID>` exactly.

1. **Project and private bootstrap.** Review the complete saved Terraform plan
   for one project, budget, state bucket, private VPC/NAT, keyless service
   account/IAM, IAP firewall, and private VM. The apply consumes that exact
   plan. State is then migrated to versioned GCS, an empty plan is required,
   and preflight/host repair run automatically.
2. **Cloud foundation.** The installer creates the infra Docker target and
   deployment with `DISTR_DRY_RUN=1`, connects its agent over IAP, and displays
   the cloud-foundation plan and SHA-256 checksum. Approval switches the same
   deployment to apply. The runner rejects missing, changed, or wrong-stage
   saved plans and intentionally stops after GKE is reachable.
3. **Complete platform.** The installer runs a second dry-run now that GKE
   exists and displays the complete un-targeted plan and checksum. Approval
   applies exactly that plan, including ESO, namespaces, ExternalSecrets,
   managed certificate, ingress policies, and optional Datadog resources.
4. **Gateway release.** The installer displays the entitled gateway version ID
   and generated Helm values. Approval creates the Kubernetes target, deploys
   that exact release and values, connects the in-cluster agent, and waits for
   a healthy Distr status.
5. **Production acceptance.** The installer obtains the Cloud SQL and Redis
   output names and runs the read-only smoke suite. Approval records completion
   only after those checks pass.

Do not approve a replacement, resource outside the intended project, public
IP endpoint, service-account key, Owner/Editor grant, disabled deletion
protection, unpinned version, or inline secret.

## What is automated

The customer does not manually edit Hub environment variables, create either
deployment target, paste either agent command, toggle dry-run/apply values,
copy Terraform outputs, or trigger repeated releases. The installer performs
those operations idempotently through the Distr API and IAP.

The remaining human work is intentional:

- approve the input file and ensure DNS delegation/quota/entitlements exist;
- complete Google login and provide the Distr PAT and enabled optional secrets;
- review and approve the five displayed gates;
- preserve the plan/checksum/smoke output in the customer's change record.

## Acceptance record

Retain the exact config, five approvals, both infra plan checksums, pinned
application/version IDs, Terraform state serials, generated Helm values, and
smoke output. Acceptance requires private DNS-only GKE access, ready ARM nodes,
Cloud SQL/Redis HA and protection, ready ESO/fixed Secrets, healthy agents and
gateway workloads, active certificate, HTTPS redirect, `/healthz`, `/readyz`,
and dashboard reachability.

Enable optional Datadog DBM only after the gateway is healthy, following
[datadog-operations.md](datadog-operations.md). Manual scripts documented in
[bootstrap/README.md](bootstrap/README.md) are recovery tools, not an alternate
new-install workflow.
