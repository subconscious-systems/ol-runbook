# Secret rotation (GCP)

Day-2 rotation for the GCP API Gateway. All production rotations require an
approved change window, a reviewed saved plan or procedure, current
backups/PITR, and an identified rollback owner.

Secret layout: [gateway-secrets.md](gateway-secrets.md). Break-glass access:
[bootstrap/](bootstrap/). Troubleshooting:
[troubleshooting.md](troubleshooting.md).

## General safety rules

- Do not read or paste secret payloads into a terminal transcript, ticket,
  Distr environment, or this repository.
- Never create a service-account key for rotation.
- Change one credential class at a time; keep gateway auto-deploy and unrelated
  upgrades off.
- Record Secret Manager version numbers and rollout timestamps, not values.
- Disable an old Secret Manager version before considering destruction.
  Destruction is permanent; use a delayed-destruction policy that matches the
  customer's recovery policy.
- Run `/healthz`, `/readyz`, dashboard login, org-key auth, and dependency
  checks before and after.

## CSRF and credential-encryption keys

The app bundle supports dual active/previous values. Use only a GCP-enabled
runner release whose notes explicitly support Secret Manager rotation.

From `api-gateway/gcp/bootstrap`:

```bash
bash scripts/rotate-app-secret.sh csrf \
  <PROD_INFRA_DEPLOY_NAME> <PROD_GATEWAY_DEPLOY_NAME>

bash scripts/rotate-app-secret.sh encryption \
  <PROD_INFRA_DEPLOY_NAME> <PROD_GATEWAY_DEPLOY_NAME>
```

The wrapper:

1. connects to the private bootstrap VM with IAP/OS Login;
2. refreshes GKE credentials with the IAM-protected DNS endpoint;
3. discovers or uses the pinned entitled runner image;
4. runs `rotate-gateway-app-secret.sh` with `CLOUD=gcp`;
5. writes a new `app` Secret Manager version and waits for ESO/rollout;
6. retains `_PREVIOUS` during the CSRF grace or credential re-encryption.

| Mode | Required result |
| --- | --- |
| `csrf` | New sessions use the active key; existing sessions survive the grace; `_PREVIOUS` is cleared only after the configured wait |
| `encryption` | One-off credential re-encryption completes; existing org/provider credentials still work; `_PREVIOUS` remains if the Job fails |

Optional controls are `CLEAR_PREVIOUS`, `SKIP_GRACE_SLEEP`, `RUN_REENCRYPT`,
and `RUNNER_IMAGE`. Do not skip grace or re-encryption in production merely to
shorten the window.

Verify:

```bash
kubectl -n "$GATEWAY_NAMESPACE" get externalsecret
kubectl -n "$GATEWAY_NAMESPACE" get job gateway-reencrypt-credentials
kubectl -n "$GATEWAY_NAMESPACE" logs job/gateway-reencrypt-credentials
```

Do not print `gateway-secrets`. For encryption, test a credential that existed
before rotation. If re-encryption fails, leave `_PREVIOUS` active, fix the Job,
and rerun the approved procedure.

## Cloud SQL application credential

Cloud SQL does not provide an automatic zero-downtime application-password
rotation for this connection URL. Use two database users so old and new
credentials can overlap:

1. Confirm PITR and a recent backup; record active connections and error rate.
2. Through a reviewed infra release, create a new least-privilege gateway
   database user with the same grants. Generate its password in automation.
3. Write a new `rds` bundle version containing the new private encrypted URL.
   Never expose the URL in plan/log output.
4. Wait for ESO to report Ready.
5. Roll gateway, router/adapter components that consume the URL, and migration
   Jobs in a controlled order. Ensure at least one replica remains ready.
6. Verify old data, migrations, dashboard login, `/readyz`, org API auth, and
   request traffic.
7. Observe for the agreed grace period, then revoke/drop the old database user.
8. Disable the old Secret Manager version; destroy only after the recovery
   retention period.

If the released infra path only changes a single user's password in place, it
is disruptive because existing/reconnecting pools can fail before pods consume
the new Secret. Schedule downtime or extend the release to support overlap; do
not hand-edit Kubernetes Secrets.

Cloud SQL server certificates and Google-managed infrastructure credentials
have separate lifecycles. Follow Google maintenance guidance; they are not the
gateway database-user rotation above.

## Memorystore Redis AUTH

Memorystore changes its AUTH string by disabling and re-enabling AUTH. That
temporarily removes authentication and does not support old/new AUTH overlap.
Do **not** toggle AUTH on the active production instance.

Use a blue/green cache replacement:

1. Confirm the gateway can tolerate an empty cache and record limiter/session
   implications.
2. Through the reviewed infra release, create a second Redis 7
   `STANDARD_HA` instance with AUTH and
   `SERVER_AUTHENTICATION` TLS enabled from creation.
3. Prove TLS trust/private connectivity from a disposable in-cluster client
   without logging the AUTH string.
4. Publish a new `valkey` bundle version with the new `rediss://` URL.
5. Wait for ESO, then roll Redis consumers in a controlled order.
6. Verify `/readyz`, login/session behavior, rate limits, and error/latency
   dashboards.
7. Keep the old instance isolated but available for the agreed rollback grace.
8. Disable the old secret version and delete the old instance only after
   approval.

Redis is used for ephemeral coordination/cache behavior, not as the system of
record. Do not introduce an unreviewed data-copy procedure. If business
behavior relies on persistence, stop and design that migration separately.

## Dashboard bootstrap password and OIDC secret

The identity-bootstrap Job is idempotent and does not rotate an existing
dashboard user's password. Rotate the bootstrap/break-glass account through the
supported identity administration flow, then update/remove the Hub bootstrap
secret so a future Job does not carry a stale value.

For OIDC:

1. Create a second client secret at the identity provider when overlap is
   supported.
2. Update the masked environment-specific Hub Secret.
3. Trigger an infra run to merge the value into the app bundle and wait for ESO.
4. Roll gateway pods and test SSO plus password break-glass.
5. Revoke the old provider secret after the grace period.

If the provider allows only one client secret, schedule a short authentication
window and keep an existing password-admin session available.

## Org API keys

Org API keys live in the gateway database, not Secret Manager:

1. Create a new key in the dashboard/API.
2. Update clients without logging it.
3. Observe both keys during the grace period.
4. Revoke the old key.
5. Verify expected requests succeed and the old key is rejected.

## Provider/worker endpoint keys

Per-endpoint provider bearers also live in the gateway database. Create a new
key, update the already managed provider/worker endpoint, verify traffic, then
revoke the old key. GPU provisioning and worker deployment are not part of this
GCP gateway runbook.

## Rollback

- App key: restore the prior app bundle version only while its corresponding
  `_PREVIOUS` and ciphertext state are understood. Prefer fixing forward.
- Cloud SQL: point the `rds` bundle back to the still-valid old user, wait for
  ESO, and roll pods.
- Redis: point the `valkey` bundle back to the retained old instance, wait for
  ESO, and roll consumers.
- OIDC: restore the still-valid old provider secret and roll gateway pods.

After any rollback, leave both cloud resources/secret versions intact, collect
evidence, and stop further rotation work until the incident owner approves.
