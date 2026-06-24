CALL dwh.refresh_supply_cebs_reporting();

SELECT
    table_name,
    status,
    rows_processed,
    last_successful_airbyte_extracted_at,
    last_run_started_at,
    last_run_completed_at,
    error_message
FROM dwh.refresh_state
WHERE table_name = 'dwh.supply_cebs_reporting';

SELECT observation_id, COUNT(*)
FROM dwh.fact_commodity_stock_movements
GROUP BY observation_id
HAVING COUNT(*) > 1;

SELECT flag_id, COUNT(*)
FROM dwh.fact_commodity_stockout_periods
GROUP BY flag_id
HAVING COUNT(*) > 1;

SELECT observation_id, component_index, COUNT(*)
FROM dwh.fact_cebs_observation_components
GROUP BY observation_id, component_index
HAVING COUNT(*) > 1;

SELECT observation_id, COUNT(*)
FROM dwh.fact_cebs_observations
GROUP BY observation_id
HAVING COUNT(*) > 1;

SELECT
    commodity_name,
    COUNT(*) AS records,
    COUNT(running_balance) AS records_with_balance
FROM dwh.dim_current_commodity_stock
GROUP BY commodity_name
ORDER BY commodity_name;

SELECT
    cebs_status_label,
    reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
GROUP BY cebs_status_label, reviewed_signal_label
ORDER BY total DESC;
