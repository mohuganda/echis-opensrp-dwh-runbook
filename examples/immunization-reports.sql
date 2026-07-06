-- Immunization reporting examples.
--
-- Two main sources:
--
--   dwh.fact_immunization_status
--     Row-level: one row per patient × expected dose × reporting period.
--     Rolling 3-month window. Use for operational line lists and follow-up.
--     assigned_vht_name is populated from dim_practitioner_assignments.
--     assigned_vht_phone is NULL — not available in the current DWH.
--
--   dwh.agg_immunization_monthly
--     Pre-aggregated: one row per month × location level × programme × antigen × dose.
--     Kept for all history from September 2023. Use for coverage trends and DHIS2 reports.
--     location_level values: national | district | subcounty | parish | health_facility | village
--     antigen_group = 'ALL' rows carry patient-level KPIs (zero_dose_count, fic_count etc.).
--     Antigen-specific rows carry coverage metrics (due_count, received_count etc.).
--
-- How to think about fact_immunization_status:
--   one row = one patient + one expected vaccine dose + one reporting period
--
-- A single under-5 child may have many rows for a given month:
--   BCG Birth, Polio 0, DPT-HepB-Hib 1, PCV 1, ... Malaria Dose 1, Malaria Dose 2 ...
--
-- Because is_zero_dose and is_under_immunised are repeated across all dose rows for
-- a patient, always use SELECT DISTINCT patient_id when counting children.


-- ============================================================================
-- SECTION A: Operational line lists (fact_immunization_status)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Monthly coverage summary — all programmes, current month
-- ----------------------------------------------------------------------------

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


-- ----------------------------------------------------------------------------
-- Coverage by facility — current month
-- ----------------------------------------------------------------------------

SELECT
    health_facility_id,
    health_facility_name,
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
GROUP BY
    health_facility_id, health_facility_name,
    programme, antigen_group, dose_label, dose_number
ORDER BY health_facility_name, programme, antigen_group, dose_number;


-- ----------------------------------------------------------------------------
-- Coverage by district — current month
-- ----------------------------------------------------------------------------

SELECT
    district_id,
    district_name,
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
GROUP BY
    district_id, district_name,
    programme, antigen_group, dose_label, dose_number
ORDER BY district_name, programme, antigen_group, dose_number;


-- ----------------------------------------------------------------------------
-- Line list: children with missing doses — current month
-- (assigned_vht_name is populated; assigned_vht_phone is NULL — not in DWH)
-- ----------------------------------------------------------------------------

SELECT
    patient_id,
    patient_name,
    gender,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    assigned_vht_name,
    programme,
    antigen_group,
    dose_label,
    due_date,
    days_overdue,
    caregiver_phone
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_due       = true
  AND is_received  = false
ORDER BY days_overdue DESC;


-- ----------------------------------------------------------------------------
-- Under-immunized: missing antigens per child — current month
-- ----------------------------------------------------------------------------

SELECT
    patient_id,
    patient_name,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    assigned_vht_name,
    STRING_AGG(
        antigen_group || ' ' || dose_label,
        ', '
        ORDER BY programme, antigen_group, dose_number
    )                                                           AS missing_antigens,
    MAX(days_overdue)                                           AS max_days_overdue
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_due       = true
  AND is_received  = false
GROUP BY
    patient_id, patient_name,
    age_months_at_period_end,
    village_name, health_facility_name, assigned_vht_name
ORDER BY max_days_overdue DESC;


-- ----------------------------------------------------------------------------
-- Zero-dose children — current month
-- Use DISTINCT because is_zero_dose is repeated across all dose rows per child.
-- ----------------------------------------------------------------------------

SELECT DISTINCT
    patient_id,
    patient_name,
    gender,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    assigned_vht_name,
    caregiver_phone
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_zero_dose = true
ORDER BY health_facility_name, village_name, patient_name;


-- ----------------------------------------------------------------------------
-- Under-immunized children (distinct list) — current month
-- ----------------------------------------------------------------------------

SELECT DISTINCT
    patient_id,
    patient_name,
    gender,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    assigned_vht_name,
    caregiver_phone
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_under_immunised = true
ORDER BY health_facility_name, village_name, patient_name;


-- ----------------------------------------------------------------------------
-- Recovery: children who were zero-dose last month and immunized this month
-- ----------------------------------------------------------------------------

