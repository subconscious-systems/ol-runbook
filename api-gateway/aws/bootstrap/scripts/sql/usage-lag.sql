-- Export / webhook lag tips for Orangeline gateway RDS.
--
-- Compare live ingest (gateway_usage_events) to the usage.recorded export tip
-- and webhook delivery health. Platform usage only moves through that tip.
--
-- Run:
--   ./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> \
--     --file scripts/sql/usage-lag.sql
--
-- Read:
--   usage_received_at far ahead of usage_recorded_occurred_at, deliveries all
--   delivered/200  → publisher lag, not missing POSTs
--   pending / failed / dead_letter → webhook worker or /api/gateway-events

SELECT max(received_at) AS usage_received_at
FROM gateway_usage_events;

SELECT occurred_at AS usage_recorded_occurred_at, export_sequence
FROM gateway_export_events
WHERE event_type = 'usage.recorded'
ORDER BY export_sequence DESC
LIMIT 1;

SELECT status, last_status_code, count(*) AS n
FROM gateway_webhook_deliveries
GROUP BY 1, 2
ORDER BY 1, 2;

SELECT event_type, occurred_at, export_sequence
FROM gateway_export_events
ORDER BY export_sequence DESC
LIMIT 8;
