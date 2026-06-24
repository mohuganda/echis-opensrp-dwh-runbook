CREATE OR REPLACE PROCEDURE dwh.refresh_admin_dimensions()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_processed integer;
BEGIN
    -------------------------------------------------------------------
    -- Refresh state start
    -------------------------------------------------------------------

    INSERT INTO dwh.refresh_state (
        table_name,
        last_run_started_at,
        status
    )
    VALUES (
        'dwh.dim_practitioner_assignments',
        now(),
        'running'
    )
    ON CONFLICT (table_name)
    DO UPDATE SET
        last_run_started_at = now(),
        status = 'running',
        error_message = NULL;

    -------------------------------------------------------------------
    -- 1. Refresh practitioners
    -------------------------------------------------------------------

    INSERT INTO dwh.stg_practitioners (
        practitioner_id,
        practitioner_name,
        family_name,
        given_name,
        gender,
        active,
        telecom_system,
        phone_number,
        official_identifier_value,
        secondary_identifier_value,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        p.resource ->> 'id' AS practitioner_id,

        dwh.fhir_human_name(p.resource -> 'name') AS practitioner_name,
        p.resource -> 'name' -> 0 ->> 'family' AS family_name,
        p.resource -> 'name' -> 0 -> 'given' ->> 0 AS given_name,

        p.resource ->> 'gender' AS gender,

        CASE
            WHEN lower(COALESCE(p.resource ->> 'active', 'true')) IN ('true', 't', 'yes', 'y', '1') THEN true
            WHEN lower(COALESCE(p.resource ->> 'active', '')) IN ('false', 'f', 'no', 'n', '0') THEN false
            ELSE true
        END AS active,

        p.resource -> 'telecom' -> 0 ->> 'system' AS telecom_system,
        p.resource -> 'telecom' -> 0 ->> 'value' AS phone_number,

        (
            SELECT i ->> 'value'
            FROM jsonb_array_elements(COALESCE(p.resource -> 'identifier', '[]'::jsonb)) i
            WHERE i ->> 'use' = 'official'
            LIMIT 1
        ) AS official_identifier_value,

        (
            SELECT i ->> 'value'
            FROM jsonb_array_elements(COALESCE(p.resource -> 'identifier', '[]'::jsonb)) i
            WHERE i ->> 'use' = 'secondary'
            LIMIT 1
        ) AS secondary_identifier_value,

        p.resource -> 'meta' ->> 'versionId' AS version_id,
        dwh.safe_timestamptz(p.resource -> 'meta' ->> 'lastUpdated') AS last_updated,

        p._airbyte_extracted_at,
        now()
    FROM airbyte.practitioner p
    WHERE p.resource ->> 'id' IS NOT NULL
    ON CONFLICT (practitioner_id)
    DO UPDATE SET
        practitioner_name = EXCLUDED.practitioner_name,
        family_name = EXCLUDED.family_name,
        given_name = EXCLUDED.given_name,
        gender = EXCLUDED.gender,
        active = EXCLUDED.active,
        telecom_system = EXCLUDED.telecom_system,
        phone_number = EXCLUDED.phone_number,
        official_identifier_value = EXCLUDED.official_identifier_value,
        secondary_identifier_value = EXCLUDED.secondary_identifier_value,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
    -- 2. Refresh organizations
    -------------------------------------------------------------------

    INSERT INTO dwh.stg_organizations (
        organization_id,
        organization_name,
        alias,
        active,
        type_code,
        type_system,
        type_display,
        parent_organization_id,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        o.resource ->> 'id' AS organization_id,
        o.resource ->> 'name' AS organization_name,
        o.resource -> 'alias' ->> 0 AS alias,

        CASE
            WHEN lower(COALESCE(o.resource ->> 'active', 'true')) IN ('true', 't', 'yes', 'y', '1') THEN true
            WHEN lower(COALESCE(o.resource ->> 'active', '')) IN ('false', 'f', 'no', 'n', '0') THEN false
            ELSE true
        END AS active,

        o.resource -> 'type' -> 0 -> 'coding' -> 0 ->> 'code' AS type_code,
        o.resource -> 'type' -> 0 -> 'coding' -> 0 ->> 'system' AS type_system,
        o.resource -> 'type' -> 0 -> 'coding' -> 0 ->> 'display' AS type_display,

        dwh.fhir_ref_id(o.resource -> 'partOf' ->> 'reference') AS parent_organization_id,

        o.resource -> 'meta' ->> 'versionId' AS version_id,
        dwh.safe_timestamptz(o.resource -> 'meta' ->> 'lastUpdated') AS last_updated,

        o._airbyte_extracted_at,
        now()
    FROM airbyte.organization o
    WHERE o.resource ->> 'id' IS NOT NULL
    ON CONFLICT (organization_id)
    DO UPDATE SET
        organization_name = EXCLUDED.organization_name,
        alias = EXCLUDED.alias,
        active = EXCLUDED.active,
        type_code = EXCLUDED.type_code,
        type_system = EXCLUDED.type_system,
        type_display = EXCLUDED.type_display,
        parent_organization_id = EXCLUDED.parent_organization_id,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
    -- 3. Refresh practitioner roles
    -------------------------------------------------------------------

    INSERT INTO dwh.stg_practitioner_roles (
        practitioner_role_id,
        practitioner_id,
        practitioner_name,
        organization_id,
        organization_name,
        active,
        role_code,
        role_system,
        role_display,
        is_supervisor_role,
        is_vht_role,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        pr.resource ->> 'id' AS practitioner_role_id,

        dwh.fhir_ref_id(pr.resource -> 'practitioner' ->> 'reference') AS practitioner_id,
        COALESCE(
            p.practitioner_name,
            pr.resource -> 'practitioner' ->> 'display'
        ) AS practitioner_name,

        dwh.fhir_ref_id(pr.resource -> 'organization' ->> 'reference') AS organization_id,
        COALESCE(
            org.organization_name,
            pr.resource -> 'organization' ->> 'display'
        ) AS organization_name,

        CASE
            WHEN lower(COALESCE(pr.resource ->> 'active', 'true')) IN ('true', 't', 'yes', 'y', '1') THEN true
            WHEN lower(COALESCE(pr.resource ->> 'active', '')) IN ('false', 'f', 'no', 'n', '0') THEN false
            ELSE true
        END AS active,

        pr.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'code' AS role_code,
        pr.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'system' AS role_system,
        pr.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'display' AS role_display,

        CASE
            WHEN lower(COALESCE(pr.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'display', '')) LIKE '%supervisor%'
              OR pr.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'code' = '236321002'
                THEN true
            ELSE false
        END AS is_supervisor_role,

        CASE
            WHEN pr.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'code' = '405623001'
              OR lower(COALESCE(pr.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'display', '')) LIKE '%assigned practitioner%'
                THEN true
            ELSE false
        END AS is_vht_role,

        pr.resource -> 'meta' ->> 'versionId' AS version_id,
        dwh.safe_timestamptz(pr.resource -> 'meta' ->> 'lastUpdated') AS last_updated,

        pr._airbyte_extracted_at,
        now()
    FROM airbyte.practitioner_role pr
    LEFT JOIN dwh.stg_practitioners p
        ON p.practitioner_id = dwh.fhir_ref_id(pr.resource -> 'practitioner' ->> 'reference')
    LEFT JOIN dwh.stg_organizations org
        ON org.organization_id = dwh.fhir_ref_id(pr.resource -> 'organization' ->> 'reference')
    WHERE pr.resource ->> 'id' IS NOT NULL
    ON CONFLICT (practitioner_role_id)
    DO UPDATE SET
        practitioner_id = EXCLUDED.practitioner_id,
        practitioner_name = EXCLUDED.practitioner_name,
        organization_id = EXCLUDED.organization_id,
        organization_name = EXCLUDED.organization_name,
        active = EXCLUDED.active,
        role_code = EXCLUDED.role_code,
        role_system = EXCLUDED.role_system,
        role_display = EXCLUDED.role_display,
        is_supervisor_role = EXCLUDED.is_supervisor_role,
        is_vht_role = EXCLUDED.is_vht_role,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
    -- 4. Refresh care teams
    -------------------------------------------------------------------

    INSERT INTO dwh.stg_care_teams (
        care_team_id,
        care_team_name,
        care_team_status,
        managing_organization_id,
        managing_organization_name,
        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        ct.resource ->> 'id' AS care_team_id,
        ct.resource ->> 'name' AS care_team_name,
        ct.resource ->> 'status' AS care_team_status,

        dwh.fhir_ref_id(ct.resource -> 'managingOrganization' -> 0 ->> 'reference') AS managing_organization_id,

        COALESCE(
            org.organization_name,
            ct.resource -> 'managingOrganization' -> 0 ->> 'display'
        ) AS managing_organization_name,

        ct.resource -> 'meta' ->> 'versionId' AS version_id,
        dwh.safe_timestamptz(ct.resource -> 'meta' ->> 'lastUpdated') AS last_updated,

        ct._airbyte_extracted_at,
        now()
    FROM airbyte.care_team ct
    LEFT JOIN dwh.stg_organizations org
        ON org.organization_id = dwh.fhir_ref_id(ct.resource -> 'managingOrganization' -> 0 ->> 'reference')
    WHERE ct.resource ->> 'id' IS NOT NULL
    ON CONFLICT (care_team_id)
    DO UPDATE SET
        care_team_name = EXCLUDED.care_team_name,
        care_team_status = EXCLUDED.care_team_status,
        managing_organization_id = EXCLUDED.managing_organization_id,
        managing_organization_name = EXCLUDED.managing_organization_name,
        version_id = EXCLUDED.version_id,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = now();

    -------------------------------------------------------------------
-- 5. Refresh care team members
-- Ignore Organization participants.
-- Deduplicate repeated Practitioner/PractitionerRole participants.
-------------------------------------------------------------------

TRUNCATE TABLE dwh.bridge_care_team_members;

INSERT INTO dwh.bridge_care_team_members (
    care_team_id,
    member_reference,
    member_resource_type,
    member_id,
    member_display,
    role_code,
    role_system,
    role_display,
    dwh_updated_at
)
WITH extracted_members AS (
    SELECT
        ct.resource ->> 'id' AS care_team_id,

        participant -> 'member' ->> 'reference' AS member_reference,

        split_part(participant -> 'member' ->> 'reference', '/', 1) AS member_resource_type,
        dwh.fhir_ref_id(participant -> 'member' ->> 'reference') AS member_id,
        participant -> 'member' ->> 'display' AS member_display,

        participant -> 'role' -> 0 -> 'coding' -> 0 ->> 'code' AS role_code,
        participant -> 'role' -> 0 -> 'coding' -> 0 ->> 'system' AS role_system,
        participant -> 'role' -> 0 -> 'coding' -> 0 ->> 'display' AS role_display,

        now() AS dwh_updated_at
    FROM airbyte.care_team ct
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(ct.resource -> 'participant', '[]'::jsonb)
    ) AS participant
    WHERE ct.resource ->> 'id' IS NOT NULL
      AND participant -> 'member' ->> 'reference' IS NOT NULL
      AND split_part(participant -> 'member' ->> 'reference', '/', 1)
            IN ('Practitioner', 'PractitionerRole')
),

deduped_members AS (
    SELECT DISTINCT ON (
        care_team_id,
        member_reference
    )
        care_team_id,
        member_reference,
        member_resource_type,
        member_id,
        member_display,
        role_code,
        role_system,
        role_display,
        dwh_updated_at
    FROM extracted_members
    ORDER BY
        care_team_id,
        member_reference,
        role_code NULLS LAST,
        role_display NULLS LAST
)

SELECT
    care_team_id,
    member_reference,
    member_resource_type,
    member_id,
    member_display,
    role_code,
    role_system,
    role_display,
    dwh_updated_at
FROM deduped_members;

    -------------------------------------------------------------------
    -- 6. Refresh organization affiliations
    -- This table already exists from the location setup.
    -------------------------------------------------------------------

    TRUNCATE TABLE dwh.dim_organization_affiliations;

    INSERT INTO dwh.dim_organization_affiliations (
        organization_affiliation_id,
        location_id,

        organization_id,
        organization_name,

        participating_organization_id,
        participating_organization_name,

        location_name,

        active,

        role_code,
        role_display,

        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        oa.resource ->> 'id' AS organization_affiliation_id,

        dwh.fhir_ref_id(location_item ->> 'reference') AS location_id,

        dwh.fhir_ref_id(oa.resource -> 'organization' ->> 'reference') AS organization_id,
        COALESCE(
            org.organization_name,
            oa.resource -> 'organization' ->> 'display'
        ) AS organization_name,

        dwh.fhir_ref_id(oa.resource -> 'participatingOrganization' ->> 'reference') AS participating_organization_id,
        COALESCE(
            participating_org.organization_name,
            oa.resource -> 'participatingOrganization' ->> 'display'
        ) AS participating_organization_name,

        COALESCE(
            loc.location_name,
            location_item ->> 'display'
        ) AS location_name,

        CASE
            WHEN lower(COALESCE(oa.resource ->> 'active', 'true')) IN ('true', 't', 'yes', 'y', '1') THEN true
            WHEN lower(COALESCE(oa.resource ->> 'active', '')) IN ('false', 'f', 'no', 'n', '0') THEN false
            ELSE true
        END AS active,

        oa.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'code' AS role_code,
        oa.resource -> 'code' -> 0 -> 'coding' -> 0 ->> 'display' AS role_display,

        dwh.safe_timestamptz(oa.resource -> 'meta' ->> 'lastUpdated') AS last_updated,
        oa._airbyte_extracted_at,
        now()
    FROM airbyte.organization_affiliation oa
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(oa.resource -> 'location', '[]'::jsonb)
    ) AS location_item
    LEFT JOIN dwh.stg_organizations org
        ON org.organization_id = dwh.fhir_ref_id(oa.resource -> 'organization' ->> 'reference')
    LEFT JOIN dwh.stg_organizations participating_org
        ON participating_org.organization_id = dwh.fhir_ref_id(oa.resource -> 'participatingOrganization' ->> 'reference')
    LEFT JOIN dwh.stg_locations loc
        ON loc.location_id = dwh.fhir_ref_id(location_item ->> 'reference')
    WHERE oa.resource ->> 'id' IS NOT NULL
      AND dwh.fhir_ref_id(location_item ->> 'reference') IS NOT NULL;

    -------------------------------------------------------------------
    -- 7. Update organization affiliation flags in dim_locations
    -- Do not rebuild full hierarchy here.
    -------------------------------------------------------------------

    UPDATE dwh.dim_locations dl
    SET
        has_organization_affiliation = false,
        organization_affiliation_count = 0,
        dwh_updated_at = now();

    UPDATE dwh.dim_locations dl
    SET
        has_organization_affiliation = true,
        organization_affiliation_count = oa.organization_affiliation_count,
        dwh_updated_at = now()
    FROM (
        SELECT
            location_id,
            COUNT(*) AS organization_affiliation_count
        FROM dwh.dim_organization_affiliations
        WHERE COALESCE(active, true) = true
        GROUP BY location_id
    ) oa
    WHERE dl.location_id = oa.location_id;

    -------------------------------------------------------------------
    -- 8. Refresh practitioner assignments
    -------------------------------------------------------------------

    TRUNCATE TABLE dwh.dim_practitioner_assignments;

    INSERT INTO dwh.dim_practitioner_assignments (
        assignment_id,

        practitioner_role_id,

        practitioner_id,
        practitioner_name,

        practitioner_active,
        practitioner_role_active,

        user_type,
        is_vht,
        is_supervisor,
        is_web_admin,

        role_code,
        role_system,
        role_display,

        care_team_id,
        care_team_name,

        organization_id,
        organization_name,

        assigned_location_id,
        assigned_location_name,

        country_name,

        region_id,
        region_name,

        district_id,
        district_name,

        county_id,
        county_name,

        subcounty_id,
        subcounty_name,

        parish_id,
        parish_name,

        health_facility_id,
        health_facility_name,

        village_id,
        village_name,

        mapping_level,

        reporting_facility_name,
        reporting_dhis2_orgunit_uid,

        has_location_assignment,
        has_dhis2_mapping,

        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    WITH care_team_practitioner_members AS (
        SELECT
            ctm.care_team_id,
            ctm.member_resource_type,
            ctm.member_id
        FROM dwh.bridge_care_team_members ctm
        WHERE ctm.member_resource_type IN ('Practitioner', 'PractitionerRole')
    ),

    role_to_care_team AS (
        -- Case 1: CareTeam participant references PractitionerRole directly
        SELECT
            pr.practitioner_role_id,
            ctm.care_team_id
        FROM dwh.stg_practitioner_roles pr
        JOIN care_team_practitioner_members ctm
            ON ctm.member_resource_type = 'PractitionerRole'
           AND ctm.member_id = pr.practitioner_role_id

        UNION

        -- Case 2: CareTeam participant references Practitioner
        SELECT
            pr.practitioner_role_id,
            ctm.care_team_id
        FROM dwh.stg_practitioner_roles pr
        JOIN care_team_practitioner_members ctm
            ON ctm.member_resource_type = 'Practitioner'
           AND ctm.member_id = pr.practitioner_id
    ),

    base AS (
        SELECT
            pr.practitioner_role_id,

            pr.practitioner_id,
            COALESCE(p.practitioner_name, pr.practitioner_name) AS practitioner_name,

            p.active AS practitioner_active,
            pr.active AS practitioner_role_active,

            pr.role_code,
            pr.role_system,
            pr.role_display,
            pr.is_supervisor_role,
            pr.is_vht_role,

            ct.care_team_id,
            ct.care_team_name,

            COALESCE(
                ct.managing_organization_id,
                pr.organization_id
            ) AS resolved_organization_id,

            COALESCE(
                ct.managing_organization_name,
                pr.organization_name
            ) AS resolved_organization_name,

            pr.last_updated,
            pr.airbyte_extracted_at
        FROM dwh.stg_practitioner_roles pr
        LEFT JOIN dwh.stg_practitioners p
            ON p.practitioner_id = pr.practitioner_id
        LEFT JOIN role_to_care_team rtc
            ON rtc.practitioner_role_id = pr.practitioner_role_id
        LEFT JOIN dwh.stg_care_teams ct
            ON ct.care_team_id = rtc.care_team_id
    ),

    org_locations AS (
        SELECT
            organization_id,
            organization_name,
            location_id,
            location_name
        FROM dwh.dim_organization_affiliations
        WHERE COALESCE(active, true) = true
          AND organization_id IS NOT NULL

        UNION

        SELECT
            participating_organization_id AS organization_id,
            participating_organization_name AS organization_name,
            location_id,
            location_name
        FROM dwh.dim_organization_affiliations
        WHERE COALESCE(active, true) = true
          AND participating_organization_id IS NOT NULL
    ),

    resolved AS (
        SELECT
            b.*,

            ol.location_id AS assigned_location_id,
            ol.location_name AS assigned_location_name,

            dl.country_name,

            dl.region_id,
            dl.region_name,

            dl.district_id,
            dl.district_name,

            dl.county_id,
            dl.county_name,

            dl.subcounty_id,
            dl.subcounty_name,

            dl.parish_id,
            dl.parish_name,

            dl.health_facility_id,
            dl.health_facility_name,

            dl.village_id,
            dl.village_name,

            dl.mapping_level,

            dl.reporting_facility_name,
            dl.reporting_dhis2_orgunit_uid,

            COALESCE(dl.has_dhis2_mapping, false) AS has_dhis2_mapping
        FROM base b
        LEFT JOIN org_locations ol
            ON ol.organization_id = b.resolved_organization_id
        LEFT JOIN dwh.dim_locations dl
            ON dl.location_id = ol.location_id
    )

    SELECT
        md5(
            COALESCE(r.practitioner_role_id, '') || '|' ||
            COALESCE(r.care_team_id, '') || '|' ||
            COALESCE(r.resolved_organization_id, '') || '|' ||
            COALESCE(r.assigned_location_id, '')
        ) AS assignment_id,

        r.practitioner_role_id,

        r.practitioner_id,
        r.practitioner_name,

        r.practitioner_active,
        r.practitioner_role_active,

        CASE
            WHEN r.assigned_location_id IS NULL THEN 'web_admin'
            WHEN r.is_supervisor_role = true THEN 'supervisor'
            ELSE 'vht'
        END AS user_type,

        CASE
            WHEN r.assigned_location_id IS NOT NULL
             AND COALESCE(r.is_supervisor_role, false) = false
                THEN true
            ELSE false
        END AS is_vht,

        COALESCE(r.is_supervisor_role, false) AS is_supervisor,

        CASE
            WHEN r.assigned_location_id IS NULL THEN true
            ELSE false
        END AS is_web_admin,

        r.role_code,
        r.role_system,
        r.role_display,

        r.care_team_id,
        r.care_team_name,

        r.resolved_organization_id AS organization_id,
        r.resolved_organization_name AS organization_name,

        r.assigned_location_id,
        r.assigned_location_name,

        r.country_name,

        r.region_id,
        r.region_name,

        r.district_id,
        r.district_name,

        r.county_id,
        r.county_name,

        r.subcounty_id,
        r.subcounty_name,

        r.parish_id,
        r.parish_name,

        r.health_facility_id,
        r.health_facility_name,

        r.village_id,
        r.village_name,

        r.mapping_level,

        r.reporting_facility_name,
        r.reporting_dhis2_orgunit_uid,

        CASE
            WHEN r.assigned_location_id IS NOT NULL THEN true
            ELSE false
        END AS has_location_assignment,

        r.has_dhis2_mapping,

        r.last_updated,
        r.airbyte_extracted_at,
        now()
    FROM resolved r;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;

    -------------------------------------------------------------------
    -- Refresh state success
    -------------------------------------------------------------------

    UPDATE dwh.refresh_state
    SET
        last_run_completed_at = now(),
        status = 'success',
        rows_processed = v_rows_processed,
        error_message = NULL
    WHERE table_name = 'dwh.dim_practitioner_assignments';

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET
        last_run_completed_at = now(),
        status = 'failed',
        error_message = SQLERRM
    WHERE table_name = 'dwh.dim_practitioner_assignments';

    RAISE;
END;
$$;