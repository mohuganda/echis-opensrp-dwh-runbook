CREATE OR REPLACE PROCEDURE dwh.refresh_code_reference_tables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES ('dwh.code_reference_tables', clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET last_run_started_at = EXCLUDED.last_run_started_at, status = 'running', error_message = NULL;

    INSERT INTO dwh.ref_encounter_codes (encounter_system, encounter_code, encounter_display, encounter_text, usage_count, first_seen_at, last_seen_at, last_refreshed_at)
    SELECT type_system, type_code, MAX(type_display), MAX(type_text), COUNT(*), MIN(airbyte_extracted_at), MAX(airbyte_extracted_at), clock_timestamp()
    FROM dwh.fact_encounters
    WHERE COALESCE(type_code, type_text) IS NOT NULL
    GROUP BY type_system, type_code, type_text
    ON CONFLICT (encounter_system, encounter_code, encounter_text)
    DO UPDATE SET encounter_display = EXCLUDED.encounter_display, usage_count = EXCLUDED.usage_count,
        first_seen_at = EXCLUDED.first_seen_at, last_seen_at = EXCLUDED.last_seen_at, last_refreshed_at = clock_timestamp();

    INSERT INTO dwh.ref_condition_codes (condition_system, condition_code, condition_display, condition_text, usage_count, first_seen_at, last_seen_at, last_refreshed_at)
    SELECT condition_system, condition_code, MAX(condition_display), condition_text, COUNT(*), MIN(airbyte_extracted_at), MAX(airbyte_extracted_at), clock_timestamp()
    FROM dwh.fact_conditions
    WHERE COALESCE(condition_code, condition_text) IS NOT NULL
    GROUP BY condition_system, condition_code, condition_text
    ON CONFLICT (condition_system, condition_code, condition_text)
    DO UPDATE SET condition_display = EXCLUDED.condition_display, usage_count = EXCLUDED.usage_count,
        first_seen_at = EXCLUDED.first_seen_at, last_seen_at = EXCLUDED.last_seen_at, last_refreshed_at = clock_timestamp();

    INSERT INTO dwh.ref_flag_codes (flag_system, flag_code, flag_display, flag_text, usage_count, first_seen_at, last_seen_at, last_refreshed_at)
    SELECT flag_system, flag_code, MAX(flag_display), flag_text, COUNT(*), MIN(airbyte_extracted_at), MAX(airbyte_extracted_at), clock_timestamp()
    FROM dwh.fact_flags
    WHERE COALESCE(flag_code, flag_text) IS NOT NULL
    GROUP BY flag_system, flag_code, flag_text
    ON CONFLICT (flag_system, flag_code, flag_text)
    DO UPDATE SET flag_display = EXCLUDED.flag_display, usage_count = EXCLUDED.usage_count,
        first_seen_at = EXCLUDED.first_seen_at, last_seen_at = EXCLUDED.last_seen_at, last_refreshed_at = clock_timestamp();

    INSERT INTO dwh.ref_observation_codes (category_1_system, category_1_code, observation_system, observation_code, observation_display, observation_text, usage_count, first_seen_at, last_seen_at, last_refreshed_at)
    SELECT category_1_system, category_1_code, observation_system, observation_code, MAX(observation_display), observation_text,
        COUNT(*), MIN(airbyte_extracted_at), MAX(airbyte_extracted_at), clock_timestamp()
    FROM dwh.fact_observations
    WHERE COALESCE(observation_code, observation_text) IS NOT NULL
    GROUP BY category_1_system, category_1_code, observation_system, observation_code, observation_text
    ON CONFLICT (category_1_system, category_1_code, observation_system, observation_code, observation_text)
    DO UPDATE SET observation_display = EXCLUDED.observation_display, usage_count = EXCLUDED.usage_count,
        first_seen_at = EXCLUDED.first_seen_at, last_seen_at = EXCLUDED.last_seen_at, last_refreshed_at = clock_timestamp();

    INSERT INTO dwh.ref_observation_component_codes (component_system, component_code, component_display, component_text, usage_count, last_refreshed_at)
    SELECT component_system, component_code, MAX(component_display), component_text, COUNT(*), clock_timestamp()
    FROM dwh.fact_observation_components
    WHERE COALESCE(component_code, component_text) IS NOT NULL
    GROUP BY component_system, component_code, component_text
    ON CONFLICT (component_system, component_code, component_text)
    DO UPDATE SET component_display = EXCLUDED.component_display, usage_count = EXCLUDED.usage_count, last_refreshed_at = clock_timestamp();

    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'success', error_message = NULL
    WHERE table_name = 'dwh.code_reference_tables';
EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'failed', error_message = SQLERRM
    WHERE table_name = 'dwh.code_reference_tables';
    RAISE;
END;
$$;
