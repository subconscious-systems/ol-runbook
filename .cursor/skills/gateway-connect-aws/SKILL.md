---
name: gateway-connect-aws
description: >-
  SSM onto the AWS API Gateway docker-agent host and run one-shot RDS SQL
  without printing secrets. Use when laptop kubectl or psql cannot reach the
  cluster, you need a shell on the bootstrap EC2, or you need to query gateway
  Postgres. AWS Assisted Self-Managed only. Slash-style: /gateway-connect-aws.
---

# Gateway connect (AWS)

The EKS API and RDS are private. Day-0 cluster access is CIDR-locked to the
bootstrap EC2. Use `connect.sh` from this runbook; do not print Secrets Manager
values or the database URL.

## Do

From `api-gateway/aws/bootstrap`:

```bash
export AWS_REGION=<your-region>
./scripts/connect.sh help
./scripts/connect.sh env <INFRA_DEPLOY_NAME>
./scripts/connect.sh shell <INFRA_DEPLOY_NAME>
./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> --file scripts/sql/usage-lag.sql
./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> --file path/to/query.sql
```

- `INFRA_DEPLOY_NAME` is the Distr Docker / Terraform name (EKS cluster name).
- `--ns` is the gateway Helm namespace (`GATEWAY_DISTR_DEPLOYMENT_NAME`). It is
  required for `sql`; do not guess it from the infra name.
- `help` lists laptop and host requirements (AWS CLI, `AWS_REGION`, SSM plugin
  for `shell`, Secret `gateway-secrets` in `--ns` for `sql`).
- `env` finds the docker-agent instance `Name=<INFRA_DEPLOY_NAME>-docker-agent`.
- After `shell`, on the box: `sudo -i` then
  `export HOME=/root KUBECONFIG=/root/.kube/config`.

`scripts/sql/usage-lag.sql` compares live gateway usage to exported
`usage.recorded` events and webhook delivery status. The file header explains
how to read the result.

## Never

- Print `SecretString`, paste connection URLs into chat, or echo
  `$SUBCONSCIOUS_GATEWAY_DATABASE_URL`.
- Run `./scripts/bootstrap.sh` against a live deploy.
- `kubectl exec` into a gateway pod expecting a shell (distroless images).
- Apply schema changes (`CREATE INDEX`, and similar) from this host; those land
  with the gateway release.

If a database password was printed, rotate it (`api-gateway/aws/secret-rotation.md`).

## Read next

- `api-gateway/aws/troubleshooting.md`
- `api-gateway/aws/bootstrap/README.md`
- `api-gateway/aws/bootstrap/scripts/connect.sh`