WITH last_month_zero_dose AS (
    SELECT DISTINCT patient_id
    FROM dwh.fact_immunization_status
    WHERE reporting_period_start = (date_trunc('month', current_date) - INTERVAL '1 month')::date
      AND is_zero_dose = true
),
this_month_immunized AS (
    SELECT DISTINCT
        patient_id,
        MIN(administered_date) AS first_immunization_this_month
    FROM dwh.fact_immunizations
    WHERE administered_date >= date_trunc('month', current_date)::date
      AND administered_date <  (date_trunc('month', current_date) + INTERVAL '1 month')::date
      AND programme IN ('child_immunization', 'malaria_vaccine')
    GROUP BY patient_id
)
SELECT
    p.patient_id,
    p.patient_name,
    p.gender,
    p.birth_date,
    dwh.age_in_months(p.birth_date, current_date)   AS age_months_today,
    p.village_name,
    p.health_facility_name,
    p.phone_number                                   AS caregiver_phone,
    i.first_immunization_this_month
FROM last_month_zero_dose z
JOIN this_month_immunized i  ON i.patient_id = z.patient_id
JOIN dwh.dim_patients p      ON p.patient_id = z.patient_id
ORDER BY i.first_immunization_this_month, p.health_facility_name, p.village_name;


-- ----------------------------------------------------------------------------
-- Recovery detail: which vaccine recovered each zero-dose child this month
-- ----------------------------------------------------------------------------

WITH last_month_zero_dose AS (
    SELECT DISTINCT patient_id
    FROM dwh.fact_immunization_status
    WHERE reporting_period_start = (date_trunc('month', current_date) - INTERVAL '1 month')::date
      AND is_zero_dose = true
)
SELECT
    fi.patient_id,
    p.patient_name,
    p.gender,
    p.village_name,
    p.health_facility_name,
    p.phone_number      AS caregiver_phone,
    fi.administered_date,
    fi.programme,
    fi.antigen_group,
    fi.dose_label,
    fi.vaccine_name
FROM last_month_zero_dose z
JOIN dwh.fact_immunizations fi  ON fi.patient_id = z.patient_id
JOIN dwh.dim_patients p         ON p.patient_id = z.patient_id
WHERE fi.administered_date >= date_trunc('month', current_date)::date
  AND fi.administered_date <  (date_trunc('month', current_date) + INTERVAL '1 month')::date
  AND fi.programme IN ('child_immunization', 'malaria_vaccine')
ORDER BY fi.administered_date, p.health_facility_name, p.village_name, p.patient_name;


-- ============================================================================
-- SECTION B: Historical coverage and trends (agg_immunization_monthly)
-- ============================================================================
--
-- Use these queries for Section 6 MCH Indicators, trend dashboards, and DHIS2.
-- agg_immunization_monthly is available for all months from September 2023.
-- fact_immunization_status only covers the last 3 months.


-- ----------------------------------------------------------------------------
-- Section 6 MCH Indicators: coverage by antigen for one facility, one month
-- Replace '2026-05-01' and the facility ID with the report parameters.
-- ----------------------------------------------------------------------------

SELECT
    antigen_group,
    dose_label,
    due_count,
    received_count,
    missed_count,
    COALESCE(ROUND(received_count::numeric / NULLIF(due_count, 0) * 100, 1), 0) AS coverage_pct,
    late_received_count
FROM dwh.agg_immunization_monthly
WHERE reporting_month  = '2026-05-01'
  AND location_level   = 'health_facility'
  AND health_facility_id = '<replace-with-facility-id>'
  AND programme        = 'child_immunization'
  AND antigen_group   <> 'ALL'
ORDER BY
    CASE antigen_group
        WHEN 'BCG'           THEN 1
        WHEN 'HepB 0'        THEN 2
        WHEN 'Polio'         THEN 3
        WHEN 'DPT-HepB-Hib'  THEN 4
        WHEN 'PCV'           THEN 5
        WHEN 'Rota'          THEN 6
        WHEN 'IPV'           THEN 7
        WHEN 'Measles-Rubella' THEN 8
        WHEN 'Yellow Fever'  THEN 9
        ELSE 10
    END,
    dose_label;


-- ----------------------------------------------------------------------------
-- Facility KPI summary for one month: zero-dose, FIC, under-immunized
-- These come from the antigen_group = 'ALL' summary rows.
-- ----------------------------------------------------------------------------

SELECT
    health_facility_name,
    reporting_facility_name,
    reporting_dhis2_orgunit_uid,
    programme,
    zero_dose_count,
    under_immunised_count,
    fully_immunised_count,
    fic_eligible_count,
    ROUND(fully_immunised_count::numeric / NULLIF(fic_eligible_count, 0) * 100, 1) AS fic_coverage_pct
