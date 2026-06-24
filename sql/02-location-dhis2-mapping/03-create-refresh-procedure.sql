-- 02-location-dhis2-mapping/03-create-refresh-procedure.sql
-- Refreshes stg_locations, dim_organization_affiliations, and dim_locations.

CREATE OR REPLACE PROCEDURE dwh.refresh_locations()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_processed integer := 0;
    v_total_rows_processed integer := 0;
BEGIN
    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES ('dwh.dim_locations', clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET last_run_started_at = EXCLUDED.last_run_started_at, status = 'running', error_message = NULL;

    INSERT INTO dwh.stg_locations (
        location_id, location_name, location_status, location_type_code, location_type_display,
        parent_location_id, is_jurisdiction_location, is_household_location,
        latitude, longitude, last_updated, airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        l.resource ->> 'id' AS location_id,
        l.resource ->> 'name' AS location_name,
        l.resource ->> 'status' AS location_status,
        l.resource #>> '{type,0,coding,0,code}' AS location_type_code,
        l.resource #>> '{type,0,coding,0,display}' AS location_type_display,
        dwh.fhir_ref_id(l.resource #>> '{partOf,reference}') AS parent_location_id,
        CASE
            WHEN l.resource #>> '{type,0,coding,0,code}' = 'PTRES' THEN false
            ELSE true
        END AS is_jurisdiction_location,
        CASE WHEN l.resource #>> '{type,0,coding,0,code}' = 'PTRES' THEN true ELSE false END AS is_household_location,
        dwh.safe_numeric(l.resource #>> '{position,latitude}') AS latitude,
        dwh.safe_numeric(l.resource #>> '{position,longitude}') AS longitude,
        dwh.safe_timestamptz(l.resource #>> '{meta,lastUpdated}') AS last_updated,
        l._airbyte_extracted_at AS airbyte_extracted_at,
        clock_timestamp()
    FROM airbyte.location l
    WHERE l.resource ->> 'id' IS NOT NULL
    ON CONFLICT (location_id)
    DO UPDATE SET
        location_name = EXCLUDED.location_name,
        location_status = EXCLUDED.location_status,
        location_type_code = EXCLUDED.location_type_code,
        location_type_display = EXCLUDED.location_type_display,
        parent_location_id = EXCLUDED.parent_location_id,
        is_jurisdiction_location = EXCLUDED.is_jurisdiction_location,
        is_household_location = EXCLUDED.is_household_location,
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = clock_timestamp();

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    DELETE FROM dwh.dim_organization_affiliations;

    INSERT INTO dwh.dim_organization_affiliations (
        organization_affiliation_id, location_id, organization_id, organization_name,
        participating_organization_id, participating_organization_name, location_name,
        active, role_code, role_display, last_updated, airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        oa.resource ->> 'id' AS organization_affiliation_id,
        dwh.fhir_ref_id(location_item ->> 'reference') AS location_id,
        dwh.fhir_ref_id(oa.resource #>> '{organization,reference}') AS organization_id,
        org.resource ->> 'name' AS organization_name,
        dwh.fhir_ref_id(oa.resource #>> '{participatingOrganization,reference}') AS participating_organization_id,
        porg.resource ->> 'name' AS participating_organization_name,
        loc.location_name,
        COALESCE(NULLIF(oa.resource ->> 'active', '')::boolean, true) AS active,
        oa.resource #>> '{code,0,coding,0,code}' AS role_code,
        oa.resource #>> '{code,0,coding,0,display}' AS role_display,
        dwh.safe_timestamptz(oa.resource #>> '{meta,lastUpdated}') AS last_updated,
        oa._airbyte_extracted_at,
        clock_timestamp()
    FROM airbyte.organization_affiliation oa
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(oa.resource -> 'location', '[]'::jsonb)) AS location_item
    LEFT JOIN airbyte.organization org
        ON org.resource ->> 'id' = dwh.fhir_ref_id(oa.resource #>> '{organization,reference}')
    LEFT JOIN airbyte.organization porg
        ON porg.resource ->> 'id' = dwh.fhir_ref_id(oa.resource #>> '{participatingOrganization,reference}')
    LEFT JOIN dwh.stg_locations loc
        ON loc.location_id = dwh.fhir_ref_id(location_item ->> 'reference')
    WHERE oa.resource ->> 'id' IS NOT NULL
      AND dwh.fhir_ref_id(location_item ->> 'reference') IS NOT NULL
    ON CONFLICT (organization_affiliation_id, location_id)
    DO UPDATE SET
        organization_id = EXCLUDED.organization_id,
        organization_name = EXCLUDED.organization_name,
        participating_organization_id = EXCLUDED.participating_organization_id,
        participating_organization_name = EXCLUDED.participating_organization_name,
        location_name = EXCLUDED.location_name,
        active = EXCLUDED.active,
        role_code = EXCLUDED.role_code,
        role_display = EXCLUDED.role_display,
        last_updated = EXCLUDED.last_updated,
        airbyte_extracted_at = EXCLUDED.airbyte_extracted_at,
        dwh_updated_at = clock_timestamp();

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    DELETE FROM dwh.dim_locations;

    INSERT INTO dwh.dim_locations (
        location_id, location_name, location_status, location_type_code, location_type_display,
        parent_location_id, country_id, country_name, region_id, region_name, district_id, district_name,
        county_id, county_name, subcounty_id, subcounty_name, parish_id, parish_name,
        health_facility_id, health_facility_name, village_id, village_name, is_leaf_location,
        has_dhis2_mapping, has_organization_affiliation, organization_affiliation_count,
        mapping_level, raw_hierarchy_depth, admin_path_depth, reporting_facility_name,
        reporting_dhis2_orgunit_uid, latitude, longitude, last_updated, airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        t.location_id,
        t.location_name,
        t.location_status,
        t.location_type_code,
        t.location_type_display,
        t.parent_location_id,
        t.admin_path_ids[1], t.admin_path_names[1],
        t.admin_path_ids[1], t.admin_path_names[1],
        t.admin_path_ids[2], t.admin_path_names[2],
        t.admin_path_ids[3], t.admin_path_names[3],
        t.admin_path_ids[4], t.admin_path_names[4],
        t.admin_path_ids[5], t.admin_path_names[5],
        CASE WHEN t.admin_path_depth >= 6 THEN t.admin_path_ids[6] END,
        CASE WHEN t.admin_path_depth >= 6 THEN t.admin_path_names[6] END,
        CASE WHEN t.admin_path_depth >= 7 THEN t.admin_path_ids[7] ELSE t.location_id END,
        CASE WHEN t.admin_path_depth >= 7 THEN t.admin_path_names[7] ELSE t.location_name END,
        t.is_leaf_location,
        t.has_dhis2_mapping,
        COALESCE(aff.affiliation_count, 0) > 0,
        COALESCE(aff.affiliation_count, 0),
        CASE
            WHEN t.reporting_dhis2_orgunit_uid IS NULL THEN NULL
            WHEN t.admin_path_depth >= 7 THEN 'village_zone'
            WHEN t.admin_path_depth = 6 THEN 'health_facility'
            ELSE 'other_assigned_location'
        END AS mapping_level,
        t.hierarchy_depth,
        t.admin_path_depth,
        t.reporting_facility_name,
        t.reporting_dhis2_orgunit_uid,
        t.latitude,
        t.longitude,
        t.last_updated,
        t.airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.v_location_tree_clean t
    LEFT JOIN (
        SELECT location_id, COUNT(*) AS affiliation_count
        FROM dwh.dim_organization_affiliations
        WHERE active = true
        GROUP BY location_id
    ) aff ON aff.location_id = t.location_id;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'success', rows_processed = v_total_rows_processed, error_message = NULL
    WHERE table_name = 'dwh.dim_locations';
EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET last_run_completed_at = clock_timestamp(), status = 'failed', error_message = SQLERRM
    WHERE table_name = 'dwh.dim_locations';
    RAISE;
END;
$$;
