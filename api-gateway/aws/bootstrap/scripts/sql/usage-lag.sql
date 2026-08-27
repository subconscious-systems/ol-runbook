-- Export / webhook lag tips for Orangeline gateway RDS.
--
-- Compare live ingest (gateway_usage_events) to the latest delivered
-- usage.recorded webhook and delivery health. New usage is dual-written to
-- gateway_export_events and gateway_webhook_deliveries at insert time. A previous
-- gateway binary can still claim by joining the journal. Historical gaps are
-- filled by a one-shot catch-up after deploy, not by a 1s journal copier.
-- Lag gauges can stay high until that drain POSTs.
--
-- gateway_export_events remains until a later release drops it. Do not
-- grep NOT EXISTS / gateway_export_events as the hot query.
--
-- Run:
--   ./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> \
--     --file scripts/sql/usage-lag.sql
--
-- Read:
--   usage_received_at far ahead of latest delivered usage, deliveries all
--   delivered/200  → delivery worker lag, not missing POSTs
--   pending / failed / dead_letter → webhook worker or /api/gateway-events
--   gateway_webhook_usage_catchup.done_at is null → catch-up still draining

SELECT max(received_at) AS usage_received_at
FROM gateway_usage_events;

SELECT u.received_at AS latest_delivered_usage_at, d.export_sequence, d.status
FROM gateway_webhook_deliveries d
JOIN gateway_export_events e
  ON e.export_sequence = d.export_sequence
 AND e.event_type = 'usage.recorded'
JOIN gateway_usage_events u
  ON u.idempotency_key = COALESCE(d.usage_idempotency_key, e.resource_id)
WHERE d.status = 'delivered'
ORDER BY d.export_sequence DESC
LIMIT 1;

SELECT status, last_status_code, count(*) AS n
FROM gateway_webhook_deliveries
GROUP BY 1, 2
ORDER BY 1, 2;

SELECT d.export_sequence, d.status, d.usage_idempotency_key, d.updated_at
FROM gateway_webhook_deliveries d
ORDER BY d.export_sequence DESC
LIMIT 8;

SELECT received_at AS catchup_watermark, done_at
FROM gateway_webhook_usage_catchup
WHERE id;
