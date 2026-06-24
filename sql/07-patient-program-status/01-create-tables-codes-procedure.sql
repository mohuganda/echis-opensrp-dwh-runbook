CREATE TABLE IF NOT EXISTS dwh.ref_patient_program_codes (
    program_key text,
    source_resource_type text,
    system text,
    code text,
    display text,
    code_text text,
    include_in_status boolean DEFAULT true,
    notes text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    PRIMARY KEY (program_key, source_resource_type, code)
);

INSERT INTO dwh.ref_patient_program_codes (program_key, source_resource_type, system, code, display, code_text, include_in_status, notes)
VALUES
    ('visitor', 'Flag', 'http://smartregister.org/', 'visitor', NULL, 'Visitor', true, 'Visitor flag'),
    ('hiv', 'Condition', 'http://snomed.info/sct', '165816005', NULL, NULL, true, 'HIV condition'),
    ('family_planning', 'Condition', 'http://snomed.info/sct', '408969000', 'Family Planning', 'Family Planning', true, 'Family Planning condition'),
    ('anc', 'Condition', 'http://snomed.info/sct', '77386006', NULL, 'Pregnant', true, 'Pregnancy / ANC condition'),
    ('pnc', 'Condition', 'http://snomed.info/sct', '133906008', NULL, 'PNC', true, 'PNC condition'),
    ('sick_child', 'Condition', 'http://snomed.info/sct', '275142008', 'Sick Child', 'Sick Child', true, 'Sick child condition'),
    ('tb', 'Condition', 'http://snomed.info/sct', '371569005', NULL, 'TB Condition', true, 'TB condition')
ON CONFLICT (program_key, source_resource_type, code)
DO UPDATE SET
    system = EXCLUDED.system,
    display = EXCLUDED.display,
    code_text = EXCLUDED.code_text,
    include_in_status = EXCLUDED.include_in_status,
    notes = EXCLUDED.notes,
    updated_at = now();

CREATE TABLE IF NOT EXISTS dwh.dim_patient_program_status (
    patient_id text PRIMARY KEY,
    is_current_visitor boolean DEFAULT false,
    has_hiv_condition boolean DEFAULT false,
    has_tb_condition boolean DEFAULT false,
    is_under_fp boolean DEFAULT false,
    is_anc_client boolean DEFAULT false,
    is_pnc_client boolean DEFAULT false,
    is_sick_child boolean DEFAULT false,
    last_visitor_flag_start_date date,
    last_hiv_recorded_date date,
    last_tb_recorded_date date,
    last_fp_recorded_date date,
    last_anc_recorded_date date,
    last_pnc_recorded_date date,
    last_sick_child_recorded_date date,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE OR REPLACE PROCEDURE dwh.refresh_patient_program_status()
LANGUAGE plpgsql
AS $proc$
BEGIN
    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES ('dwh.patient_program_status', clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET last_run_started_at = EXCLUDED.last_run_started_at, status = 'running', error_message = NULL;

    DELETE FROM dwh.dim_patient_program_status;

    INSERT INTO dwh.dim_patient_program_status (
        patient_id,
        is_current_visitor,
        has_hiv_condition,
        has_tb_condition,
        is_under_fp,
        is_anc_client,
        is_pnc_client,
        is_sick_child,
        last_visitor_flag_start_date,
        last_hiv_recorded_date,
        last_tb_recorded_date,
        last_fp_recorded_date,
        last_anc_recorded_date,
        last_pnc_recorded_date,
        last_sick_child_recorded_date,
        dwh_updated_at
    )
    SELECT
        p.patient_id,
        COALESCE(MAX((f.flag_status = 'active')::int) FILTER (WHERE pc.program_key = 'visitor'), 0) = 1 AS is_current_visitor,
        COALESCE(MAX((c.is_active_condition)::int) FILTER (WHERE pc.program_key = 'hiv'), 0) = 1 AS has_hiv_condition,
        COALESCE(MAX((c.is_active_condition)::int) FILTER (WHERE pc.program_key = 'tb'), 0) = 1 AS has_tb_condition,
        COALESCE(MAX((c.is_active_condition)::int) FILTER (WHERE pc.program_key = 'family_planning'), 0) = 1 AS is_under_fp,
        COALESCE(MAX((c.is_active_condition)::int) FILTER (WHERE pc.program_key = 'anc'), 0) = 1 AS is_anc_client,
        COALESCE(MAX((c.is_active_condition)::int) FILTER (WHERE pc.program_key = 'pnc'), 0) = 1 AS is_pnc_client,
        COALESCE(MAX((c.is_active_condition)::int) FILTER (WHERE pc.program_key = 'sick_child'), 0) = 1 AS is_sick_child,
        MAX(f.period_start::date) FILTER (WHERE pc.program_key = 'visitor') AS last_visitor_flag_start_date,
        MAX(c.recorded_date::date) FILTER (WHERE pc.program_key = 'hiv') AS last_hiv_recorded_date,
        MAX(c.recorded_date::date) FILTER (WHERE pc.program_key = 'tb') AS last_tb_recorded_date,
        MAX(c.recorded_date::date) FILTER (WHERE pc.program_key = 'family_planning') AS last_fp_recorded_date,
        MAX(c.recorded_date::date) FILTER (WHERE pc.program_key = 'anc') AS last_anc_recorded_date,
        MAX(c.recorded_date::date) FILTER (WHERE pc.program_key = 'pnc') AS last_pnc_recorded_date,
        MAX(c.recorded_date::date) FILTER (WHERE pc.program_key = 'sick_child') AS last_sick_child_recorded_date,
        clock_timestamp()
    FROM dwh.dim_patients p
    LEFT JOIN dwh.fact_conditions c
        ON c.patient_id = p.patient_id
       AND c.is_active_condition = true
    LEFT JOIN dwh.ref_patient_program_codes pc
        ON pc.source_resource_type = 'Condition'
       AND pc.code = c.condition_code
       AND pc.include_in_status = true
    LEFT JOIN dwh.fact_flags f
        ON f.patient_id = p.patient_id
       AND f.flag_code = 'visitor'
    LEFT JOIN dwh.ref_patient_program_codes pcf
        ON pcf.source_resource_type = 'Flag'
       AND pcf.code = f.flag_code
       AND pcf.include_in_status = true
    GROUP BY p.patient_id;

    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'success', rows_processed = (SELECT COUNT(*) FROM dwh.dim_patient_program_status), error_message = NULL
    WHERE table_name = 'dwh.patient_program_status';
EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'failed', error_message = SQLERRM
    WHERE table_name = 'dwh.patient_program_status';
    RAISE;
END;
$proc$;
