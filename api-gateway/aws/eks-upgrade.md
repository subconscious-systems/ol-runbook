# EKS staged upgrade: 1.32 to 1.33

This is the only approved EKS hop in this runbook: **1.32 → 1.33**. Operate one
minor version per `api-gateway-infra` Distr Application release.

**Stop after 1.33.** Do not set `KUBERNETES_VERSION` to 1.34 or later and do not
select a later-hop infra release until the user has validated the 1.33 result
and explicitly approved the next hop. A cluster below 1.32 needs an earlier
staged release; a cluster already on 1.33 needs no version upgrade.

EKS 1.32 is in extended support. EKS 1.33 standard support ends July 29, 2026
and moves to extended support afterward. Confirm the live support tier before
the maintenance window. See
[cost-estimate.md](cost-estimate.md).

## Scope and maintenance expectations

The infra release changes the EKS control plane, managed node group, and pinned
EKS add-ons through Terraform. It does not upgrade the gateway Helm application
or the separate k3s clusters on GPU hosts.

Schedule a staffed maintenance window. EKS and the managed node group perform
rolling work, but pod eviction, rescheduling, add-on restarts, and short request
failures remain possible. Do not promise zero downtime. Keep the window open
until every post-apply gate passes, and keep an operator available during the
24-hour soak.

Before the window, record:

- approved change and rollback owners;
- exact staged `api-gateway-infra` Distr Application version;
- infra `DEPLOY_NAME` (also the EKS cluster name), AWS Region, gateway namespace,
  public origin, and current gateway Application version;
- EKS control-plane version, node-group names/versions, add-on versions, current
  pod images, and recent Datadog alerts;
- successful dashboard login and authenticated inference evidence.

Use the vendor-designated infra Application version whose release notes state
that it packages the 1.32→1.33 hop. **Do not use `latest`.** Keep the gateway
setting at `GATEWAY_AUTO_DEPLOY=false` and
`GATEWAY_CHART_VERSION=nochange` so this operation does not combine a gateway
release with the EKS change.

Before the EKS maintenance window, deploy the vendor-designated gateway
compatibility Application version as a separate Distr Helm rollout on EKS 1.32.
That release pins its cleanup-hook kubectl image to 1.33. Validate it with the
pre-upgrade gates below, then leave that exact gateway version unchanged for the
infra dry-run, apply, and 24-hour EKS soak.

## Operator variables and access

EKS API access is normally restricted to the bootstrap host. From
`api-gateway/aws/bootstrap`, open the host with:

```bash
./scripts/connect.sh "$DEPLOY_NAME"
```

Run the `aws` and `kubectl` checks below on that host after setting:

```bash
export CLUSTER='<DEPLOY_NAME>'
export AWS_REGION='<AWS_REGION>'
export NAMESPACE='<GATEWAY_DISTR_DEPLOYMENT_NAME>'
export RELEASE="$NAMESPACE"
export PUBLIC_ORIGIN='https://<DOMAIN_NAME>'
export SMOKE_API_KEY='<gateway API key>'
export SMOKE_MODEL='<registered model-group name>'
export WORKER_HEALTH_URL='https://<worker-host>/health'
export HOME=/root KUBECONFIG=/root/.kube/config
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
test "$(kubectl version --client -o json \
  | jq -r '.clientVersion.gitVersion')" = "v1.33.13"
```

Do not paste `SMOKE_API_KEY` into Distr, logs, tickets, or this repository.

## Pre-upgrade health gates

All of these gates must pass before changing the Distr deployment:

```bash
test "$(aws eks describe-cluster \
  --name "$CLUSTER" --region "$AWS_REGION" \
  --query 'cluster.version' --output text)" = "1.32"
test "$(aws eks describe-cluster \
  --name "$CLUSTER" --region "$AWS_REGION" \
  --query 'cluster.status' --output text)" = "ACTIVE"

aws eks list-insights \
  --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --filter '{"categories":["UPGRADE_READINESS"]}'
test "$(aws eks list-insights \
  --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --filter '{"categories":["UPGRADE_READINESS"],"kubernetesVersions":["1.33"],"statuses":["ERROR","UNKNOWN"]}' \
  --query 'length(insights)' --output text)" = "0"

kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/distr-agent --timeout=5m
kubectl -n "$NAMESPACE" rollout status \
  deployment/"$RELEASE"-gateway --timeout=10m
kubectl -n "$NAMESPACE" rollout status \
  deployment/"$RELEASE"-router --timeout=10m

curl -fsS "$PUBLIC_ORIGIN/healthz"
curl -fsS "$PUBLIC_ORIGIN/readyz"
curl -fsS "$PUBLIC_ORIGIN/dashboard/login" >/dev/null

kubectl -n "$NAMESPACE" run eks-upgrade-worker-route-smoke \
  --image=curlimages/curl --restart=Never --rm -i \
  --command -- curl -fsS "$WORKER_HEALTH_URL"

curl -fsS "$PUBLIC_ORIGIN/v1/chat/completions" \
  -H "Authorization: Bearer $SMOKE_API_KEY" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg model "$SMOKE_MODEL" \
    '{model:$model,messages:[{role:"user",content:"Reply with OK"}],stream:false}')" \
  | jq -e '.choices[0].message.content | length > 0'
```

