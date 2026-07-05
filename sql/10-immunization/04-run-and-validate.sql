-- Run and validate the immunization reporting layer.
--
-- Step 1: Refresh administered facts (incremental, reads from questionnaire_response).
-- Step 2: Refresh status for the current and previous month.
-- Step 3: Validate results with the queries below.

-- ============================================================================
-- Step 1: Refresh administered immunization facts
-- ============================================================================

CALL dwh.refresh_immunization_facts();

-- ============================================================================
-- Step 2: Refresh immunization status (current + previous month)
-- ============================================================================

CALL dwh.refresh_immunization_status_current_and_previous_month();

-- To refresh a specific month manually:
-- CALL dwh.refresh_immunization_status(
--     date_trunc('month', current_date)::date,
--     (date_trunc('month', current_date) + INTERVAL '1 month')::date
-- );

-- To refresh a past month manually:
-- CALL dwh.refresh_immunization_status(
--     (date_trunc('month', current_date) - INTERVAL '1 month')::date,
--     date_trunc('month', current_date)::date
-- );

-- ============================================================================
-- Step 3: Validation
-- ============================================================================

-- Check refresh state for immunization procedures.
SELECT *
FROM dwh.refresh_state
WHERE table_name LIKE 'dwh.immunization%'
ORDER BY last_run_started_at DESC;

-- Check vaccine reference map row count by programme.
SELECT
    programme,
    COUNT(*) AS doses
FROM dwh.ref_immunization_vaccine_map
GROUP BY programme
ORDER BY programme;

-- Check administered facts by source form and programme.
SELECT
    source_form,
    programme,
    antigen_group,
    dose_label,
    COUNT(*) AS records
FROM dwh.fact_immunizations
GROUP BY source_form, programme, antigen_group, dose_label
ORDER BY source_form, programme, antigen_group, dose_label;

-- Check status table row counts by period and programme.
SELECT
    reporting_period_start,
    reporting_period_end,
    programme,
    COUNT(*) AS rows
FROM dwh.fact_immunization_status
GROUP BY reporting_period_start, reporting_period_end, programme
ORDER BY reporting_period_start DESC, programme;

-- Quick coverage summary for the current month.
SELECT
    programme,
    antigen_group,
    dose_label,
    COUNT(*) FILTER (WHERE is_due)                              AS due,
    COUNT(*) FILTER (WHERE is_due AND is_received)             AS received,
    COUNT(*) FILTER (WHERE is_due AND NOT is_received)         AS missing,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_due AND is_received)
        / NULLIF(COUNT(*) FILTER (WHERE is_due), 0),
        1
    )                                                           AS coverage_pct
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
GROUP BY programme, antigen_group, dose_label, dose_number
ORDER BY programme, antigen_group, dose_number;
