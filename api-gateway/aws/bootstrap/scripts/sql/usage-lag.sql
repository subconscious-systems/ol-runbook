-- Export / webhook lag tips for Orangeline gateway RDS.
--
-- Compare live ingest (gateway_usage_events) to delivery health. New usage
-- enqueues gateway_webhook_deliveries at insert time. Payload is rebuilt from
-- gateway_usage_events as usage.recorded. Do not treat a NOT EXISTS skip-scan
-- of the journal as the hot query; that copier is gone.
--
-- Run:
--   ./scripts/connect.sh sql <INFRA_DEPLOY_NAME> --ns <GATEWAY_NS> \
--     --file scripts/sql/usage-lag.sql
--
-- Read:
--   pending / failed / dead_letter → webhook worker or /api/gateway-events

SELECT max(received_at) AS usage_received_at
FROM gateway_usage_events;

SELECT status, last_status_code, count(*) AS n
FROM gateway_webhook_deliveries
GROUP BY 1, 2
ORDER BY 1, 2;