Review every `UPGRADE_READINESS` insight. `ERROR` is a hard stop; resolve it and
refresh the insights before continuing. Also stop for unready nodes, failed
rollouts, non-2xx public checks, failed worker routing or inference, or an
unexplained active Datadog alert.

## Distr dry-run

In the existing `api-gateway-infra` Docker deployment:

1. Select the exact approved 1.32→1.33 Application version.
2. Preserve all customer-specific env and secret references.
3. Set:

   ```text
   KUBERNETES_VERSION=1.33
   GATEWAY_AUTO_DEPLOY=false
   GATEWAY_CHART_VERSION=nochange
   DISTR_DRY_RUN=1
   ```

4. Start the Distr deployment and save the runner logs and Terraform plan.

The expected plan updates the EKS control plane, the existing managed node
group, and the release-pinned EKS add-ons. It must not replace the VPC, EKS
cluster, RDS, Valkey, load balancer, Secrets Manager secrets, or bootstrap host.
It must not select a new gateway Application version. Any destroy/recreate,
unrelated change, or version other than 1.33 is a hard stop.

The plan shows the final External Secrets target `0.19.2`. During the real
apply, the runner first migrates CRD storage to `external-secrets.io/v1`, then
applies and verifies External Secrets `0.17.0`, `0.18.2`, and `0.19.2` while
the cluster is still on EKS 1.32. Any failed secret-controller, store, sync, or
generated-Secret check stops the run before the EKS control-plane update.

The dry-run runner intentionally idles after `terraform plan`; stop or replace
that revision through Distr after collecting the plan.

## Distr apply

After plan approval, change only:

```text
DISTR_DRY_RUN=0
```

Start a new deployment of the same pinned infra Application version. Do not edit
the environment during the apply and do not start a second infra run in
parallel. Follow both Distr logs and the EKS update history until Terraform
finishes successfully.

Require the runner log to show successful verification of External Secrets
`0.17.0`, `0.18.2`, and `0.19.2` before it reports the EKS 1.32→1.33
control-plane plan or apply. If any ESO step fails, do not manually advance the
EKS version; correct the error and rerun the same pinned release.

Record the EKS control-plane upgrade completion time. AWS permits a rollback
only until seven days after that completion time.

## Exact post-apply gates

Repeat every pre-upgrade gate, changing the expected control-plane version to
1.33. In addition, require all nodes to report kubelet 1.33 and inspect the
managed add-ons:

```bash
test "$(aws eks describe-cluster \
  --name "$CLUSTER" --region "$AWS_REGION" \
  --query 'cluster.version' --output text)" = "1.33"
test "$(aws eks describe-cluster \
  --name "$CLUSTER" --region "$AWS_REGION" \
  --query 'cluster.status' --output text)" = "ACTIVE"

kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
kubectl get nodes -o json \
  | jq -e '[.items[].status.nodeInfo.kubeletVersion | startswith("v1.33.")] | all'

for addon in coredns kube-proxy vpc-cni aws-ebs-csi-driver; do
  aws eks describe-addon \
    --cluster-name "$CLUSTER" --region "$AWS_REGION" \
    --addon-name "$addon" \
    --query 'addon.{name:addonName,version:addonVersion,status:status}' \
    --output table
done

test "$(aws eks describe-addon \
  --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --addon-name coredns --query 'addon.addonVersion' --output text)" \
  = "v1.12.4-eksbuild.18"
test "$(aws eks describe-addon \
  --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --addon-name kube-proxy --query 'addon.addonVersion' --output text)" \
  = "v1.33.10-eksbuild.17"
test "$(aws eks describe-addon \
  --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --addon-name vpc-cni --query 'addon.addonVersion' --output text)" \
  = "v1.22.3-eksbuild.1"
test "$(aws eks describe-addon \
  --cluster-name "$CLUSTER" --region "$AWS_REGION" \
  --addon-name aws-ebs-csi-driver --query 'addon.addonVersion' --output text)" \
  = "v1.63.0-eksbuild.1"

kubectl -n external-secrets get deployment external-secrets -o json \
  | jq -e 'all(.spec.template.spec.containers[].image; endswith(":v0.19.2"))'
kubectl get clustersecretstores.external-secrets.io -o json \
  | jq -e 'all(.items[];
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))'
kubectl get externalsecrets.external-secrets.io -A -o json \
  | jq -e 'all(.items[];
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))'
```

Each listed add-on must be `ACTIVE`. Then run the node wait, three rollout
checks, `/healthz`, `/readyz`, dashboard login, in-cluster worker route smoke,
and authenticated `/v1/chat/completions` smoke exactly as in the pre-upgrade
section. Confirm the Distr Kubernetes agent is Healthy in Hub and that Datadog
has no new cluster, pod, database, cache, router, or adapter alert.

