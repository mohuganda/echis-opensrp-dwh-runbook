CREATE OR REPLACE PROCEDURE dwh.refresh_client_dimensions()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_processed integer := 0;
    v_total_rows_processed integer := 0;
BEGIN
    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES ('dwh.client_dimensions', clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET last_run_started_at = EXCLUDED.last_run_started_at, status = 'running', error_message = NULL;

    INSERT INTO dwh.stg_patients (
        patient_id, full_name, family_name, given_name, gender, birth_date,
        deceased_boolean, deceased_datetime, active, telecom_system, phone_number,
        official_identifier_value, secondary_identifier_value,
        practitioner_tag_id, care_team_tag_id, organization_tag_id, location_tag_id, app_version,
        version_id, last_updated, airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        p.resource ->> 'id',
        dwh.fhir_human_name(p.resource -> 'name'),
        p.resource -> 'name' -> 0 ->> 'family',
        p.resource -> 'name' -> 0 -> 'given' ->> 0,
        p.resource ->> 'gender',
        NULLIF(p.resource ->> 'birthDate', '')::date,
        NULLIF(p.resource ->> 'deceasedBoolean', '')::boolean,
        dwh.safe_timestamptz(p.resource ->> 'deceasedDateTime'),
        COALESCE(NULLIF(p.resource ->> 'active', '')::boolean, true),
        telecom.telecom_system,
        telecom.phone_number,
        identifiers.official_identifier_value,
        identifiers.secondary_identifier_value,
        dwh.fhir_meta_tag_code(p.resource, 'https://smartregister.org/practitioner-tag-id'),
        dwh.fhir_meta_tag_code(p.resource, 'https://smartregister.org/care-team-tag-id'),
        dwh.fhir_meta_tag_code(p.resource, 'https://smartregister.org/organisation-tag-id'),
        dwh.fhir_meta_tag_code(p.resource, 'https://smartregister.org/location-tag-id'),
        dwh.fhir_meta_tag_code(p.resource, 'https://smartregister.org/app-version'),
        p.resource #>> '{meta,versionId}',
        dwh.safe_timestamptz(p.resource #>> '{meta,lastUpdated}'),
        p._airbyte_extracted_at,
        clock_timestamp()
    FROM airbyte.patient p
    LEFT JOIN LATERAL (
        SELECT t ->> 'system' AS telecom_system, t ->> 'value' AS phone_number
        FROM jsonb_array_elements(COALESCE(p.resource -> 'telecom', '[]'::jsonb)) t
        WHERE t ->> 'system' = 'phone'
          AND NULLIF(t ->> 'value', '') IS NOT NULL
        ORDER BY CASE WHEN t ->> 'use' = 'mobile' THEN 1 WHEN t ->> 'use' = 'home' THEN 2 ELSE 3 END
        LIMIT 1
    ) telecom ON true
    LEFT JOIN LATERAL (
        SELECT
            MAX(i ->> 'value') FILTER (WHERE i ->> 'use' = 'official') AS official_identifier_value,
            MAX(i ->> 'value') FILTER (WHERE i ->> 'use' = 'secondary') AS secondary_identifier_value
        FROM jsonb_array_elements(COALESCE(p.resource -> 'identifier', '[]'::jsonb)) i
    ) identifiers ON true
    WHERE p.resource ->> 'id' IS NOT NULL
    ON CONFLICT (patient_id) DO UPDATE SET
        full_name = EXCLUDED.full_name,
        family_name = EXCLUDED.family_name,
        given_name = EXCLUDED.given_name,
        gender = EXCLUDED.gender,
        birth_date = EXCLUDED.birth_date,
        deceased_boolean = EXCLUDED.deceased_boolean,
        deceased_datetime = EXCLUDED.deceased_datetime,
        active = EXCLUDED.active,
        telecom_system = EXCLUDED.telecom_system,
        phone_number = EXCLUDED.phone_number,
        official_identifier_value = EXCLUDED.official_identifier_value,
        secondary_identifier_value = EXCLUDED.secondary_identifier_value,
        practitioner_tag_id = EXCLUDED.practitioner_tag_id,
        care_team_tag_id = EXCLUDED.care_team_tag_id,
        organization_tag_id = EXCLUDED.organization_tag_id,
        location_tag_id = EXCLUDED.location_tag_id,
        app_version = EXCLUDED.app_version,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = clock_timestamp();

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    INSERT INTO dwh.stg_households (
        household_id, household_name, group_type, active, actual,
        household_code_system, household_code, household_code_display, household_code_text,
        location_id, practitioner_tag_id, care_team_tag_id, organization_tag_id, location_tag_id, app_version,
        version_id, last_updated, airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        g.resource ->> 'id',
        g.resource ->> 'name',
        g.resource ->> 'type',
        COALESCE(NULLIF(g.resource ->> 'active', '')::boolean, true),
        COALESCE(NULLIF(g.resource ->> 'actual', '')::boolean, true),
        g.resource #>> '{code,coding,0,system}',
        g.resource #>> '{code,coding,0,code}',
        g.resource #>> '{code,coding,0,display}',
        g.resource #>> '{code,text}',
        dwh.fhir_ref_id(g.resource #>> '{managingEntity,reference}'),
        dwh.fhir_meta_tag_code(g.resource, 'https://smartregister.org/practitioner-tag-id'),
        dwh.fhir_meta_tag_code(g.resource, 'https://smartregister.org/care-team-tag-id'),
        dwh.fhir_meta_tag_code(g.resource, 'https://smartregister.org/organisation-tag-id'),
        dwh.fhir_meta_tag_code(g.resource, 'https://smartregister.org/location-tag-id'),
        dwh.fhir_meta_tag_code(g.resource, 'https://smartregister.org/app-version'),
        g.resource #>> '{meta,versionId}',
        dwh.safe_timestamptz(g.resource #>> '{meta,lastUpdated}'),
        g._airbyte_extracted_at,
        clock_timestamp()
    FROM airbyte."group" g
    WHERE g.resource ->> 'id' IS NOT NULL
      AND g.resource #>> '{code,coding,0,code}' = '35359004'
    ON CONFLICT (household_id) DO UPDATE SET
        household_name = EXCLUDED.household_name,
        active = EXCLUDED.active,
        actual = EXCLUDED.actual,
        location_id = EXCLUDED.location_id,
        practitioner_tag_id = EXCLUDED.practitioner_tag_id,
        care_team_tag_id = EXCLUDED.care_team_tag_id,
        organization_tag_id = EXCLUDED.organization_tag_id,
        location_tag_id = EXCLUDED.location_tag_id,
        app_version = EXCLUDED.app_version,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = clock_timestamp();

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    DELETE FROM dwh.bridge_household_members;

    INSERT INTO dwh.bridge_household_members (household_id, patient_id, member_reference, member_entity_type, inactive, dwh_updated_at)
    SELECT
        g.resource ->> 'id' AS household_id,
        dwh.fhir_ref_id(member_item #>> '{entity,reference}') AS patient_id,
        member_item #>> '{entity,reference}' AS member_reference,
        split_part(member_item #>> '{entity,reference}', '/', 1) AS member_entity_type,
        COALESCE(NULLIF(member_item ->> 'inactive', '')::boolean, false) AS inactive,
        clock_timestamp()
    FROM airbyte."group" g
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(g.resource -> 'member', '[]'::jsonb)) member_item
    WHERE g.resource #>> '{code,coding,0,code}' = '35359004'
      AND split_part(member_item #>> '{entity,reference}', '/', 1) = 'Patient'
      AND dwh.fhir_ref_id(member_item #>> '{entity,reference}') IS NOT NULL
    ON CONFLICT (household_id, patient_id) DO UPDATE SET
        member_reference = EXCLUDED.member_reference,
        member_entity_type = EXCLUDED.member_entity_type,
        inactive = EXCLUDED.inactive,
        dwh_updated_at = clock_timestamp();

    DELETE FROM dwh.dim_households;
    INSERT INTO dwh.dim_households (
        household_id, household_name, active, location_id, reporting_facility_name, reporting_dhis2_orgunit_uid,
        member_count, practitioner_tag_id, care_team_tag_id, organization_tag_id, location_tag_id, app_version,
        version_id, last_updated, airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        h.household_id,
        h.household_name,
        h.active,
        COALESCE(h.location_id, h.location_tag_id),
        dl.reporting_facility_name,
        dl.reporting_dhis2_orgunit_uid,
        COUNT(b.patient_id) FILTER (WHERE b.inactive = false),
        h.practitioner_tag_id,
        h.care_team_tag_id,
        h.organization_tag_id,
        h.location_tag_id,
        h.app_version,
        h.version_id,
        h.last_updated,
        h.airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.stg_households h
    LEFT JOIN dwh.bridge_household_members b ON b.household_id = h.household_id
    LEFT JOIN dwh.dim_locations dl ON dl.location_id = COALESCE(h.location_id, h.location_tag_id)
    GROUP BY h.household_id, h.household_name, h.active, COALESCE(h.location_id, h.location_tag_id), dl.reporting_facility_name,
        dl.reporting_dhis2_orgunit_uid, h.practitioner_tag_id, h.care_team_tag_id, h.organization_tag_id, h.location_tag_id,
        h.app_version, h.version_id, h.last_updated, h.airbyte_extracted_at;

    DELETE FROM dwh.dim_patients;
    INSERT INTO dwh.dim_patients (
        patient_id, full_name, family_name, given_name, gender, birth_date, phone_number,
        active, deceased_boolean, deceased_datetime, is_deceased, age_years_today, age_group_today,
        is_woman_of_reproductive_age_today, household_id, household_name, location_id,
        reporting_facility_name, reporting_dhis2_orgunit_uid,
        practitioner_tag_id, care_team_tag_id, organization_tag_id, location_tag_id, app_version,
        version_id, last_updated, airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        p.patient_id,
        p.full_name,
        p.family_name,
        p.given_name,
        p.gender,
        p.birth_date,
        p.phone_number,
        p.active,
        p.deceased_boolean,
        p.deceased_datetime,
        COALESCE(p.deceased_boolean, p.deceased_datetime IS NOT NULL, false),
        dwh.age_in_years(p.birth_date, CURRENT_DATE),
        dwh.reporting_age_group(p.birth_date, CURRENT_DATE),
        dwh.is_woman_of_reproductive_age(p.gender, p.birth_date, CURRENT_DATE),
        b.household_id,
        h.household_name,
        COALESCE(h.location_id, p.location_tag_id),
        dl.reporting_facility_name,
        dl.reporting_dhis2_orgunit_uid,
        p.practitioner_tag_id,
        p.care_team_tag_id,
        p.organization_tag_id,
        p.location_tag_id,
        p.app_version,
        p.version_id,
        p.last_updated,
        p.airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.stg_patients p
    LEFT JOIN dwh.bridge_household_members b ON b.patient_id = p.patient_id AND b.inactive = false
    LEFT JOIN dwh.stg_households h ON h.household_id = b.household_id
    LEFT JOIN dwh.dim_locations dl ON dl.location_id = COALESCE(h.location_id, p.location_tag_id);

    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'success', rows_processed = v_total_rows_processed, error_message = NULL
    WHERE table_name = 'dwh.client_dimensions';
EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'failed', error_message = SQLERRM
    WHERE table_name = 'dwh.client_dimensions';
    RAISE;
END;
$$;
