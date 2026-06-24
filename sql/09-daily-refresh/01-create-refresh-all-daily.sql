CREATE OR REPLACE PROCEDURE dwh.refresh_all_daily()
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name text := 'dwh.refresh_all_daily';
    v_lock_acquired boolean := false;
BEGIN
    v_lock_acquired := pg_try_advisory_lock(hashtext(v_table_name));

    IF NOT v_lock_acquired THEN
        RAISE NOTICE 'Daily DWH refresh already running. Skipping.';
        RETURN;
    END IF;

    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES (v_table_name, clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET last_run_started_at = EXCLUDED.last_run_started_at, status = 'running', error_message = NULL;

    CALL dwh.refresh_locations();
    CALL dwh.refresh_admin_dimensions();
    CALL dwh.refresh_client_dimensions();
    CALL dwh.refresh_program_facts_base();
    CALL dwh.refresh_patient_program_status();
    CALL dwh.refresh_supply_cebs_reporting();

    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'success', error_message = NULL
    WHERE table_name = v_table_name;

    PERFORM pg_advisory_unlock(hashtext(v_table_name));
EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'failed', error_message = SQLERRM
    WHERE table_name = v_table_name;

    IF v_lock_acquired THEN
        PERFORM pg_advisory_unlock(hashtext(v_table_name));
    END IF;

    RAISE;
END;
$$;