Any failed gate means the upgrade is incomplete even if Terraform reports
success.

## 24-hour soak and stop point

For 24 continuous hours after all immediate gates pass:

- keep `KUBERNETES_VERSION=1.33` and the pinned hop release unchanged;
- do not combine the soak with a gateway, worker, networking, database, or
  secret-rotation change;
- monitor EKS/node/add-on health, restarts and pending pods, Distr agent health,
  Datadog alerts, public `/healthz` and `/readyz`, dashboard login, worker route
  health, and authenticated inference;
- rerun the public, route, and inference smokes at the start, after 1 hour, and
  at the end of the 24 hours.

Record the evidence and user decision. **A successful soak does not authorize
1.34 or any later hop.** Stop at 1.33 pending explicit user validation and a
separately staged release.

## Partial failure handling

- If Distr or Terraform fails before an EKS update starts, fix the reported
  prerequisite and rerun the same pinned release with the same 1.33 input.
- If the control plane reaches 1.33 but a node group or add-on fails, do not
  change versions and do not advance releases. Wait for any active AWS update to
  finish, preserve the Terraform state, and rerun the same Distr apply. Escalate
  before making manual state or resource changes.
- If Terraform succeeds but an application gate fails, keep the cluster at
  1.33 while diagnosing. Prefer a fix-forward that can complete inside the
  maintenance window.
- Never run concurrent infra applies, delete/recreate the cluster, restore old
  Terraform state, or use `terraform apply` outside the Distr runner.
- Use AWS rollback only for a material regression that cannot be fixed forward.
  Start early enough to finish the ordered preparation inside AWS's seven-day
  eligibility window.

## AWS seven-day rollback order

AWS rollback is only from the current version to the immediately previous
version, and must be initiated within seven days of the in-place upgrade
completing. For 1.33→1.32, use this order:

1. Stop new changes. Record the failure, upgrade completion time, versions, and
   active AWS update IDs. Wait until the cluster is `ACTIVE` with no update in
   progress.
2. Because 1.32 is in extended support, ensure the cluster upgrade policy is
   `EXTENDED`:

   ```bash
   aws eks update-cluster-config \
     --name "$CLUSTER" --region "$AWS_REGION" \
     --upgrade-policy supportType=EXTENDED
   ```

3. Review AWS `ROLLBACK_READINESS` insights. Resolve all `ERROR` and `UNKNOWN`
   findings; do not use `--force` without AWS/vendor escalation and explicit
   risk approval:

   ```bash
   aws eks list-insights \
     --cluster-name "$CLUSTER" --region "$AWS_REGION" \
     --filter '{"categories":["ROLLBACK_READINESS"]}'
   test "$(aws eks list-insights \
     --cluster-name "$CLUSTER" --region "$AWS_REGION" \
     --filter '{"categories":["ROLLBACK_READINESS"],"statuses":["ERROR","UNKNOWN"]}' \
     --query 'length(insights)' --output text)" = "0"
   ```

4. **Roll every EKS managed node group back to 1.32 first.** Repeat for each
   name returned by `list-nodegroups`, monitor its update ID to `Successful`,
   and require the node group to return to `ACTIVE`:

   ```bash
   aws eks list-nodegroups \
     --cluster-name "$CLUSTER" --region "$AWS_REGION"
   aws eks update-nodegroup-version \
     --cluster-name "$CLUSTER" --region "$AWS_REGION" \
     --nodegroup-name '<node-group-name>' \
     --kubernetes-version 1.32
   ```

5. **Before the control plane**, downgrade any EKS add-on that rollback
   readiness reports as incompatible. Use the exact 1.32-compatible versions
   recorded from the previous approved infra release; EKS does not roll add-ons
   back automatically:

   ```bash
   aws eks update-addon \
     --cluster-name "$CLUSTER" --region "$AWS_REGION" \
     --addon-name '<addon-name>' \
     --addon-version '<approved-1.32-addon-version>'
   ```

6. Initiate the control-plane rollback and save the returned update ID:

   ```bash
   aws eks update-cluster-version \
     --name "$CLUSTER" --region "$AWS_REGION" \
     --kubernetes-version 1.32
   aws eks describe-update \
     --name "$CLUSTER" --region "$AWS_REGION" \
     --update-id '<update-id>'
   ```

7. After the update is `Successful`, select the previous approved 1.32 infra
   Application release and restore `KUBERNETES_VERSION=1.32` in Distr before
   any later infra run. Do not run the 1.33 release again. Re-run every health
   gate and begin a new 24-hour observation period.

AWS preserves etcd data, workloads, and persistent volumes during control-plane
rollback, but it does not roll back managed node groups or add-ons. See the
[AWS EKS rollback procedure](https://docs.aws.amazon.com/eks/latest/userguide/rollback-cluster.html)
for current prerequisites and limitations.
