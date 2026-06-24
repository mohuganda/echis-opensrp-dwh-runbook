-- This procedure is the incremental version of refresh_program_facts_base.
-- It processes only rows changed since the previous successful Airbyte watermark minus 1 day.

CREATE OR REPLACE PROCEDURE dwh.refresh_program_facts_base()
LANGUAGE plpgsql
AS $$

DECLARE
    v_table_name text := 'dwh.program_facts_base';
    v_previous_watermark timestamptz;
    v_refresh_from timestamptz;
    v_new_watermark timestamptz;
    v_rows_processed integer := 0;
    v_total_rows_processed integer := 0;
    v_lock_acquired boolean := false;
BEGIN
    v_lock_acquired := pg_try_advisory_lock(hashtext(v_table_name));
    IF NOT v_lock_acquired THEN
        RAISE NOTICE 'Refresh already running for %. Skipping.', v_table_name;
        RETURN;
    END IF;

    SELECT last_successful_airbyte_extracted_at
    INTO v_previous_watermark
    FROM dwh.refresh_state
    WHERE table_name = v_table_name
      AND status = 'success';

    v_refresh_from := COALESCE(v_previous_watermark, TIMESTAMPTZ '2000-01-01') - INTERVAL '1 day';

    -------------------------------------------------------------------
    -- Refresh state start
    -------------------------------------------------------------------

    INSERT INTO dwh.refresh_state (
        table_name,
        last_run_started_at,
        status
    )
    VALUES (
        v_table_name,
        clock_timestamp(),
        'running'
    )
    ON CONFLICT (table_name)
    DO UPDATE SET
        last_run_started_at = clock_timestamp(),
        status = 'running',
        error_message = NULL;

    -------------------------------------------------------------------
    -- 1. Refresh encounters
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_encounters (
        encounter_id,
        patient_id,
        practitioner_id,
        organization_id,
        location_id,
        encounter_status,
        class_code,
        class_system,
        class_display,
        type_code,
        type_system,
        type_display,
        type_text,
        service_type_code,
        service_type_system,
        service_type_display,
        service_type_text,
        reason_code,
        reason_system,
        reason_display,
        reason_text,
        period_start,
        period_end,
        practitioner_tag_id,
        care_team_tag_id,
        organization_tag_id,
        location_tag_id,
        app_version,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        e.resource ->> 'id' AS encounter_id,

        dwh.fhir_ref_id(e.resource -> 'subject' ->> 'reference') AS patient_id,
        dwh.fhir_ref_id(e.resource -> 'participant' -> 0 -> 'individual' ->> 'reference') AS practitioner_id,
        dwh.fhir_ref_id(e.resource -> 'serviceProvider' ->> 'reference') AS organization_id,
        dwh.fhir_ref_id(e.resource -> 'location' -> 0 -> 'location' ->> 'reference') AS location_id,

        e.resource ->> 'status' AS encounter_status,

        e.resource -> 'class' ->> 'code' AS class_code,
        e.resource -> 'class' ->> 'system' AS class_system,
        e.resource -> 'class' ->> 'display' AS class_display,

        e.resource -> 'type' -> 0 -> 'coding' -> 0 ->> 'code' AS type_code,
        e.resource -> 'type' -> 0 -> 'coding' -> 0 ->> 'system' AS type_system,
        e.resource -> 'type' -> 0 -> 'coding' -> 0 ->> 'display' AS type_display,
        e.resource -> 'type' -> 0 ->> 'text' AS type_text,

        e.resource -> 'serviceType' -> 'coding' -> 0 ->> 'code' AS service_type_code,
        e.resource -> 'serviceType' -> 'coding' -> 0 ->> 'system' AS service_type_system,
        e.resource -> 'serviceType' -> 'coding' -> 0 ->> 'display' AS service_type_display,
        e.resource -> 'serviceType' ->> 'text' AS service_type_text,

        e.resource -> 'reasonCode' -> 0 -> 'coding' -> 0 ->> 'code' AS reason_code,
        e.resource -> 'reasonCode' -> 0 -> 'coding' -> 0 ->> 'system' AS reason_system,
        e.resource -> 'reasonCode' -> 0 -> 'coding' -> 0 ->> 'display' AS reason_display,
        e.resource -> 'reasonCode' -> 0 ->> 'text' AS reason_text,

        dwh.safe_timestamptz(e.resource -> 'period' ->> 'start') AS period_start,
        dwh.safe_timestamptz(e.resource -> 'period' ->> 'end') AS period_end,

        dwh.fhir_meta_tag_code(e.resource, 'https://smartregister.org/practitioner-tag-id') AS practitioner_tag_id,
        dwh.fhir_meta_tag_code(e.resource, 'https://smartregister.org/care-team-tag-id') AS care_team_tag_id,
        dwh.fhir_meta_tag_code(e.resource, 'https://smartregister.org/organisation-tag-id') AS organization_tag_id,
        dwh.fhir_meta_tag_code(e.resource, 'https://smartregister.org/location-tag-id') AS location_tag_id,
        dwh.fhir_meta_tag_code(e.resource, 'https://smartregister.org/app-version') AS app_version,

        e.resource -> 'meta' ->> 'versionId' AS version_id,
        dwh.safe_timestamptz(e.resource -> 'meta' ->> 'lastUpdated') AS last_updated,
        e._airbyte_extracted_at AS airbyte_extracted_at,
        now()
    FROM airbyte.encounter e
    WHERE e.resource ->> 'id' IS NOT NULL
      AND e._airbyte_extracted_at >= v_refresh_from
    ON CONFLICT (encounter_id)
    DO UPDATE SET
        patient_id = EXCLUDED.patient_id,
        practitioner_id = EXCLUDED.practitioner_id,
        organization_id = EXCLUDED.organization_id,
        location_id = EXCLUDED.location_id,
        encounter_status = EXCLUDED.encounter_status,
        class_code = EXCLUDED.class_code,
        class_system = EXCLUDED.class_system,
        class_display = EXCLUDED.class_display,
        type_code = EXCLUDED.type_code,
        type_system = EXCLUDED.type_system,
        type_display = EXCLUDED.type_display,
        type_text = EXCLUDED.type_text,
        service_type_code = EXCLUDED.service_type_code,
        service_type_system = EXCLUDED.service_type_system,
        service_type_display = EXCLUDED.service_type_display,
        service_type_text = EXCLUDED.service_type_text,
        reason_code = EXCLUDED.reason_code,
        reason_system = EXCLUDED.reason_system,
        reason_display = EXCLUDED.reason_display,
        reason_text = EXCLUDED.reason_text,
        period_start = EXCLUDED.period_start,
        period_end = EXCLUDED.period_end,
        practitioner_tag_id = EXCLUDED.practitioner_tag_id,
        care_team_tag_id = EXCLUDED.care_team_tag_id,
        organization_tag_id = EXCLUDED.organization_tag_id,
        location_tag_id = EXCLUDED.location_tag_id,
        app_version = EXCLUDED.app_version,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
    -- 2. Refresh conditions
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_conditions (
        condition_id,
        patient_id,
        encounter_id,
        condition_code,
        condition_system,
        condition_display,
        condition_text,
        clinical_status_code,
        clinical_status_system,
        clinical_status_display,
        verification_status_code,
        verification_status_system,
        verification_status_display,
        category_code,
        category_system,
        category_display,
        category_text,
        severity_code,
        severity_system,
        severity_display,
        severity_text,
        recorded_date,
        onset_datetime,
        abatement_datetime,
        condition_start_date,
        condition_end_date,
        is_active_condition,
        practitioner_tag_id,
        care_team_tag_id,
        organization_tag_id,
        location_tag_id,
        app_version,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    WITH extracted AS (
        SELECT
            c.resource ->> 'id' AS condition_id,

            dwh.fhir_ref_id(c.resource -> 'subject' ->> 'reference') AS patient_id,
            dwh.fhir_ref_id(c.resource -> 'encounter' ->> 'reference') AS encounter_id,

            c.resource -> 'code' -> 'coding' -> 0 ->> 'code' AS condition_code,
            c.resource -> 'code' -> 'coding' -> 0 ->> 'system' AS condition_system,
            c.resource -> 'code' -> 'coding' -> 0 ->> 'display' AS condition_display,
            c.resource -> 'code' ->> 'text' AS condition_text,

            c.resource -> 'clinicalStatus' -> 'coding' -> 0 ->> 'code' AS clinical_status_code,
            c.resource -> 'clinicalStatus' -> 'coding' -> 0 ->> 'system' AS clinical_status_system,
            c.resource -> 'clinicalStatus' -> 'coding' -> 0 ->> 'display' AS clinical_status_display,

            c.resource -> 'verificationStatus' -> 'coding' -> 0 ->> 'code' AS verification_status_code,
            c.resource -> 'verificationStatus' -> 'coding' -> 0 ->> 'system' AS verification_status_system,
            c.resource -> 'verificationStatus' -> 'coding' -> 0 ->> 'display' AS verification_status_display,

            c.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'code' AS category_code,
            c.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'system' AS category_system,
            c.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'display' AS category_display,
            c.resource -> 'category' -> 0 ->> 'text' AS category_text,

            c.resource -> 'severity' -> 'coding' -> 0 ->> 'code' AS severity_code,
            c.resource -> 'severity' -> 'coding' -> 0 ->> 'system' AS severity_system,
            c.resource -> 'severity' -> 'coding' -> 0 ->> 'display' AS severity_display,
            c.resource -> 'severity' ->> 'text' AS severity_text,

            dwh.safe_timestamptz(c.resource ->> 'recordedDate') AS recorded_date,
            dwh.safe_timestamptz(c.resource ->> 'onsetDateTime') AS onset_datetime,
            dwh.safe_timestamptz(c.resource ->> 'abatementDateTime') AS abatement_datetime,

            dwh.fhir_meta_tag_code(c.resource, 'https://smartregister.org/practitioner-tag-id') AS practitioner_tag_id,
            dwh.fhir_meta_tag_code(c.resource, 'https://smartregister.org/care-team-tag-id') AS care_team_tag_id,
            dwh.fhir_meta_tag_code(c.resource, 'https://smartregister.org/organisation-tag-id') AS organization_tag_id,
            dwh.fhir_meta_tag_code(c.resource, 'https://smartregister.org/location-tag-id') AS location_tag_id,
            dwh.fhir_meta_tag_code(c.resource, 'https://smartregister.org/app-version') AS app_version,

            c.resource -> 'meta' ->> 'versionId' AS version_id,
            dwh.safe_timestamptz(c.resource -> 'meta' ->> 'lastUpdated') AS last_updated,
            c._airbyte_extracted_at AS airbyte_extracted_at
        FROM airbyte.condition c
        WHERE c.resource ->> 'id' IS NOT NULL
          AND c._airbyte_extracted_at >= v_refresh_from
    ),

    normalized AS (
        SELECT
            e.*,

            COALESCE(
                e.onset_datetime::date,
                e.recorded_date::date,
                e.last_updated::date
            ) AS condition_start_date,

            CASE
                WHEN e.abatement_datetime IS NOT NULL
                    THEN e.abatement_datetime::date
                WHEN lower(COALESCE(e.clinical_status_code, 'active')) IN ('inactive', 'resolved', 'remission')
                    THEN e.last_updated::date
                ELSE NULL
            END AS condition_end_date,

            CASE
                WHEN lower(COALESCE(e.clinical_status_code, 'active')) IN ('active', 'recurrence', 'relapse')
                    THEN true
                WHEN e.abatement_datetime IS NULL
                 AND e.clinical_status_code IS NULL
                    THEN true
                ELSE false
            END AS is_active_condition
        FROM extracted e
    )

    SELECT
        n.condition_id,
        n.patient_id,
        n.encounter_id,
        n.condition_code,
        n.condition_system,
        n.condition_display,
        n.condition_text,
        n.clinical_status_code,
        n.clinical_status_system,
        n.clinical_status_display,
        n.verification_status_code,
        n.verification_status_system,
        n.verification_status_display,
        n.category_code,
        n.category_system,
        n.category_display,
        n.category_text,
        n.severity_code,
        n.severity_system,
        n.severity_display,
        n.severity_text,
        n.recorded_date,
        n.onset_datetime,
        n.abatement_datetime,
        n.condition_start_date,
        n.condition_end_date,
        n.is_active_condition,
        n.practitioner_tag_id,
        n.care_team_tag_id,
        n.organization_tag_id,
        n.location_tag_id,
        n.app_version,
        n.version_id,
        n.last_updated,
        n.airbyte_extracted_at,
        now()
    FROM normalized n
    ON CONFLICT (condition_id)
    DO UPDATE SET
        patient_id = EXCLUDED.patient_id,
        encounter_id = EXCLUDED.encounter_id,
        condition_code = EXCLUDED.condition_code,
        condition_system = EXCLUDED.condition_system,
        condition_display = EXCLUDED.condition_display,
        condition_text = EXCLUDED.condition_text,
        clinical_status_code = EXCLUDED.clinical_status_code,
        clinical_status_system = EXCLUDED.clinical_status_system,
        clinical_status_display = EXCLUDED.clinical_status_display,
        verification_status_code = EXCLUDED.verification_status_code,
        verification_status_system = EXCLUDED.verification_status_system,
        verification_status_display = EXCLUDED.verification_status_display,
        category_code = EXCLUDED.category_code,
        category_system = EXCLUDED.category_system,
        category_display = EXCLUDED.category_display,
        category_text = EXCLUDED.category_text,
        severity_code = EXCLUDED.severity_code,
        severity_system = EXCLUDED.severity_system,
        severity_display = EXCLUDED.severity_display,
        severity_text = EXCLUDED.severity_text,
        recorded_date = EXCLUDED.recorded_date,
        onset_datetime = EXCLUDED.onset_datetime,
        abatement_datetime = EXCLUDED.abatement_datetime,
        condition_start_date = EXCLUDED.condition_start_date,
        condition_end_date = EXCLUDED.condition_end_date,
        is_active_condition = EXCLUDED.is_active_condition,
        practitioner_tag_id = EXCLUDED.practitioner_tag_id,
        care_team_tag_id = EXCLUDED.care_team_tag_id,
        organization_tag_id = EXCLUDED.organization_tag_id,
        location_tag_id = EXCLUDED.location_tag_id,
        app_version = EXCLUDED.app_version,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
    -- 3. Refresh flags
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_flags (
        flag_id,
        patient_id,
        group_id,
        encounter_id,
        author_practitioner_id,
        flag_status,
        flag_code,
        flag_system,
        flag_display,
        flag_text,
        category_code,
        category_system,
        category_display,
        category_text,
        period_start,
        period_end,
        practitioner_tag_id,
        care_team_tag_id,
        organization_tag_id,
        location_tag_id,
        app_version,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    WITH extracted AS (
        SELECT
            f.resource ->> 'id' AS flag_id,

            CASE
                WHEN split_part(f.resource -> 'subject' ->> 'reference', '/', 1) = 'Patient'
                    THEN dwh.fhir_ref_id(f.resource -> 'subject' ->> 'reference')
                ELSE NULL
            END AS patient_id,

            CASE
                WHEN split_part(f.resource -> 'subject' ->> 'reference', '/', 1) = 'Group'
                    THEN dwh.fhir_ref_id(f.resource -> 'subject' ->> 'reference')
                ELSE NULL
            END AS group_id,

            dwh.fhir_ref_id(f.resource -> 'encounter' ->> 'reference') AS encounter_id,
            dwh.fhir_ref_id(f.resource -> 'author' ->> 'reference') AS author_practitioner_id,

            f.resource ->> 'status' AS flag_status,

            f.resource -> 'code' -> 'coding' -> 0 ->> 'code' AS flag_code,
            f.resource -> 'code' -> 'coding' -> 0 ->> 'system' AS flag_system,
            f.resource -> 'code' -> 'coding' -> 0 ->> 'display' AS flag_display,
            f.resource -> 'code' ->> 'text' AS flag_text,

            f.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'code' AS category_code,
            f.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'system' AS category_system,
            f.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'display' AS category_display,
            f.resource -> 'category' -> 0 ->> 'text' AS category_text,

            dwh.safe_timestamptz(f.resource -> 'period' ->> 'start') AS period_start,
            dwh.safe_timestamptz(f.resource -> 'period' ->> 'end') AS period_end,

            dwh.fhir_meta_tag_code(f.resource, 'https://smartregister.org/practitioner-tag-id') AS practitioner_tag_id,
            dwh.fhir_meta_tag_code(f.resource, 'https://smartregister.org/care-team-tag-id') AS care_team_tag_id,
            dwh.fhir_meta_tag_code(f.resource, 'https://smartregister.org/organisation-tag-id') AS organization_tag_id,
            dwh.fhir_meta_tag_code(f.resource, 'https://smartregister.org/location-tag-id') AS location_tag_id,
            dwh.fhir_meta_tag_code(f.resource, 'https://smartregister.org/app-version') AS app_version,

            f.resource -> 'meta' ->> 'versionId' AS version_id,
            dwh.safe_timestamptz(f.resource -> 'meta' ->> 'lastUpdated') AS last_updated,
            f._airbyte_extracted_at AS airbyte_extracted_at
        FROM airbyte.flag f
        WHERE f.resource ->> 'id' IS NOT NULL
          AND f._airbyte_extracted_at >= v_refresh_from
    )

    SELECT
        e.flag_id,
        e.patient_id,
        e.group_id,
        e.encounter_id,
        e.author_practitioner_id,
        e.flag_status,
        e.flag_code,
        e.flag_system,
        e.flag_display,
        e.flag_text,
        e.category_code,
        e.category_system,
        e.category_display,
        e.category_text,
        e.period_start,
        e.period_end,
        e.practitioner_tag_id,
        e.care_team_tag_id,
        e.organization_tag_id,
        e.location_tag_id,
        e.app_version,
        e.version_id,
        e.last_updated,
        e.airbyte_extracted_at,
        now()
    FROM extracted e
    ON CONFLICT (flag_id)
    DO UPDATE SET
        patient_id = EXCLUDED.patient_id,
        group_id = EXCLUDED.group_id,
        encounter_id = EXCLUDED.encounter_id,
        author_practitioner_id = EXCLUDED.author_practitioner_id,
        flag_status = EXCLUDED.flag_status,
        flag_code = EXCLUDED.flag_code,
        flag_system = EXCLUDED.flag_system,
        flag_display = EXCLUDED.flag_display,
        flag_text = EXCLUDED.flag_text,
        category_code = EXCLUDED.category_code,
        category_system = EXCLUDED.category_system,
        category_display = EXCLUDED.category_display,
        category_text = EXCLUDED.category_text,
        period_start = EXCLUDED.period_start,
        period_end = EXCLUDED.period_end,
        practitioner_tag_id = EXCLUDED.practitioner_tag_id,
        care_team_tag_id = EXCLUDED.care_team_tag_id,
        organization_tag_id = EXCLUDED.organization_tag_id,
        location_tag_id = EXCLUDED.location_tag_id,
        app_version = EXCLUDED.app_version,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
    -- 4. Refresh observations
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_observations (
        observation_id,
        patient_id,
        group_id,
        location_id,
        encounter_id,
        performer_practitioner_id,
        observation_status,
        observation_code,
        observation_system,
        observation_display,
        observation_text,
        category_1_code,
        category_1_system,
        category_1_display,
        category_2_code,
        category_2_system,
        category_2_display,
        effective_datetime,
        issued_datetime,
        value_string,
        value_boolean,
        value_quantity,
        value_quantity_unit,
        value_quantity_code,
        value_quantity_system,
        value_codeable_concept_code,
        value_codeable_concept_system,
        value_codeable_concept_display,
        value_codeable_concept_text,
        practitioner_tag_id,
        care_team_tag_id,
        organization_tag_id,
        location_tag_id,
        app_version,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        o.resource ->> 'id' AS observation_id,

        CASE
            WHEN split_part(o.resource -> 'subject' ->> 'reference', '/', 1) = 'Patient'
                THEN dwh.fhir_ref_id(o.resource -> 'subject' ->> 'reference')
            ELSE NULL
        END AS patient_id,

        CASE
            WHEN split_part(o.resource -> 'subject' ->> 'reference', '/', 1) = 'Group'
                THEN dwh.fhir_ref_id(o.resource -> 'subject' ->> 'reference')
            ELSE NULL
        END AS group_id,

        CASE
            WHEN split_part(o.resource -> 'subject' ->> 'reference', '/', 1) = 'Location'
                THEN dwh.fhir_ref_id(o.resource -> 'subject' ->> 'reference')
            ELSE dwh.fhir_meta_tag_code(o.resource, 'https://smartregister.org/location-tag-id')
        END AS location_id,

        dwh.fhir_ref_id(o.resource -> 'encounter' ->> 'reference') AS encounter_id,
        dwh.fhir_ref_id(o.resource -> 'performer' -> 0 ->> 'reference') AS performer_practitioner_id,

        o.resource ->> 'status' AS observation_status,

        o.resource -> 'code' -> 'coding' -> 0 ->> 'code' AS observation_code,
        o.resource -> 'code' -> 'coding' -> 0 ->> 'system' AS observation_system,
        o.resource -> 'code' -> 'coding' -> 0 ->> 'display' AS observation_display,
        o.resource -> 'code' ->> 'text' AS observation_text,

        o.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'code' AS category_1_code,
        o.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'system' AS category_1_system,
        o.resource -> 'category' -> 0 -> 'coding' -> 0 ->> 'display' AS category_1_display,

        o.resource -> 'category' -> 1 -> 'coding' -> 0 ->> 'code' AS category_2_code,
        o.resource -> 'category' -> 1 -> 'coding' -> 0 ->> 'system' AS category_2_system,
        o.resource -> 'category' -> 1 -> 'coding' -> 0 ->> 'display' AS category_2_display,

        dwh.safe_timestamptz(o.resource ->> 'effectiveDateTime') AS effective_datetime,
        dwh.safe_timestamptz(o.resource ->> 'issued') AS issued_datetime,

        o.resource ->> 'valueString' AS value_string,

        CASE
            WHEN lower(COALESCE(o.resource ->> 'valueBoolean', '')) IN ('true', 't', 'yes', 'y', '1') THEN true
            WHEN lower(COALESCE(o.resource ->> 'valueBoolean', '')) IN ('false', 'f', 'no', 'n', '0') THEN false
            ELSE NULL
        END AS value_boolean,

        dwh.safe_numeric(o.resource -> 'valueQuantity' ->> 'value') AS value_quantity,
        o.resource -> 'valueQuantity' ->> 'unit' AS value_quantity_unit,
        o.resource -> 'valueQuantity' ->> 'code' AS value_quantity_code,
        o.resource -> 'valueQuantity' ->> 'system' AS value_quantity_system,

        o.resource -> 'valueCodeableConcept' -> 'coding' -> 0 ->> 'code' AS value_codeable_concept_code,
        o.resource -> 'valueCodeableConcept' -> 'coding' -> 0 ->> 'system' AS value_codeable_concept_system,
        o.resource -> 'valueCodeableConcept' -> 'coding' -> 0 ->> 'display' AS value_codeable_concept_display,
        o.resource -> 'valueCodeableConcept' ->> 'text' AS value_codeable_concept_text,

        dwh.fhir_meta_tag_code(o.resource, 'https://smartregister.org/practitioner-tag-id') AS practitioner_tag_id,
        dwh.fhir_meta_tag_code(o.resource, 'https://smartregister.org/care-team-tag-id') AS care_team_tag_id,
        dwh.fhir_meta_tag_code(o.resource, 'https://smartregister.org/organisation-tag-id') AS organization_tag_id,
        dwh.fhir_meta_tag_code(o.resource, 'https://smartregister.org/location-tag-id') AS location_tag_id,
        dwh.fhir_meta_tag_code(o.resource, 'https://smartregister.org/app-version') AS app_version,

        o.resource -> 'meta' ->> 'versionId' AS version_id,
        dwh.safe_timestamptz(o.resource -> 'meta' ->> 'lastUpdated') AS last_updated,
        o._airbyte_extracted_at AS airbyte_extracted_at,
        now()
    FROM airbyte.observation o
    WHERE o.resource ->> 'id' IS NOT NULL
      AND o._airbyte_extracted_at >= v_refresh_from
    ON CONFLICT (observation_id)
    DO UPDATE SET
        patient_id = EXCLUDED.patient_id,
        group_id = EXCLUDED.group_id,
        location_id = EXCLUDED.location_id,
        encounter_id = EXCLUDED.encounter_id,
        performer_practitioner_id = EXCLUDED.performer_practitioner_id,
        observation_status = EXCLUDED.observation_status,
        observation_code = EXCLUDED.observation_code,
        observation_system = EXCLUDED.observation_system,
        observation_display = EXCLUDED.observation_display,
        observation_text = EXCLUDED.observation_text,
        category_1_code = EXCLUDED.category_1_code,
        category_1_system = EXCLUDED.category_1_system,
        category_1_display = EXCLUDED.category_1_display,
        category_2_code = EXCLUDED.category_2_code,
        category_2_system = EXCLUDED.category_2_system,
        category_2_display = EXCLUDED.category_2_display,
        effective_datetime = EXCLUDED.effective_datetime,
        issued_datetime = EXCLUDED.issued_datetime,
        value_string = EXCLUDED.value_string,
        value_boolean = EXCLUDED.value_boolean,
        value_quantity = EXCLUDED.value_quantity,
        value_quantity_unit = EXCLUDED.value_quantity_unit,
        value_quantity_code = EXCLUDED.value_quantity_code,
        value_quantity_system = EXCLUDED.value_quantity_system,
        value_codeable_concept_code = EXCLUDED.value_codeable_concept_code,
        value_codeable_concept_system = EXCLUDED.value_codeable_concept_system,
        value_codeable_concept_display = EXCLUDED.value_codeable_concept_display,
        value_codeable_concept_text = EXCLUDED.value_codeable_concept_text,
        practitioner_tag_id = EXCLUDED.practitioner_tag_id,
        care_team_tag_id = EXCLUDED.care_team_tag_id,
        organization_tag_id = EXCLUDED.organization_tag_id,
        location_tag_id = EXCLUDED.location_tag_id,
        app_version = EXCLUDED.app_version,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
    -- 5. Refresh observation components
    -------------------------------------------------------------------

    CREATE TEMP TABLE IF NOT EXISTS tmp_changed_observations (
        observation_id text PRIMARY KEY
    ) ON COMMIT DROP;

    TRUNCATE TABLE tmp_changed_observations;

    INSERT INTO tmp_changed_observations (observation_id)
    SELECT DISTINCT o.resource ->> 'id'
    FROM airbyte.observation o
    WHERE o.resource ->> 'id' IS NOT NULL
      AND o._airbyte_extracted_at >= v_refresh_from
    ON CONFLICT (observation_id) DO NOTHING;

    DELETE FROM dwh.fact_observation_components c
    USING tmp_changed_observations co
    WHERE c.observation_id = co.observation_id;

    INSERT INTO dwh.fact_observation_components (
        observation_id,
        component_index,
        component_code,
        component_system,
        component_display,
        component_text,
        value_string,
        value_boolean,
        value_quantity,
        value_quantity_unit,
        value_quantity_code,
        value_quantity_system,
        value_codeable_concept_code,
        value_codeable_concept_system,
        value_codeable_concept_display,
        value_codeable_concept_text,
        dwh_updated_at
    )
    SELECT
        o.resource ->> 'id' AS observation_id,
        component_item.ordinality::integer AS component_index,

        component_item.component -> 'code' -> 'coding' -> 0 ->> 'code' AS component_code,
        component_item.component -> 'code' -> 'coding' -> 0 ->> 'system' AS component_system,
        component_item.component -> 'code' -> 'coding' -> 0 ->> 'display' AS component_display,
        component_item.component -> 'code' ->> 'text' AS component_text,

        component_item.component ->> 'valueString' AS value_string,

        CASE
            WHEN lower(COALESCE(component_item.component ->> 'valueBoolean', '')) IN ('true', 't', 'yes', 'y', '1') THEN true
            WHEN lower(COALESCE(component_item.component ->> 'valueBoolean', '')) IN ('false', 'f', 'no', 'n', '0') THEN false
            ELSE NULL
        END AS value_boolean,

        dwh.safe_numeric(component_item.component -> 'valueQuantity' ->> 'value') AS value_quantity,
        component_item.component -> 'valueQuantity' ->> 'unit' AS value_quantity_unit,
        component_item.component -> 'valueQuantity' ->> 'code' AS value_quantity_code,
        component_item.component -> 'valueQuantity' ->> 'system' AS value_quantity_system,

        component_item.component -> 'valueCodeableConcept' -> 'coding' -> 0 ->> 'code' AS value_codeable_concept_code,
        component_item.component -> 'valueCodeableConcept' -> 'coding' -> 0 ->> 'system' AS value_codeable_concept_system,
        component_item.component -> 'valueCodeableConcept' -> 'coding' -> 0 ->> 'display' AS value_codeable_concept_display,
        component_item.component -> 'valueCodeableConcept' ->> 'text' AS value_codeable_concept_text,

        now()
    FROM airbyte.observation o
    JOIN tmp_changed_observations co
        ON co.observation_id = o.resource ->> 'id'
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(o.resource -> 'component', '[]'::jsonb)
    ) WITH ORDINALITY AS component_item(component, ordinality)
    WHERE o.resource ->> 'id' IS NOT NULL;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;

    -------------------------------------------------------------------
    -- Refresh state success
    -------------------------------------------------------------------

    SELECT GREATEST(
        COALESCE((SELECT MAX(_airbyte_extracted_at) FROM airbyte.encounter WHERE _airbyte_extracted_at >= v_refresh_from), v_previous_watermark, TIMESTAMPTZ '2000-01-01'),
        COALESCE((SELECT MAX(_airbyte_extracted_at) FROM airbyte.condition WHERE _airbyte_extracted_at >= v_refresh_from), v_previous_watermark, TIMESTAMPTZ '2000-01-01'),
        COALESCE((SELECT MAX(_airbyte_extracted_at) FROM airbyte.flag WHERE _airbyte_extracted_at >= v_refresh_from), v_previous_watermark, TIMESTAMPTZ '2000-01-01'),
        COALESCE((SELECT MAX(_airbyte_extracted_at) FROM airbyte.observation WHERE _airbyte_extracted_at >= v_refresh_from), v_previous_watermark, TIMESTAMPTZ '2000-01-01')
    ) INTO v_new_watermark;

    UPDATE dwh.refresh_state
    SET
        last_successful_airbyte_extracted_at = COALESCE(v_new_watermark, v_previous_watermark),
        last_run_completed_at = clock_timestamp(),
        status = 'success',
        rows_processed = v_total_rows_processed + v_rows_processed,
        error_message = NULL
    WHERE table_name = v_table_name;

    PERFORM pg_advisory_unlock(hashtext(v_table_name));

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET
        last_run_completed_at = now(),
        status = 'failed',
        error_message = SQLERRM
    WHERE table_name = v_table_name;

    IF v_lock_acquired THEN
        PERFORM pg_advisory_unlock(hashtext(v_table_name));
    END IF;

    RAISE;
END;

$$;
