-- Optional: if facts are already fully loaded and validated, seed the watermark before first incremental run.
-- Otherwise, leave it null and the first run will perform a full initial load.

-- CALL dwh.refresh_program_facts_base();

CALL dwh.refresh_program_facts_base();

SELECT
    table_name,
    status,
    rows_processed,
    last_successful_airbyte_extracted_at,
    last_run_started_at,
    last_run_completed_at,
    error_message
FROM dwh.refresh_state
WHERE table_name = 'dwh.program_facts_base';

SELECT 'fact_encounters' AS table_name, COUNT(*) AS total FROM dwh.fact_encounters
UNION ALL
SELECT 'fact_conditions', COUNT(*) FROM dwh.fact_conditions
UNION ALL
SELECT 'fact_flags', COUNT(*) FROM dwh.fact_flags
UNION ALL
SELECT 'fact_observations', COUNT(*) FROM dwh.fact_observations
UNION ALL
SELECT 'fact_observation_components', COUNT(*) FROM dwh.fact_observation_components;

SELECT observation_id, COUNT(*)
FROM dwh.fact_observations
GROUP BY observation_id
HAVING COUNT(*) > 1;

SELECT observation_id, component_index, COUNT(*)
FROM dwh.fact_observation_components
GROUP BY observation_id, component_index
HAVING COUNT(*) > 1;

WITH recent_source AS (
    SELECT resource ->> 'id' AS observation_id
    FROM airbyte.observation
    WHERE _airbyte_extracted_at >= now() - INTERVAL '2 days'
)
SELECT
    COUNT(*) AS recent_source_observations,
    COUNT(fo.observation_id) AS found_in_dwh,
    COUNT(*) - COUNT(fo.observation_id) AS missing_in_dwh
FROM recent_source rs
LEFT JOIN dwh.fact_observations fo
    ON fo.observation_id = rs.observation_id;
