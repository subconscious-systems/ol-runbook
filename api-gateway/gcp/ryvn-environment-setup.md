# Ryvn-managed GCP environment setup

This runbook prepares an existing Google Cloud project for a Ryvn-managed
Subconscious API Gateway environment. It configures billing, required Google
APIs, an AWS workload identity provider, the Ryvn provisioner service account,
and the post-provisioning checks needed for GKE, Cloud SQL, and Memorystore.

This workflow is separate from the assisted self-managed GCP installer in
[`instructions.md`](instructions.md). Use this document only when Ryvn runs the
Terraform and Kubernetes installation.

Replace every `<PLACEHOLDER>` before running a command. Standard Google role
names such as `roles/owner` are command parameters, not customer-specific
values.

## Prerequisites

- An existing active Google Cloud project.
- Permission to link the project to the selected billing account.
- Permission to enable Google APIs and update project IAM.
- The Ryvn AWS account ID and AWS IAM role name.
- `gcloud` and `kubectl` installed locally.
- An authenticated `gcloud` user:

  ```bash
  gcloud auth login
  gcloud auth list
  ```

## 1. Configure project and Ryvn identity values

```bash
PROJECT_ID="<GCP_PROJECT_ID>"
BILLING_ACCOUNT_ID="<GCP_BILLING_ACCOUNT_ID>"

AWS_ACCOUNT_ID="<RYVN_AWS_ACCOUNT_ID>"
AWS_ROLE_NAME="<RYVN_AWS_ROLE_NAME>"

SA_NAME="<RYVN_PROVISIONER_SERVICE_ACCOUNT_NAME>"
POOL_ID="<WORKLOAD_IDENTITY_POOL_ID>"
PROVIDER_ID="<WORKLOAD_IDENTITY_PROVIDER_ID>"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "$PROJECT_ID"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" \
  --format="value(projectNumber)")"

echo "Project: $PROJECT_ID"
echo "Project number: $PROJECT_NUMBER"
echo "Account: $(gcloud config get-value account)"
```

Suggested resource names are `ryvn-provisioner`, `ryvn-aws-pool`, and
`ryvn-aws-provider`. The AWS role name must match the value supplied by Ryvn.

## 2. Link billing and enable Google APIs

```bash
gcloud beta billing projects link "$PROJECT_ID" \
  --billing-account="$BILLING_ACCOUNT_ID"
```

Enable all APIs before starting the first Ryvn Terraform operation:

```bash
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  compute.googleapis.com \
  container.googleapis.com \
  dns.googleapis.com \
  servicenetworking.googleapis.com \
  redis.googleapis.com \
  sqladmin.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  --project="$PROJECT_ID"
```

Verify billing and the APIs that previously blocked provisioning:

```bash
gcloud beta billing projects describe "$PROJECT_ID"

gcloud services list \
  --project="$PROJECT_ID" \
  --enabled \
  --filter='config.name:(cloudresourcemanager.googleapis.com OR container.googleapis.com OR redis.googleapis.com OR sqladmin.googleapis.com)'
```

## 3. Create the Ryvn provisioner service account

The following create command is safe to rerun:

```bash
gcloud iam service-accounts describe "$SA_EMAIL" \
  --project="$PROJECT_ID" >/dev/null 2>&1 ||
gcloud iam service-accounts create "$SA_NAME" \
  --project="$PROJECT_ID" \
  --display-name="Ryvn Provisioner"
```

Grant the permissions expected by the current Ryvn provisioning workflow:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/owner" \
  --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --quiet
```

`roles/owner` is broad. Retain it only while it remains part of Ryvn's
documented provisioning contract, and replace it with a narrower supported
role when Ryvn provides one.

## 4. Create the Workload Identity pool

```bash
gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" \
  --location="global" >/dev/null 2>&1 ||
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="Ryvn Pool"
```

## 5. Create the AWS Workload Identity provider

```bash
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" >/dev/null 2>&1 ||
gcloud iam workload-identity-pools providers create-aws "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --account-id="$AWS_ACCOUNT_ID" \
  --display-name="Ryvn AWS Provider" \
  --attribute-mapping="google.subject=assertion.arn,attribute.aws_role=assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
```

## 6. Allow the Ryvn AWS role to impersonate the service account

```bash
POOL_NAME="$(gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --format="value(name)")"

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.aws_role/arn:aws:sts::${AWS_ACCOUNT_ID}:assumed-role/${AWS_ROLE_NAME}"
```

Verify the service-account policy:

```bash
gcloud iam service-accounts get-iam-policy "$SA_EMAIL" \
  --project="$PROJECT_ID"
```

## 7. Generate the credential configuration for Ryvn

```bash
CREDENTIAL_FILE="<OUTPUT_CREDENTIAL_FILENAME>.json"

gcloud iam workload-identity-pools create-cred-config \
  "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}" \
  --service-account="$SA_EMAIL" \
  --aws \
  --enable-imdsv2 \
  --output-file="$CREDENTIAL_FILE"

chmod 600 "$CREDENTIAL_FILE"

