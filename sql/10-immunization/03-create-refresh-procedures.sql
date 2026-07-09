-- Immunization refresh procedures.
--
-- Source note: these procedures read from airbyte.questionnaire_response,
-- NOT from airbyte.immunization or airbyte.observation. Those resources had
-- extraction errors during Airbyte replication. The QuestionnaireResponse forms
-- are the reliable source for all immunization records.
--
-- Procedure 1: dwh.refresh_immunization_facts()
--   Extracts administered vaccine doses from QuestionnaireResponse resources.
--   Incremental: uses _airbyte_extracted_at watermark with a 1-day overlap window.
--   Covers three source forms:
--     - child-immunization-record-all  (multi-vaccine record form)
--     - malaria-vaccine-record         (malaria-specific form)
--     - hpv-vaccine-record             (HPV-specific form)
--     - legacy single-vaccine forms
--
-- Procedure 2: dwh.refresh_immunization_status(p_period_start, p_period_end)
--   Builds the per-patient per-dose per-period status table.
--   Full DELETE + INSERT for the given period. Not incremental.
--   Joins dim_patients × ref_immunization_vaccine_map to generate the
--   eligible schedule, then joins fact_immunizations to mark what was received.
--
-- Procedure 3: dwh.refresh_immunization_status_current_and_previous_month()
--   Wrapper that refreshes the previous month and current month as two
--   separate calls. Used in the daily refresh schedule.

-- ============================================================================
-- Procedure 1: Refresh administered immunization facts
-- ============================================================================

CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_facts()
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name text := 'dwh.immunization_facts';
    v_started_at timestamptz := clock_timestamp();
    v_previous_watermark timestamptz;
    v_refresh_from timestamptz;
    v_new_watermark timestamptz;
    v_rows_processed integer := 0;
