-- Run and validate the immunization reporting layer.
--
-- Initial setup order:
--   01-create-tables-indexes.sql
--   02-seed-vaccine-reference-map.sql
--   03-create-refresh-procedures.sql
--   05-create-aggregate-table.sql
--   04-run-and-validate.sql  ← this file
--
-- After running 03 + 05, do the one-time historical backfill:
--   CALL dwh.refresh_immunization_monthly_aggregate_backfill('2023-09-01');
--
-- Then run the daily procedures once to populate current + previous month:
--   CALL dwh.refresh_immunization_facts();
--   CALL dwh.refresh_immunization_status_current_and_previous_month();
--
-- Step 1: Refresh administered facts (incremental).
-- Step 2: Refresh status + aggregate (current + previous month).
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

-- ============================================================================
-- Monthly aggregate table validation
-- ============================================================================

-- Row counts per period and location level.
SELECT
    reporting_month,
    location_level,
    COUNT(*) AS rows
FROM dwh.agg_immunization_monthly
GROUP BY reporting_month, location_level
ORDER BY reporting_month DESC, location_level;

-- Verify aggregate matches status table for current month at health_facility level.
-- Rows should match (both read from the same source data).
SELECT 'status_table' AS source, programme, antigen_group, dose_label,
       SUM(CASE WHEN is_due THEN 1 ELSE 0 END) AS due_count,
       SUM(CASE WHEN is_due AND is_received THEN 1 ELSE 0 END) AS received_count
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
GROUP BY programme, antigen_group, dose_label

UNION ALL

SELECT 'agg_table', programme, antigen_group, dose_label,
       SUM(due_count), SUM(received_count)
FROM dwh.agg_immunization_monthly
WHERE reporting_month = date_trunc('month', current_date)::date
  AND location_level  = 'health_facility'
  AND antigen_group  <> 'ALL'
GROUP BY programme, antigen_group, dose_label

ORDER BY source, programme, antigen_group, dose_label;

-- Check that zero_dose_count in aggregate matches status table count.
SELECT 'status_table' AS source, programme,
       COUNT(DISTINCT patient_id) AS zero_dose_patients
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_zero_dose = true
GROUP BY programme

UNION ALL

SELECT 'agg_national', programme,
       SUM(zero_dose_count)
FROM dwh.agg_immunization_monthly
WHERE reporting_month = date_trunc('month', current_date)::date
  AND location_level  = 'national'
  AND antigen_group   = 'ALL'
GROUP BY programme

ORDER BY source, programme;