FROM dwh.agg_immunization_monthly
WHERE reporting_month = '2026-05-01'
  AND location_level  = 'health_facility'
  AND antigen_group   = 'ALL'
  AND programme       = 'child_immunization'
ORDER BY health_facility_name;


-- ----------------------------------------------------------------------------
-- Coverage trend: DPT-HepB-Hib Dose 1 for one facility, last 12 months
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    due_count,
    received_count,
    ROUND(received_count::numeric / NULLIF(due_count, 0) * 100, 1) AS coverage_pct
FROM dwh.agg_immunization_monthly
WHERE location_level   = 'health_facility'
  AND health_facility_id = '<replace-with-facility-id>'
  AND programme        = 'child_immunization'
  AND antigen_group    = 'DPT-HepB-Hib'
  AND dose_label       = 'Dose 1'
  AND reporting_month >= date_trunc('month', current_date)::date - INTERVAL '11 months'
ORDER BY reporting_month;


-- ----------------------------------------------------------------------------
-- District summary: FIC coverage trend, all districts, last 6 months
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    district_name,
    fully_immunised_count,
    fic_eligible_count,
    ROUND(fully_immunised_count::numeric / NULLIF(fic_eligible_count, 0) * 100, 1) AS fic_coverage_pct
FROM dwh.agg_immunization_monthly
WHERE location_level = 'district'
  AND antigen_group  = 'ALL'
  AND programme      = 'child_immunization'
  AND reporting_month >= date_trunc('month', current_date)::date - INTERVAL '5 months'
ORDER BY reporting_month, district_name;


-- ----------------------------------------------------------------------------
-- Village burden: zero-dose and under-immunized per village for one month
-- Useful for planning VHT mobilization priorities.
-- ----------------------------------------------------------------------------

SELECT
    health_facility_name,
    village_name,
    zero_dose_count,
    under_immunised_count,
    fully_immunised_count
FROM dwh.agg_immunization_monthly
WHERE reporting_month = date_trunc('month', current_date)::date
  AND location_level  = 'village'
  AND antigen_group   = 'ALL'
  AND programme       = 'child_immunization'
ORDER BY zero_dose_count DESC, under_immunised_count DESC;


-- ----------------------------------------------------------------------------
-- National coverage summary: all antigens, current month
-- ----------------------------------------------------------------------------

SELECT
    antigen_group,
    dose_label,
    due_count,
    received_count,
    ROUND(received_count::numeric / NULLIF(due_count, 0) * 100, 1) AS coverage_pct
FROM dwh.agg_immunization_monthly
WHERE reporting_month = date_trunc('month', current_date)::date
  AND location_level  = 'national'
  AND programme       = 'child_immunization'
  AND antigen_group  <> 'ALL'
ORDER BY
    CASE antigen_group
        WHEN 'BCG'           THEN 1
        WHEN 'HepB 0'        THEN 2
        WHEN 'Polio'         THEN 3
        WHEN 'DPT-HepB-Hib'  THEN 4
        WHEN 'PCV'           THEN 5
        WHEN 'Rota'          THEN 6
        WHEN 'IPV'           THEN 7
        WHEN 'Measles-Rubella' THEN 8
        WHEN 'Yellow Fever'  THEN 9
        ELSE 10
    END,
    dose_label;


-- ============================================================================
-- SECTION C: BI widget queries (mv_immunization_monthly_report)
-- ============================================================================
--
-- Use these queries directly in the BI tool dashboard widgets.
-- Replace DATE '2026-06-01' with the selected month from the BI filter.
--
-- indicator_code reference:
--   IMM-ZD-OPEN    Zero-dose children still open
--   IMM-UI-OPEN    Under-immunised children still open
--   IMM-RECOVERED  Children immunized this period
--   IMM-FIC-COV    Fully immunised child (FIC) coverage %
--   IMM-COV-*      Antigen/dose coverage rows (report_section = 'coverage_by_antigen')
--
-- location_level values: national | district | subcounty | parish | health_facility | village


-- ----------------------------------------------------------------------------
-- 1. Zero-dose children still open — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    indicator_value AS zero_dose_open
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND indicator_code  = 'IMM-ZD-OPEN';


-- ----------------------------------------------------------------------------
-- 2. Under-immunised children still open — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    indicator_value AS under_immunised_open
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND indicator_code  = 'IMM-UI-OPEN';


-- ----------------------------------------------------------------------------
-- 3. Children immunized / recovered this period — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    indicator_value AS recovered_this_period
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND indicator_code  = 'IMM-RECOVERED';


