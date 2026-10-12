# Deploy GLM 5.3 with L1 and L2 on Aranya

Deploy the Subconscious Inference System on Aranya's managed clusterdOS cluster
using its kubeconfig and `helm upgrade --install`. This procedure serves
GLM-5.3 NVFP4 with a DFlash2 draft model and L1/L2 caching. It starts one TP4
worker on each of the two B200 nodes; after verification, expand to two workers
per node to use all sixteen GPUs. Each worker has its own Dynamo sidecar.

Aranya manages Kubernetes, drivers, the GPU device plugin and local storage.
The three CPU nodes run the provider control plane and etcd. Place application
services, including the separate application etcd, on a GPU node. This deployment
uses local PVCs; it requires no object store, shared filesystem or 3FS service.

## Before the nodes arrive

Send the [provider handoff checklist](../PROVIDER-HANDOFF.md) to your Aranya contact.
Keep the completed answers with the deployment record. Node names, storage class,
namespace and runtime class must come from the delivered cluster.

Obtain a matching release folder from your Subconscious FDE containing:

- `chart/`, `cell.py` and `probe.py` from the qualified chart revision.
- `images.yaml` with registry-accessible worker and runtime SHA256 digests.
- `provider.example.yaml`, this guide and the shared `../PROVIDER-HANDOFF.md`.
- Release provenance identifying the chart revision and images.

Also obtain the exact Hugging Face repository IDs and full 40-character revision
hashes for **both** the NVFP4 main model and the matching DFlash2 draft. Image
publication does not include the model weights. A gated model also needs a
download token with access to both repositories.

Use an operator workstation with Bash, Python 3.9 or newer, Helm, kubectl and OpenSSL.
For ECR images, also install the AWS CLI and authenticate with the release
registry's pull-access identity. Cluster nodes need download access to the
registry, its layer storage and the model host. No SSH to the nodes is required.

## 1 Prepare the operator directory

Run these commands from the L1/L2 release folder (`l1-l2/` in the combined
bundle), then keep using the same shell. Replace the namespace with the one issued by Aranya. Store kubeconfigs,
values and credential records outside Git.

```bash
set -euo pipefail
umask 077
ARANYA_BUNDLE="$PWD"
ARANYA_WORKDIR="$HOME/.config/subconscious/aranya"
ARANYA_NAMESPACE="inference"
ARANYA_RELEASE="glm"
ARANYA_KUBECONFIG="$ARANYA_WORKDIR/kubeconfig"
mkdir -p "$ARANYA_WORKDIR"
cp -n "$ARANYA_BUNDLE/provider.example.yaml" "$ARANYA_WORKDIR/provider.yaml"
```

Save Aranya's kubeconfig at `$ARANYA_KUBECONFIG`. Edit `provider.yaml`, replacing
every `REPLACE_` value. Copy the delivered `images.yaml` unchanged into your
deployment record; the commands below use the original in the release folder.

The template starts with one four-GPU worker per node, HiCache ratio 4,
262,144-token context and 48 running requests per worker. Each worker requests
900 GiB RAM with a 1,000 GiB limit. These are starting budgets; confirm actual
allocatable resources and measured memory before increasing replicas.

Each node gets a separate 1 TiB model PVC shared by workers on that same node.
Confirm the capacity fits the pinned models. Use ReadWriteOnce, not
ReadWriteOncePod. A directory named `/mnt`, RAID layout or shared mount is not a
prerequisite: Aranya supplies a working local StorageClass or prebound local PVs.

## 2 Check namespace access

```bash
kubectl --kubeconfig "$ARANYA_KUBECONFIG" config current-context
python3 "$ARANYA_BUNDLE/cell.py" preflight \
  --kubeconfig "$ARANYA_KUBECONFIG" \
  --namespace "$ARANYA_NAMESPACE" --release "$ARANYA_RELEASE"
```

Confirm the context belongs to Aranya before continuing. The helper checks
namespace permissions, quotas, limits and PVCs. GPU allocation, memlock, storage
topology and cross-node connectivity still require the provider handoff answers
and workload checks. A namespace-only kubeconfig may not list nodes or
StorageClasses; Aranya can supply that information without granting cluster admin.

## 3 Give the namespace registry access

For ECR, set the profile, region and account from the release handoff. The identity
needs authorization-token access and permission to pull both image repositories.
This pipeline creates or refreshes `registry-pull` without printing the token or
putting it in a command argument.

```bash
ARANYA_AWS_PROFILE="REPLACE_AWS_PROFILE"
ARANYA_ECR_REGION="REPLACE_ECR_REGION"
ARANYA_ECR_ACCOUNT="REPLACE_ECR_ACCOUNT"
aws --profile "$ARANYA_AWS_PROFILE" --region "$ARANYA_ECR_REGION" \
  --no-cli-pager ecr get-authorization-token \
  --registry-ids "$ARANYA_ECR_ACCOUNT" --output json |
  python3 -c 'import json, sys
records = json.load(sys.stdin)["authorizationData"]
assert len(records) == 1, "Expected one registry"
record = records[0]
host = record["proxyEndpoint"].removeprefix("https://")
json.dump({"auths": {host: {"auth": record["authorizationToken"]}}}, sys.stdout)' |
  kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
    create secret generic registry-pull --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml |
  kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" apply -f -
```