BEGIN
    SELECT last_successful_airbyte_extracted_at
    INTO v_previous_watermark
    FROM dwh.refresh_state
    WHERE table_name = v_table_name;

    v_refresh_from := COALESCE(v_previous_watermark - INTERVAL '1 day', TIMESTAMPTZ '1900-01-01');

    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES (v_table_name, v_started_at, 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET last_run_started_at = EXCLUDED.last_run_started_at, status = 'running', error_message = NULL;

    WITH RECURSIVE changed_qrs AS (
        SELECT resource, _airbyte_extracted_at
        FROM airbyte.questionnaire_response
        WHERE _airbyte_extracted_at >= v_refresh_from
          AND resource ->> 'resourceType' = 'QuestionnaireResponse'
          AND (
              resource ->> 'questionnaire' IN (
                  'Questionnaire/child-immunization-record-all',
                  'Questionnaire/malaria-vaccine-record',
                  'Questionnaire/hpv-vaccine-record',
                  'Questionnaire/6965f0fc-e0e9-449e-941a-c6e708cc9dd6'
              )
              OR resource::text ILIKE '%vaccine%'
          )
    ),
    deleted_old AS (
        DELETE FROM dwh.fact_immunizations fi
        USING changed_qrs q
        WHERE fi.questionnaire_response_id = q.resource ->> 'id'
        RETURNING fi.questionnaire_response_id
    ),
    qr_items AS (
        SELECT q.resource ->> 'id' AS questionnaire_response_id, q.resource, q._airbyte_extracted_at, item
        FROM changed_qrs q
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(q.resource -> 'item', '[]'::jsonb)) item
        UNION ALL
        SELECT qi.questionnaire_response_id, qi.resource, qi._airbyte_extracted_at, child_item
        FROM qr_items qi
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(qi.item -> 'item', '[]'::jsonb)) child_item
    ),
    qr_base AS (
        SELECT
            q.resource ->> 'id' AS questionnaire_response_id,
            q.resource,
            q._airbyte_extracted_at,
            q.resource ->> 'questionnaire' AS questionnaire,
            regexp_replace(q.resource #>> '{subject,reference}', '^Patient/', '') AS subject_patient_id,
            regexp_replace(q.resource #>> '{encounter,reference}', '^Encounter/', '') AS encounter_id,
            regexp_replace(q.resource #>> '{author,reference}', '^Practitioner/', '') AS author_practitioner_id,
            q.resource ->> 'authored' AS authored_text,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/care-team-tag-id' LIMIT 1) AS care_team_id,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/location-tag-id' LIMIT 1) AS location_id,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/organisation-tag-id' LIMIT 1) AS organization_id,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/practitioner-tag-id' LIMIT 1) AS practitioner_id
        FROM changed_qrs q
    ),
    item_values AS (
        SELECT
            questionnaire_response_id,
            MAX(item #>> '{answer,0,valueString}') FILTER (WHERE item ->> 'linkId' IN ('patient-id', 'patient-id-hidden')) AS patient_id_answer,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'vaccines-date') AS vaccines_date,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = '1e1f0f3b-58de-41b4-8db0-6c4b033cce57') AS single_immunization_date,
            MAX(item #>> '{answer,0,valueString}') FILTER (WHERE item ->> 'linkId' = 'vaccine-name') AS single_vaccine_name,
            MAX(item #>> '{answer,0,valueCoding,code}') FILTER (WHERE item ->> 'linkId' = 'received-malaria-vaccine') AS received_malaria_code,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'hpv-vaccine-received') AS hpv_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'hpv-vaccine-date') AS hpv_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-1-received') AS dose_1_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-1-date') AS dose_1_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-2-received') AS dose_2_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-2-date') AS dose_2_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-3-received') AS dose_3_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-3-date') AS dose_3_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-4-received') AS dose_4_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-4-date') AS dose_4_date
        FROM qr_items
        GROUP BY questionnaire_response_id
    ),
    record_all_rows AS (
        SELECT b.questionnaire_response_id, 'child_immunization_record_all' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               iv.vaccines_date::date AS administered_date, b.authored_text::timestamptz AS recorded_at,
               ans #>> '{valueReference,display}' AS vaccine_name, qi.item ->> 'linkId' AS source_link_id,
               ans #>> '{valueReference,reference}' AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_items qi
        JOIN qr_base b ON b.questionnaire_response_id = qi.questionnaire_response_id
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(qi.item -> 'answer', '[]'::jsonb)) ans
        WHERE b.questionnaire = 'Questionnaire/child-immunization-record-all'
          AND qi.item ->> 'linkId' LIKE 'selected-vaccines-%'
          AND ans #>> '{valueReference,display}' IS NOT NULL
          AND iv.vaccines_date IS NOT NULL
    ),
    single_rows AS (
        SELECT b.questionnaire_response_id, 'child_immunization_single' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               iv.single_immunization_date::date AS administered_date, b.authored_text::timestamptz AS recorded_at,
               iv.single_vaccine_name AS vaccine_name, 'vaccine-name' AS source_link_id,
               NULL::text AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_base b
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        WHERE iv.single_vaccine_name IS NOT NULL
          AND iv.single_immunization_date IS NOT NULL
          AND b.questionnaire <> 'Questionnaire/child-immunization-record-all'
    ),
    malaria_rows AS (
        SELECT b.questionnaire_response_id, 'malaria_vaccine_record' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               d.administered_date, b.authored_text::timestamptz AS recorded_at, d.vaccine_name,
               d.source_link_id, NULL::text AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_base b
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        CROSS JOIN LATERAL (
            VALUES
                ('dose-1-date', 'Malaria Vaccine Dose 1', iv.dose_1_received, iv.dose_1_date::date),
                ('dose-2-date', 'Malaria Vaccine Dose 2', iv.dose_2_received, iv.dose_2_date::date),
                ('dose-3-date', 'Malaria Vaccine Dose 3', iv.dose_3_received, iv.dose_3_date::date),
                ('dose-4-date', 'Malaria Vaccine Dose 4', iv.dose_4_received, iv.dose_4_date::date)
        ) d(source_link_id, vaccine_name, received, administered_date)
        WHERE b.questionnaire = 'Questionnaire/malaria-vaccine-record'
          AND iv.received_malaria_code = 'yes'
          AND d.received = 'true'
          AND d.administered_date IS NOT NULL
    ),
    hpv_rows AS (
        SELECT b.questionnaire_response_id, 'hpv_vaccine_record' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               iv.hpv_date::date AS administered_date, b.authored_text::timestamptz AS recorded_at,
               'HPV Vaccine' AS vaccine_name, 'hpv-vaccine-date' AS source_link_id,
               NULL::text AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_base b
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        WHERE b.questionnaire = 'Questionnaire/hpv-vaccine-record'
          AND iv.hpv_received = 'true'
          AND iv.hpv_date IS NOT NULL
    ),
    all_rows AS (
        SELECT * FROM record_all_rows
        UNION ALL SELECT * FROM single_rows
        UNION ALL SELECT * FROM malaria_rows
        UNION ALL SELECT * FROM hpv_rows
    )
    INSERT INTO dwh.fact_immunizations (
        questionnaire_response_id, source_form, questionnaire, patient_id, encounter_id,
        administered_date, recorded_at, vaccine_name, programme, antigen_group, dose_label,
        dose_number, schedule_group, source_link_id, source_task_id, practitioner_id,
        care_team_id, location_id, organization_id, patient_age_days_at_admin,
        patient_age_months_at_admin, patient_age_years_at_admin, is_under_5_at_admin,
        _airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        r.questionnaire_response_id, r.source_form, r.questionnaire, r.patient_id, r.encounter_id,
        r.administered_date, r.recorded_at, r.vaccine_name,
        COALESCE(m.programme, 'unknown'), m.antigen_group, COALESCE(m.dose_label, ''),
        m.dose_number, m.schedule_group, r.source_link_id, r.source_task_id,
        COALESCE(r.practitioner_id, r.author_practitioner_id), r.care_team_id, r.location_id, r.organization_id,
        CASE WHEN p.birth_date IS NOT NULL THEN r.administered_date - p.birth_date END,
        CASE WHEN p.birth_date IS NOT NULL THEN dwh.age_in_months(p.birth_date, r.administered_date) END,
        CASE WHEN p.birth_date IS NOT NULL THEN dwh.age_in_years(p.birth_date, r.administered_date) END,
        CASE WHEN p.birth_date IS NOT NULL THEN r.administered_date < p.birth_date + INTERVAL '5 years' END,
        r._airbyte_extracted_at, clock_timestamp()
    FROM all_rows r
    LEFT JOIN dwh.ref_immunization_vaccine_map m ON m.vaccine_name = REPLACE(r.vaccine_name, '_', '-')
    LEFT JOIN dwh.dim_patients p ON p.patient_id = r.patient_id
    WHERE r.patient_id IS NOT NULL AND r.administered_date IS NOT NULL AND r.vaccine_name IS NOT NULL
    ON CONFLICT (questionnaire_response_id, source_link_id, vaccine_name, dose_label)
    DO UPDATE SET
        patient_id                  = EXCLUDED.patient_id,
        encounter_id                = EXCLUDED.encounter_id,
        administered_date           = EXCLUDED.administered_date,
        recorded_at                 = EXCLUDED.recorded_at,
        programme                   = EXCLUDED.programme,
        antigen_group               = EXCLUDED.antigen_group,
        dose_number                 = EXCLUDED.dose_number,
        schedule_group              = EXCLUDED.schedule_group,
        source_task_id              = EXCLUDED.source_task_id,
        practitioner_id             = EXCLUDED.practitioner_id,
        care_team_id                = EXCLUDED.care_team_id,
        location_id                 = EXCLUDED.location_id,
        organization_id             = EXCLUDED.organization_id,
        patient_age_days_at_admin   = EXCLUDED.patient_age_days_at_admin,
        patient_age_months_at_admin = EXCLUDED.patient_age_months_at_admin,
        patient_age_years_at_admin  = EXCLUDED.patient_age_years_at_admin,
        is_under_5_at_admin         = EXCLUDED.is_under_5_at_admin,
        _airbyte_extracted_at       = EXCLUDED._airbyte_extracted_at,
        dwh_updated_at              = clock_timestamp();

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;

    SELECT MAX(_airbyte_extracted_at)
    INTO v_new_watermark
    FROM airbyte.questionnaire_response
    WHERE _airbyte_extracted_at >= v_refresh_from
      AND resource ->> 'resourceType' = 'QuestionnaireResponse';

    UPDATE dwh.refresh_state
    SET status = 'success',
        rows_processed = v_rows_processed,
        last_successful_airbyte_extracted_at = COALESCE(v_new_watermark, v_previous_watermark),
        last_run_completed_at = clock_timestamp(),
        error_message = NULL
    WHERE table_name = v_table_name;

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET status = 'failed',
        last_run_completed_at = clock_timestamp(),
        error_message = SQLERRM
    WHERE table_name = v_table_name;
    RAISE;
END;
$$;

-- ============================================================================
-- Procedure 2: Refresh immunization status for a given reporting period
-- ============================================================================

CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_status(
    p_period_start date,
    p_period_end date
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name text := 'dwh.immunization_status:' || p_period_start::text;
    v_rows_processed integer := 0;
BEGIN
    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES (v_table_name, clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET
        last_run_started_at = EXCLUDED.last_run_started_at,
        status = 'running',
        error_message = NULL;

    DELETE FROM dwh.fact_immunization_status
    WHERE reporting_period_start = p_period_start
      AND reporting_period_end = p_period_end;

    WITH vht_lookup AS (
        -- One row per practitioner — deduplicates in case a VHT has multiple active roles.
        SELECT DISTINCT ON (practitioner_id)
            practitioner_id,
            practitioner_name AS vht_name
        FROM dwh.dim_practitioner_assignments
        WHERE is_vht = true
          AND COALESCE(active, true) = true
        ORDER BY practitioner_id
    ),
    eligible_schedule AS (
        SELECT
            p.patient_id,
            p.patient_name,
            p.gender,
            p.birth_date,
            dwh.age_in_months(p.birth_date, p_period_end) AS age_months_at_period_end,
            dwh.age_in_years(p.birth_date, p_period_end) AS age_years_at_period_end,
            p.phone_number AS caregiver_phone,
            p.household_id,
            p.practitioner_id AS patient_practitioner_id,
            p.care_team_id AS patient_care_team_id,
            p.organization_id AS patient_organization_id,
            p.country_name,
            p.region_id,
            p.region_name,
            p.district_id,
            p.district_name,
            p.county_id,
            p.county_name,
            p.subcounty_id,
            p.subcounty_name,
            p.parish_id,
            p.parish_name,
            p.health_facility_id,
            p.health_facility_name,
            p.village_id,
            p.village_name,
            p.reporting_facility_name,
            p.reporting_dhis2_orgunit_uid,
            vht.vht_name,
            m.*,
            CASE WHEN m.due_age_days IS NOT NULL THEN (p.birth_date + (m.due_age_days || ' days')::interval)::date END AS due_date,
            CASE WHEN m.max_age_days IS NOT NULL THEN (p.birth_date + (m.max_age_days || ' days')::interval)::date END AS max_due_date
        FROM dwh.dim_patients p
        JOIN dwh.ref_immunization_vaccine_map m ON true
        LEFT JOIN vht_lookup vht ON vht.practitioner_id = p.practitioner_id
        WHERE p.birth_date IS NOT NULL
          AND COALESCE(p.active, true) = true
          AND COALESCE(p.is_deceased, false) = false
          AND (
              ((m.include_in_child_immunization_reports OR m.include_in_malaria_reports)
                AND p.birth_date > p_period_end - INTERVAL '5 years')
              OR
              (m.include_in_hpv_reports
                AND lower(COALESCE(p.gender, '')) IN ('female', 'f')
                AND dwh.age_in_years(p.birth_date, p_period_end) BETWEEN 9 AND 19)
          )
    ),
    received AS (
        SELECT DISTINCT ON (patient_id, programme, vaccine_name, dose_label)
            patient_id,
            programme,
            vaccine_name,
            dose_label,
            administered_date AS received_date
        FROM dwh.fact_immunizations
        WHERE administered_date < p_period_end
        ORDER BY patient_id, programme, vaccine_name, dose_label, administered_date
    ),
    received_summary AS (
        SELECT
            patient_id,
            COUNT(*) FILTER (
                WHERE administered_date < p_period_end
                  AND programme IN ('child_immunization', 'malaria_vaccine')
            ) AS under5_received_count
        FROM dwh.fact_immunizations
        GROUP BY patient_id
    ),
    status_rows AS (
        SELECT
            p_period_start AS reporting_period_start,
            p_period_end AS reporting_period_end,
            es.patient_id,
            es.patient_name,
            es.gender,
            es.birth_date,
            es.age_months_at_period_end,
            es.age_years_at_period_end,
            NULL::text AS caregiver_name,
            es.caregiver_phone,
            es.household_id,
            es.country_name,
            es.region_id,
            es.region_name,
            es.district_id,
            es.district_name,
            es.county_id,
            es.county_name,
            es.subcounty_id,
            es.subcounty_name,
            es.parish_id,
            es.parish_name,
            es.health_facility_id,
            es.health_facility_name,
            es.village_id,
            es.village_name,
            es.reporting_facility_name,
            es.reporting_dhis2_orgunit_uid,
            es.patient_practitioner_id,
            es.patient_care_team_id,
            es.patient_organization_id,
            es.patient_practitioner_id AS assigned_practitioner_id,
            es.vht_name AS assigned_vht_name,
            NULL::text AS assigned_vht_phone,  -- phone not available in dim_practitioner_assignments
            es.programme,
            es.vaccine_name,
            es.antigen_group,
            es.dose_label,
            es.dose_number,
            es.schedule_group,
            es.due_date,
            es.max_due_date,
            CASE WHEN es.due_date < p_period_end AND r.received_date IS NULL THEN p_period_end - es.due_date END AS days_overdue,
            true AS is_eligible,
            COALESCE(es.due_date < p_period_end, false) AS is_due,
            r.received_date IS NOT NULL AS is_received,
            r.received_date,
            CASE WHEN r.received_date IS NOT NULL AND es.max_due_date IS NOT NULL AND r.received_date > es.max_due_date THEN true ELSE false END AS is_late_received,
            CASE WHEN es.include_in_under5_reports AND COALESCE(rs.under5_received_count, 0) = 0 THEN true ELSE false END AS is_zero_dose,
            CASE WHEN es.due_date < p_period_end AND r.received_date IS NULL THEN true ELSE false END AS is_under_immunised,
            CASE WHEN r.received_date >= p_period_start AND r.received_date < p_period_end THEN true ELSE false END AS is_recovered_this_period,
            CASE
                WHEN es.due_date IS NULL THEN 'eligible'
                WHEN es.due_date >= p_period_end THEN 'not_due'
                WHEN r.received_date IS NOT NULL THEN 'received'
                ELSE 'due_missing'
            END AS follow_up_status,
            es.is_fic_required
        FROM eligible_schedule es
        LEFT JOIN received r
          ON r.patient_id = es.patient_id
         AND r.programme = es.programme
         AND r.vaccine_name = es.vaccine_name
         AND r.dose_label = es.dose_label
        LEFT JOIN received_summary rs
          ON rs.patient_id = es.patient_id
    ),
    fic AS (
        SELECT
            patient_id,
            COALESCE(bool_and(is_received) FILTER (
                WHERE programme = 'child_immunization'
                  AND is_fic_required
                  AND is_due
            ), false) AS is_fully_immunised_child
        FROM status_rows
        GROUP BY patient_id
    )
    INSERT INTO dwh.fact_immunization_status (
        reporting_period_start, reporting_period_end, patient_id, patient_name, gender,
        birth_date, age_months_at_period_end, age_years_at_period_end, caregiver_name,
        caregiver_phone, household_id, village_id, parish_id, health_facility_id,
        subcounty_id, district_id, assigned_practitioner_id, assigned_vht_name,
        assigned_vht_phone, programme, vaccine_name, antigen_group, dose_label,
        dose_number, schedule_group, due_date, max_due_date, days_overdue, is_eligible,
        is_due, is_received, received_date, is_late_received, is_zero_dose,
        is_under_immunised, is_fully_immunised_child, is_recovered_this_period,
        follow_up_status, barrier_reason, dwh_updated_at, country_name, region_id,
        region_name, district_name, county_id, county_name, subcounty_name, parish_name,
        health_facility_name, village_name, reporting_facility_name,
        reporting_dhis2_orgunit_uid, patient_practitioner_id, patient_care_team_id,
        patient_organization_id
    )
    SELECT
        s.reporting_period_start, s.reporting_period_end, s.patient_id, s.patient_name,
        s.gender, s.birth_date, s.age_months_at_period_end, s.age_years_at_period_end,
        s.caregiver_name, s.caregiver_phone, s.household_id, s.village_id, s.parish_id,
        s.health_facility_id, s.subcounty_id, s.district_id, s.assigned_practitioner_id,
        s.assigned_vht_name, s.assigned_vht_phone, s.programme, s.vaccine_name,
        s.antigen_group, s.dose_label, s.dose_number, s.schedule_group, s.due_date,
        s.max_due_date, s.days_overdue, s.is_eligible, s.is_due, s.is_received,
        s.received_date, s.is_late_received, s.is_zero_dose, s.is_under_immunised,
        COALESCE(f.is_fully_immunised_child, false), s.is_recovered_this_period,
        s.follow_up_status, NULL::text, clock_timestamp(), s.country_name, s.region_id,
        s.region_name, s.district_name, s.county_id, s.county_name, s.subcounty_name,
        s.parish_name, s.health_facility_name, s.village_name, s.reporting_facility_name,
        s.reporting_dhis2_orgunit_uid, s.patient_practitioner_id, s.patient_care_team_id,
        s.patient_organization_id
    FROM status_rows s
    LEFT JOIN fic f ON f.patient_id = s.patient_id;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;

    UPDATE dwh.refresh_state
    SET status = 'success',
        rows_processed = v_rows_processed,
        last_run_completed_at = clock_timestamp(),
        error_message = NULL
    WHERE table_name = v_table_name;

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET status = 'failed',
        last_run_completed_at = clock_timestamp(),
        error_message = SQLERRM
    WHERE table_name = v_table_name;
    RAISE;
END;
$$;

-- ============================================================================
-- Procedure 3: Status table purge helper
-- ============================================================================
--
-- Removes fact_immunization_status rows older than p_keep_from.
-- Default: start of the current quarter (keeps ~1-3 months for follow-up).
-- The aggregate table (agg_immunization_monthly) is never touched here.

CREATE OR REPLACE PROCEDURE dwh.purge_old_immunization_status(
    p_keep_from date DEFAULT (date_trunc('quarter', current_date))::date
)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows_deleted integer := 0;
BEGIN
    DELETE FROM dwh.fact_immunization_status
    WHERE reporting_period_start < p_keep_from;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    RAISE NOTICE 'Deleted % old immunization status rows (keep from %)', v_rows_deleted, p_keep_from;
END;
$$;

-- ============================================================================
-- Procedure 4: Daily wrapper — refresh status for current + previous month
-- ============================================================================
--
-- Refreshes the row-level operational line-list for the two most recent months,
-- then purges status rows older than the start of the current quarter.
--
-- The monthly aggregate (agg_immunization_monthly) is managed separately by
-- dwh.refresh_immunization_monthly_aggregates() in 05-create-aggregate-table.sql.

CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_status_current_and_previous_month()
LANGUAGE plpgsql AS $$
DECLARE
    v_current_start date := date_trunc('month', current_date)::date;
    v_current_end   date := (date_trunc('month', current_date) + INTERVAL '1 month')::date;
    v_prev_start    date := (date_trunc('month', current_date) - INTERVAL '1 month')::date;
    v_prev_end      date := date_trunc('month', current_date)::date;
BEGIN
    CALL dwh.refresh_immunization_status(v_prev_start,    v_prev_end);
    CALL dwh.refresh_immunization_status(v_current_start, v_current_end);
    CALL dwh.purge_old_immunization_status((date_trunc('quarter', current_date))::date);
END;
$$;