-- ----------------------------------------------------------------------------
-- 4. FIC coverage — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    numerator      AS fully_immunised_children,
    denominator    AS fic_eligible_children,
    indicator_value AS fic_coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND indicator_code  = 'IMM-FIC-COV';


-- ----------------------------------------------------------------------------
-- 5. DPT1 coverage — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    received_count,
    due_count,
    indicator_value AS dpt1_coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month  = DATE '2026-06-01'
  AND location_level   = 'health_facility'
  AND report_section   = 'coverage_by_antigen'
  AND programme        = 'child_immunization'
  AND antigen_group    ILIKE 'DPT%HepB%Hib%'
  AND dose_number      = 1;


-- ----------------------------------------------------------------------------
-- 6. MR1 coverage — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    received_count,
    due_count,
    indicator_value AS mr1_coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND report_section  = 'coverage_by_antigen'
  AND antigen_group   ILIKE 'Measles%Rubella%'
  AND dose_number     = 1;


-- ----------------------------------------------------------------------------
-- 7. MR2 coverage — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    received_count,
    due_count,
    indicator_value AS mr2_coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND report_section  = 'coverage_by_antigen'
  AND antigen_group   ILIKE 'Measles%Rubella%'
  AND dose_number     = 2;


-- ----------------------------------------------------------------------------
-- 8. HPV coverage — by facility (all doses)
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    received_count,
    due_count,
    indicator_value AS hpv_coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND report_section  = 'coverage_by_antigen'
  AND programme       = 'hpv_vaccine';


-- ----------------------------------------------------------------------------
-- 9. Malaria vaccine coverage by dose — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    dose_label,
    dose_number,
    received_count,
    due_count,
    missed_count,
    indicator_value AS malaria_coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND report_section  = 'coverage_by_antigen'
  AND programme       = 'malaria_vaccine'
ORDER BY dose_number;


-- ----------------------------------------------------------------------------
-- 10. Zero-dose burden by village
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    health_facility_name,
    village_name,
    indicator_value AS zero_dose_open
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'village'
  AND indicator_code  = 'IMM-ZD-OPEN'
ORDER BY zero_dose_open DESC;


-- ----------------------------------------------------------------------------
-- 11. Under-immunised burden by village
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    health_facility_name,
    village_name,
    indicator_value AS under_immunised_open
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'village'
  AND indicator_code  = 'IMM-UI-OPEN'
ORDER BY under_immunised_open DESC;


-- ----------------------------------------------------------------------------
-- 12. Full antigen coverage table — by facility
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    programme,
    antigen_group,
    dose_label,
    dose_number,
    due_count,
    received_count,
    missed_count,
    late_received_count,
    indicator_value AS coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND report_section  = 'coverage_by_antigen'
ORDER BY programme, antigen_group, dose_number;


-- ----------------------------------------------------------------------------
-- 13. Facility monthly KPI summary (pivot)
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    location_name AS health_facility_name,
    MAX(indicator_value) FILTER (WHERE indicator_code = 'IMM-ZD-OPEN')    AS zero_dose_open,
    MAX(indicator_value) FILTER (WHERE indicator_code = 'IMM-UI-OPEN')    AS under_immunised_open,
    MAX(indicator_value) FILTER (WHERE indicator_code = 'IMM-RECOVERED')  AS recovered_this_period,
    MAX(indicator_value) FILTER (WHERE indicator_code = 'IMM-FIC-COV')    AS fic_coverage_pct
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
GROUP BY reporting_month, location_name
ORDER BY location_name;


-- ----------------------------------------------------------------------------
-- 14. Monthly trend for one indicator (example: zero-dose, all facilities)
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    SUM(indicator_value) AS zero_dose_open
FROM dwh.mv_immunization_monthly_report
WHERE location_level = 'health_facility'
  AND indicator_code = 'IMM-ZD-OPEN'
GROUP BY reporting_month
ORDER BY reporting_month;


-- ----------------------------------------------------------------------------
-- 15. Top 20 facilities by zero-dose — one month
-- ----------------------------------------------------------------------------

SELECT
    reporting_month,
    district_name,
    subcounty_name,
    health_facility_name,
    indicator_value AS zero_dose_open
FROM dwh.mv_immunization_monthly_report
WHERE reporting_month = DATE '2026-06-01'
  AND location_level  = 'health_facility'
  AND indicator_code  = 'IMM-ZD-OPEN'
ORDER BY zero_dose_open DESC
LIMIT 20;