ECR tokens last 12 hours. Refresh before a deployment if needed, and arrange
automated renewal with a suitable pull identity or a provider-supported registry
mirror before unattended operation. A running pod can remain healthy after
credentials expire while a later image pull fails.
[AWS ECR authentication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html)

For another registry, use its issued pull credentials to create the same Secret.
The Secret must exist in the workload namespace and match the registry in
`images.yaml`.
[Kubernetes image pull secrets](https://kubernetes.io/docs/concepts/containers/images/#specifying-imagepullsecrets-on-a-pod)

## 4 Create application and model credentials

Run application credential creation once. Its destination directory must not
already exist. The helper creates TLS and separate inference, admin and worker
pressure tokens. It reserves identities for both groups, so adding their second
replicas later needs no token rotation.

```bash
python3 "$ARANYA_BUNDLE/cell.py" credentials \
  --kubeconfig "$ARANYA_KUBECONFIG" \
  --namespace "$ARANYA_NAMESPACE" --release "$ARANYA_RELEASE" \
  --credentials-dir "$ARANYA_WORKDIR/credentials" \
  --worker-group a --worker-group b
```

Retain the private credential record securely. Certificates expire after 90 days;
schedule explicit rotation and a workload rollout before expiry. On repeat
deployments, reuse the existing record and Secrets. The helper deliberately
refuses to overwrite them.

For gated model downloads, place the Hugging Face token in
`$ARANYA_WORKDIR/hf.token`, then create the model Secret and set
`model.hfSecretName: hf-download` in `provider.yaml`. Skip this command for public
downloads and leave `hfSecretName` empty.

```bash
kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  create secret generic hf-download \
  --from-file=token="$ARANYA_WORKDIR/hf.token" --dry-run=client -o yaml |
  kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" apply -f -
```

## 5 Stage both pinned models

Render and review the first installation. Use the same ordered values files in
every Helm command, with `images.yaml` last. The `kubectl apply` commands above
manage Secrets; Helm owns the application release.

```bash
helm lint "$ARANYA_BUNDLE/chart" \
  -f "$ARANYA_WORKDIR/provider.yaml" -f "$ARANYA_BUNDLE/images.yaml" \
  --set staging.enabled=true,workers.enabled=false
helm template "$ARANYA_RELEASE" "$ARANYA_BUNDLE/chart" \
  --namespace "$ARANYA_NAMESPACE" \
  -f "$ARANYA_WORKDIR/provider.yaml" -f "$ARANYA_BUNDLE/images.yaml" \
  --set staging.enabled=true,workers.enabled=false \
  > "$ARANYA_WORKDIR/staging-rendered.yaml"
helm upgrade --install "$ARANYA_RELEASE" "$ARANYA_BUNDLE/chart" \
  --kubeconfig "$ARANYA_KUBECONFIG" --namespace "$ARANYA_NAMESPACE" \
  -f "$ARANYA_WORKDIR/provider.yaml" -f "$ARANYA_BUNDLE/images.yaml" \
  --set staging.enabled=true,workers.enabled=false \
  --wait --wait-for-jobs --timeout 120m --history-max 5
```

This creates one CPU download Job per GPU node and downloads both model revisions
into that node's claim. It starts no GPU workers. The downloader checks model
configuration and shards named by safetensors indexes. Confirm both Jobs finish:

```bash
kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" get jobs,pvc
kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  logs "job/$ARANYA_RELEASE-stage-a"
kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  logs "job/$ARANYA_RELEASE-stage-b"
```

If Aranya supplied prepopulated, verified model claims, agree on claim binding and
model subpaths with your FDE and skip downloading. For a failed download, preserve
the PVC, delete only the failed staging Job, then repeat staging for the same
revision. Use a fresh claim/directory for a different model revision.

**Staging disables workers. Run this step before first serving, never against a
live serving release.** The timeout bounds the Helm wait; model downloads may
need a longer agreed window. Inspect Job status before retrying after a timeout.

## 6 Start serving

```bash
helm lint "$ARANYA_BUNDLE/chart" \
  -f "$ARANYA_WORKDIR/provider.yaml" -f "$ARANYA_BUNDLE/images.yaml" \
  --set staging.enabled=false,workers.enabled=true
helm upgrade --install "$ARANYA_RELEASE" "$ARANYA_BUNDLE/chart" \
  --kubeconfig "$ARANYA_KUBECONFIG" --namespace "$ARANYA_NAMESPACE" \
  -f "$ARANYA_WORKDIR/provider.yaml" -f "$ARANYA_BUNDLE/images.yaml" \
  --set staging.enabled=false,workers.enabled=true \
  --wait --wait-for-jobs --timeout 120m --history-max 5
python3 "$ARANYA_BUNDLE/cell.py" status \
  --kubeconfig "$ARANYA_KUBECONFIG" \
  --namespace "$ARANYA_NAMESPACE" --release "$ARANYA_RELEASE"
```

Expect the frontend, application etcd and two worker pods to become ready. Each
worker pod contains a GPU worker and a CPU sidecar. First initialization includes
model loading and compilation; the prior single-worker GCP rehearsal took about
30 minutes. That is planning context, not a startup guarantee for Aranya.

## 7 Verify before connecting traffic

In another terminal, forward the frontend locally using the same namespace and
release values. This command stays running:

```bash
kubectl --kubeconfig /path/to/aranya/kubeconfig -n inference \
  port-forward service/glm-frontend 19513:19513 --address 127.0.0.1
```

Back in the original shell, run the probe, which prints results to the terminal:

```bash
python3 "$ARANYA_BUNDLE/probe.py" \
  --credentials-dir "$ARANYA_WORKDIR/credentials" --model glm-5.3 \
  --sources "$ARANYA_RELEASE-worker-a-0" "$ARANYA_RELEASE-worker-b-0" \
  --concurrency 2
```

Require valid TLS, rejection of an invalid token, two ready workers, fresh L1/L2
pressure for both sources, and completed 32-token inference streams. Verify with
Aranya that each worker received four exclusive physical B200s. Pressure rank
counts describe data-parallel ranks; they are not a count of TP4 GPUs.

Check worker memory, restarts and events before increasing load. The probe checks
discovery for every source, but ordinary routed requests do not prove that every
replica generated tokens; use per-worker metrics/logs for that confirmation.

To use all sixteen GPUs, change **both** `replicas: 1` entries to `replicas: 2`
in `provider.yaml`, confirm per-node resources and namespace quotas fit, and rerun
the serving command. Two workers consume up to 2,000 GiB of worker memory per
node, plus sidecars and any frontend/etcd services. Then verify all four sources:

```bash
python3 "$ARANYA_BUNDLE/probe.py" \
  --credentials-dir "$ARANYA_WORKDIR/credentials" --model glm-5.3 \
  --sources "$ARANYA_RELEASE-worker-a-0" "$ARANYA_RELEASE-worker-a-1" \
    "$ARANYA_RELEASE-worker-b-0" "$ARANYA_RELEASE-worker-b-1" \
  --concurrency 4
```

Repeat with `--concurrency 64` for a bounded c64 smoke test. These checks establish
basic operation; a sustained workload test establishes throughput and latency.

## 8 Connect the gateway

The chart exposes an internal ClusterIP frontend. Agree with Aranya and your FDE
on a private route or ingress and permit its actual source addresses in
`networkPolicy.frontendIngressCidrs`. Configure the gateway with the `glm-5.3`
model, the data-plane token and the appropriate CA trust.

The generated frontend certificate covers service DNS names and localhost. An
external hostname needs matching TLS at the ingress or an explicitly managed
frontend certificate. Keep TLS verification and Bearer authentication enabled.
Verify inference through the gateway before admitting user traffic.

## Updates and recovery

Pushing Git or publishing an image does not deploy it. Select a qualified release
folder and point `ARANYA_BUNDLE` at it. Drain affected traffic, review the new
image digests and your private provider values, then rerun the serving
`helm upgrade --install` command with both flags explicit.
Refresh registry credentials and rerun the probe after the rollout.

```bash
helm --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  history "$ARANYA_RELEASE"
```

To roll back, select a successful **serving** revision from that history. Replace
the revision placeholder below. A successful staging revision has no workers.

```bash
helm --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  rollback "$ARANYA_RELEASE" REPLACE_SERVING_REVISION \
  --wait --wait-for-jobs --timeout 120m
```

Model and application-etcd claims are retained on uninstall. Helm rollback does
not restore their contents. Keep the required model revisions, image references
and protected credentials available for recovery. Local disks are not replicated
or backed up by this deployment. The single frontend and local application etcd
also mean application availability depends on their node; a redundant Kubernetes
control plane does not provide application failover.

## Troubleshooting

| Symptom | First check |
| --- | --- |
| `ImagePullBackOff` | Secret namespace, repository permissions, ECR token age and registry/layer-storage egress. |
| PVC stays pending | Local PV capacity, StorageClass binding mode and matching node affinity; wait for its consumer to be scheduled. |
| Worker stays pending | Exclusive GPU quota, node selector/taints, CPU/RAM budget, runtime class and namespace LimitRange. |
| Startup memory or memlock error | Provider runtime limits and allocatable RAM; reduce replicas or HiCache after measuring rather than granting pod privileges. |
| Download Job fails | Repository access, exact model revision, disk space and egress; inspect that Job's logs before retrying. |
| Probe sees stale/missing workers | Worker/sidecar logs, application etcd connectivity and per-worker pressure credentials. |
| TLS verification fails | Use the supplied CA and a certificate-covered hostname; check certificate expiry. |

```bash
kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  get pods,pvc,jobs -o wide
kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  get events --sort-by=.metadata.creationTimestamp
kubectl --kubeconfig "$ARANYA_KUBECONFIG" -n "$ARANYA_NAMESPACE" \
  logs "$ARANYA_RELEASE-worker-a-0" -c worker --tail=100
```
