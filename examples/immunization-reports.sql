-- Immunization reporting examples.
--
-- These queries read from dwh.fact_immunization_status and dwh.fact_immunizations.
--
-- How to think about fact_immunization_status:
--   one row = one patient + one expected vaccine dose + one reporting period
--
-- A single under-5 child may have many rows for a given month:
--   BCG Birth, Polio 0, DPT-HepB-Hib 1, PCV 1, ... Malaria Dose 1, Malaria Dose 2 ...
--
-- Each row answers:
--   Was this child eligible for this dose?
--   Was the dose due by the end of this period?
--   Was it received before period end?
--   If missing, how overdue is it?
--   If received during this month, is it a recovery?
--
-- Because is_zero_dose and is_under_immunised are repeated across all dose rows for
-- a patient, always use SELECT DISTINCT patient_id when counting children.


-- ============================================================================
-- Monthly coverage summary (all programmes)
-- ============================================================================

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
-- Coverage by facility — current month
-- ============================================================================

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
    health_facility_id,
    health_facility_name,
    programme,
    antigen_group,
    dose_label,
    dose_number
ORDER BY health_facility_name, programme, antigen_group, dose_number;


-- ============================================================================
-- Coverage by district — current month
-- ============================================================================

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
    district_id,
    district_name,
    programme,
    antigen_group,
    dose_label,
    dose_number
ORDER BY district_name, programme, antigen_group, dose_number;


-- ============================================================================
-- Line list of children with missing doses — current month
-- ============================================================================

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


-- ============================================================================
-- Under-immunized: missing antigens per child — current month
-- ============================================================================

SELECT
    patient_id,
    patient_name,
    age_months_at_period_end,
    village_name,
    health_facility_name,
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
    patient_id,
    patient_name,
    age_months_at_period_end,
    village_name,
    health_facility_name
ORDER BY max_days_overdue DESC;


-- ============================================================================
-- Zero-dose children — current month
-- Use DISTINCT because is_zero_dose is repeated across all dose rows per child.
-- ============================================================================

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


-- ============================================================================
-- Under-immunized children (distinct list) — current month
-- ============================================================================

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


-- ============================================================================
-- Recovery: children who were zero-dose last month and immunized this month
-- ============================================================================

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


-- ============================================================================
-- Recovery detail: which vaccine recovered each zero-dose child this month
-- ============================================================================

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
