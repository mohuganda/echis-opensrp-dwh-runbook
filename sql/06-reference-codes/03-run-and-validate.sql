CALL dwh.refresh_code_reference_tables();

SELECT *
FROM dwh.refresh_state
WHERE table_name = 'dwh.code_reference_tables';

SELECT * FROM dwh.ref_observation_codes ORDER BY usage_count DESC LIMIT 100;
SELECT * FROM dwh.ref_condition_codes ORDER BY usage_count DESC LIMIT 100;
SELECT * FROM dwh.ref_flag_codes ORDER BY usage_count DESC LIMIT 100;
