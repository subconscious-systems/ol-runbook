-- Export / webhook lag tips for Orangeline gateway RDS.
--
-- Compare live ingest (gateway_usage_events) to the latest delivered
-- usage.recorded webhook and delivery health. New usage enqueues
-- gateway_webhook_deliveries at insert time. Payload is rebuilt from
-- gateway_usage_events. Platform billing keys on event id and usage
-- idempotency_key. The journal table may still exist until a later
-- drop; do not treat a NOT EXISTS skip-scan of it as the hot query.
--
-- Run:
--   ./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> \
--     --file scripts/sql/usage-lag.sql
--
-- Read:
--   usage_received_at far ahead of latest delivered usage, deliveries all
--   delivered/200  → delivery worker lag, not missing POSTs
--   pending / failed / dead_letter → webhook worker or /api/gateway-events

SELECT max(received_at) AS usage_received_at
FROM gateway_usage_events;

SELECT u.received_at AS latest_delivered_usage_at, d.event_id, d.status
FROM gateway_webhook_deliveries d
JOIN gateway_usage_events u
  ON u.idempotency_key = d.usage_idempotency_key
WHERE d.status = 'delivered'
ORDER BY d.created_at DESC, d.id DESC
LIMIT 1;

SELECT status, last_status_code, count(*) AS n
FROM gateway_webhook_deliveries
GROUP BY 1, 2
ORDER BY 1, 2;

SELECT d.id, d.status, d.usage_idempotency_key, d.event_id, d.updated_at
FROM gateway_webhook_deliveries d
ORDER BY d.created_at DESC, d.id DESC
LIMIT 8;