echo ""
echo "Copy the following JSON into Ryvn:"
echo ""
cat "$CREDENTIAL_FILE"
echo ""
```

This file is an external-account configuration, not a long-lived service
account private key. Do not commit the generated file.

## 8. Create the environment in Ryvn

Create and wait for resources in this order:

1. GKE infrastructure.
2. PostgreSQL on Cloud SQL.
3. Redis on Memorystore.
4. Gateway installation.

Do not start a dependent resource while its preceding Terraform operation is
still running.

## 9. Repair a generated Ryvn agent role when required

Current Ryvn releases may generate a project custom role that omits Cloud SQL
user management or Service Usage permissions. Run this only after the role
exists and only if provisioning reports the corresponding `403` error.

List Ryvn roles:

```bash
gcloud iam roles list \
  --project="$PROJECT_ID" \
  --filter='name:ryvn' \
  --format='table(name,title)'
```

Update the affected role:

```bash
RYVN_AGENT_ROLE_ID="<RYVN_GENERATED_AGENT_CUSTOM_ROLE_ID>"

gcloud iam roles update "$RYVN_AGENT_ROLE_ID" \
  --project="$PROJECT_ID" \
  --add-permissions="cloudsql.users.create,cloudsql.users.update,cloudsql.users.delete,serviceusage.services.use,serviceusage.operations.get"
```

## 10. Repair the Cloud SQL service identity when required

Normally API activation creates and binds this Google-managed service agent.
Use these commands only if Cloud SQL reports that its service agent is missing
or unauthorized:

```bash
gcloud beta services identity create \
  --service="sqladmin.googleapis.com" \
  --project="$PROJECT_ID"

CLOUD_SQL_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloud-sql.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CLOUD_SQL_SERVICE_AGENT}" \
  --role="roles/cloudsql.serviceAgent" \
  --quiet
```

Verify the binding:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members:${CLOUD_SQL_SERVICE_AGENT}" \
  --format='table(bindings.role,bindings.members)'
```

## 11. Connect to the GKE cluster

Set the environment-specific values created by Ryvn:

```bash
REGION="<GCP_REGION>"
CLUSTER_NAME="<RYVN_GKE_CLUSTER_NAME>"
KUBERNETES_NAMESPACE="<GATEWAY_KUBERNETES_NAMESPACE>"
GATEWAY_DEPLOYMENT="<GATEWAY_DEPLOYMENT_NAME>"
REDIS_INSTANCE="<MEMORYSTORE_INSTANCE_NAME>"
```

Fetch credentials and verify access:

```bash
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION"

kubectl get nodes
kubectl -n "$KUBERNETES_NAMESPACE" get pods
```

## 12. Inject the Memorystore TLS CA when required

Memorystore instances using server-authenticated TLS expose a unique CA. The
gateway needs that CA in `SUBCONSCIOUS_GATEWAY_REDIS_CA_CERT` before it can
finish initialization.

Ryvn should export and inject this value automatically. Use the following
workaround only when the gateway has a `rediss://` URL but the environment
variable is absent. A later Ryvn reconciliation may overwrite this manual
deployment change.

```bash
REDIS_CA_FILE="/tmp/ryvn-gateway-redis-ca.pem"
REDIS_CA_SECRET="<REDIS_CA_KUBERNETES_SECRET_NAME>"

gcloud redis instances describe "$REDIS_INSTANCE" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format='value(serverCaCerts[0].cert)' \
  > "$REDIS_CA_FILE"

kubectl -n "$KUBERNETES_NAMESPACE" create secret generic "$REDIS_CA_SECRET" \
  --from-file=SUBCONSCIOUS_GATEWAY_REDIS_CA_CERT="$REDIS_CA_FILE" \
  --dry-run=client -o yaml |
kubectl apply -f -

kubectl -n "$KUBERNETES_NAMESPACE" set env \
  "deployment/${GATEWAY_DEPLOYMENT}" \
  --from="secret/${REDIS_CA_SECRET}"

kubectl -n "$KUBERNETES_NAMESPACE" rollout status \
  "deployment/${GATEWAY_DEPLOYMENT}" \
  --timeout=5m
```

## 13. Final verification

```bash
kubectl -n "$KUBERNETES_NAMESPACE" get pods
kubectl -n "$KUBERNETES_NAMESPACE" get deployments
kubectl -n "$KUBERNETES_NAMESPACE" get services

kubectl -n "$KUBERNETES_NAMESPACE" rollout status \
  "deployment/${GATEWAY_DEPLOYMENT}" \
  --timeout=5m
```

For a failed rollout, inspect events and application logs:

```bash
kubectl -n "$KUBERNETES_NAMESPACE" get events \
  --sort-by='.lastTimestamp'

kubectl -n "$KUBERNETES_NAMESPACE" logs \
  "deployment/${GATEWAY_DEPLOYMENT}" \
  --tail=200
```

The completed gateway deployment must have all requested replicas available,
with every gateway pod reporting `Running` and `Ready`.

## References

- [Create an AWS workload identity provider](https://cloud.google.com/sdk/gcloud/reference/iam/workload-identity-pools/providers/create-aws)
- [Create an external-account credential configuration](https://cloud.google.com/sdk/gcloud/reference/iam/workload-identity-pools/create-cred-config)
- [Memorystore in-transit encryption](https://cloud.google.com/memorystore/docs/redis/manage-in-transit-encryption)
