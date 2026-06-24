-- NOTE: This file should contain the latest semi-incremental refresh_supply_cebs_reporting procedure.
-- The version included here is generated from the current working body and should be reviewed in the target DB.
-- It intentionally keeps dim_commodities and dim_current_commodity_stock as rebuild snapshots.

CREATE OR REPLACE PROCEDURE dwh.refresh_supply_cebs_reporting()
LANGUAGE plpgsql
AS $$

DECLARE
    v_total_rows_processed integer := 0;
    v_rows_processed integer := 0;
BEGIN
    INSERT INTO dwh.refresh_state (
        table_name,
        last_run_started_at,
        status
    )
    VALUES (
        'dwh.supply_cebs_reporting',
        clock_timestamp(),
        'running'
    )
    ON CONFLICT (table_name)
    DO UPDATE SET
        last_run_started_at = clock_timestamp(),
        status = 'running',
        error_message = NULL;

    -------------------------------------------------------------------
    -- Clear derived tables
    -------------------------------------------------------------------

    TRUNCATE TABLE dwh.dim_current_commodity_stock;
    -- Fact tables are not truncated in production semi-incremental refresh.
    -- Existing rows should be updated/deleted/reinserted only for changed IDs.
    -- See docs/refresh-strategy.md for the semi-incremental approach.
    TRUNCATE TABLE dwh.dim_commodities;

    -------------------------------------------------------------------
    -- 1. Commodities from Group resources
    -------------------------------------------------------------------

    INSERT INTO dwh.dim_commodities (
        commodity_id,

        commodity_name,

        group_type,
        group_actual,
        group_active,

        commodity_code_system,
        commodity_code,
        commodity_code_display,
        commodity_code_text,

        unit_system,
        unit_code,
        unit_display,
        unit_text,

        official_identifier,
        secondary_identifier,

        version_id,
        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT
        g.resource ->> 'id' AS commodity_id,

        g.resource ->> 'name' AS commodity_name,

        g.resource ->> 'type' AS group_type,
        NULLIF(g.resource ->> 'actual', '')::boolean AS group_actual,
        NULLIF(g.resource ->> 'active', '')::boolean AS group_active,

        g.resource #>> '{code,coding,0,system}' AS commodity_code_system,
        g.resource #>> '{code,coding,0,code}' AS commodity_code,
        g.resource #>> '{code,coding,0,display}' AS commodity_code_display,
        g.resource #>> '{code,text}' AS commodity_code_text,

        unit_characteristic.unit_system,
        unit_characteristic.unit_code,
        unit_characteristic.unit_display,
        unit_characteristic.unit_text,

        identifiers.official_identifier,
        identifiers.secondary_identifier,

        g.resource #>> '{meta,versionId}' AS version_id,
        NULLIF(g.resource #>> '{meta,lastUpdated}', '')::timestamptz AS last_updated,
        g._airbyte_extracted_at AS airbyte_extracted_at,
        clock_timestamp()
    FROM airbyte."group" g

    LEFT JOIN LATERAL (
        SELECT
            ch #>> '{valueCodeableConcept,coding,0,system}' AS unit_system,
            ch #>> '{valueCodeableConcept,coding,0,code}' AS unit_code,
            ch #>> '{valueCodeableConcept,coding,0,display}' AS unit_display,
            ch #>> '{valueCodeableConcept,text}' AS unit_text
        FROM jsonb_array_elements(
            COALESCE(g.resource -> 'characteristic', '[]'::jsonb)
        ) AS ch
        WHERE ch #>> '{code,coding,0,code}' = '767524001'
        LIMIT 1
    ) unit_characteristic ON true

    LEFT JOIN LATERAL (
        SELECT
            MAX(identifier_item ->> 'value') FILTER (
                WHERE identifier_item ->> 'use' = 'official'
            ) AS official_identifier,
            MAX(identifier_item ->> 'value') FILTER (
                WHERE identifier_item ->> 'use' = 'secondary'
            ) AS secondary_identifier
        FROM jsonb_array_elements(
            COALESCE(g.resource -> 'identifier', '[]'::jsonb)
        ) AS identifier_item
    ) identifiers ON true

    WHERE g.resource #>> '{code,coding,0,system}' = 'http://snomed.info/sct'
      AND g.resource #>> '{code,coding,0,code}' = '386452003';

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    -------------------------------------------------------------------
    -- 2. Commodity stock movements from supply Observations
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_commodity_stock_movements (
        observation_id,

        effective_datetime,
        issued_datetime,

        observation_status,

        commodity_id,
        commodity_name,
        commodity_default_unit,

        location_id,
        encounter_id,
        performer_practitioner_id,

        event_system,
        event_code,
        event_label,

        commodity_category_system,
        commodity_category_code,
        commodity_category_display,

        movement_system,
        movement_code,
        movement_display,
        movement_type,

        event_quantity,
        event_quantity_unit,
        event_quantity_code,
        event_quantity_system,

        running_balance,
        running_balance_unit,
        running_balance_code,
        running_balance_system,

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
        o.observation_id,

        o.effective_datetime,
        o.issued_datetime,

        o.observation_status,

        o.group_id AS commodity_id,
        dc.commodity_name,
        dc.unit_text AS commodity_default_unit,

        o.location_id,
        o.encounter_id,
        o.performer_practitioner_id,

        o.observation_system AS event_system,
        COALESCE(o.observation_code, o.observation_text) AS event_code,
        COALESCE(
            o.observation_display,
            o.observation_text,
            o.observation_code
        ) AS event_label,

        o.category_1_system AS commodity_category_system,
        o.category_1_code AS commodity_category_code,
        o.category_1_display AS commodity_category_display,

        o.category_2_system AS movement_system,
        o.category_2_code AS movement_code,
        o.category_2_display AS movement_display,

        CASE
            WHEN COALESCE(o.observation_code, o.observation_text) = 'consumption' THEN 'consumption'
            WHEN COALESCE(o.observation_code, o.observation_text) = 'restocked' THEN 'restock'
            WHEN COALESCE(o.observation_code, o.observation_text) IN (
                'physical-count-soh',
                'balance-before-restock',
                'balance-after-restock',
                'Physical Inventory count'
            ) THEN 'snapshot'
            WHEN COALESCE(o.observation_code, o.observation_text) IN (
                'expiry',
                'damage',
                'over-reporting'
            ) THEN 'negative_adjustment'
            WHEN COALESCE(o.observation_code, o.observation_text) IN (
                'donation',
                'under-reporting'
            ) THEN 'positive_adjustment'
            WHEN o.category_2_code = 'subtraction' THEN 'subtraction'
            WHEN o.category_2_code = 'addition' THEN 'addition'
            WHEN o.category_2_code = 'snapshot' THEN 'snapshot'
            ELSE 'other'
        END AS movement_type,

        o.value_quantity AS event_quantity,
        o.value_quantity_unit AS event_quantity_unit,
        o.value_quantity_code AS event_quantity_code,
        o.value_quantity_system AS event_quantity_system,

        c.value_quantity AS running_balance,
        c.value_quantity_unit AS running_balance_unit,
        c.value_quantity_code AS running_balance_code,
        c.value_quantity_system AS running_balance_system,

        o.practitioner_tag_id,
        o.care_team_tag_id,
        o.organization_tag_id,
        o.location_tag_id,
        o.app_version,

        o.version_id,
        o.last_updated,
        o.airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.fact_observations o
    LEFT JOIN dwh.fact_observation_components c
        ON c.observation_id = o.observation_id
       AND c.component_system = 'http://snomed.info/sct'
       AND c.component_code = '255619001'
    LEFT JOIN dwh.dim_commodities dc
        ON dc.commodity_id = o.group_id
    WHERE o.category_1_system = 'http://snomed.info/sct'
      AND o.category_1_code = '386452003'
      AND o.group_id IS NOT NULL;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    -------------------------------------------------------------------
    -- 3. Current commodity stock from preliminary observations
    -------------------------------------------------------------------

    INSERT INTO dwh.dim_current_commodity_stock (
        commodity_id,

        commodity_name,
        commodity_default_unit,

        observation_id,
        effective_datetime,

        event_code,
        event_label,
        movement_type,

        running_balance,
        running_balance_unit,

        location_id,
        practitioner_tag_id,
        care_team_tag_id,
        organization_tag_id,
        location_tag_id,

        last_updated,
        airbyte_extracted_at,
        dwh_updated_at
    )
    SELECT DISTINCT ON (commodity_id)
        commodity_id,

        commodity_name,
        commodity_default_unit,

        observation_id,
        effective_datetime,

        event_code,
        event_label,
        movement_type,

        running_balance,
        COALESCE(running_balance_unit, commodity_default_unit) AS running_balance_unit,

        location_id,
        practitioner_tag_id,
        care_team_tag_id,
        organization_tag_id,
        location_tag_id,

        last_updated,
        airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.fact_commodity_stock_movements
    WHERE observation_status = 'preliminary'
    ORDER BY
        commodity_id,
        COALESCE(effective_datetime, last_updated, airbyte_extracted_at) DESC;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    -------------------------------------------------------------------
    -- 4. Commodity stockout flags
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_commodity_stockout_periods (
        flag_id,

        commodity_id,
        commodity_name,
        commodity_default_unit,

        flag_status,
        is_current_stockout,

        stockout_started_at,
        stockout_ended_at,
        stockout_duration,

        flag_system,
        flag_code,
        flag_display,
        flag_text,

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
        f.flag_id,

        f.group_id AS commodity_id,
        dc.commodity_name,
        dc.unit_text AS commodity_default_unit,

        f.flag_status,

        CASE
            WHEN lower(COALESCE(f.flag_status, '')) = 'active' THEN true
            ELSE false
        END AS is_current_stockout,

        f.period_start AS stockout_started_at,
        f.period_end AS stockout_ended_at,

        CASE
            WHEN f.period_start IS NOT NULL THEN
                COALESCE(f.period_end, clock_timestamp()) - f.period_start
            ELSE NULL
        END AS stockout_duration,

        f.flag_system,
        f.flag_code,
        f.flag_display,
        f.flag_text,

        f.practitioner_tag_id,
        f.care_team_tag_id,
        f.organization_tag_id,
        f.location_tag_id,
        f.app_version,

        f.version_id,
        f.last_updated,
        f.airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.fact_flags f
    LEFT JOIN dwh.dim_commodities dc
        ON dc.commodity_id = f.group_id
    WHERE f.flag_system = 'http://snomed.info/sct'
      AND f.flag_code = '419182006'
      AND f.group_id IS NOT NULL;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    -------------------------------------------------------------------
    -- 5. CEBS observation components
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_cebs_observation_components (
        observation_id,
        component_index,

        effective_datetime,
        issued_datetime,

        observation_status,

        location_id,
        encounter_id,
        performer_practitioner_id,

        signal_system,
        signal_code,
        signal_label,
        signal_description,

        cebs_category_system,
        cebs_category_code,
        cebs_category_display,

        component_system,
        component_code,
        component_display,
        component_text,
        component_label,

        value_string,
        value_boolean,
        value_quantity,
        value_quantity_unit,
        value_quantity_code,
        value_quantity_system,
        value_datetime,

        value_codeable_concept_code,
        value_codeable_concept_system,
        value_codeable_concept_display,
        value_codeable_concept_text,

        component_value_text,

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
        o.observation_id,
        component_item.ordinality::integer AS component_index,

        o.effective_datetime,
        o.issued_datetime,

        o.observation_status,

        o.location_id,
        o.encounter_id,
        o.performer_practitioner_id,

        o.observation_system AS signal_system,
        o.observation_code AS signal_code,
        COALESCE(
            o.observation_display,
            o.observation_text,
            o.observation_code
        ) AS signal_label,
        o.value_string AS signal_description,

        o.category_1_system AS cebs_category_system,
        o.category_1_code AS cebs_category_code,
        o.category_1_display AS cebs_category_display,

        component_item.component #>> '{code,coding,0,system}' AS component_system,
        component_item.component #>> '{code,coding,0,code}' AS component_code,
        component_item.component #>> '{code,coding,0,display}' AS component_display,
        component_item.component #>> '{code,text}' AS component_text,
        COALESCE(
            component_item.component #>> '{code,coding,0,display}',
            component_item.component #>> '{code,text}',
            component_item.component #>> '{code,coding,0,code}'
        ) AS component_label,

        component_item.component ->> 'valueString' AS value_string,
        NULLIF(component_item.component ->> 'valueBoolean', '')::boolean AS value_boolean,
        NULLIF(component_item.component #>> '{valueQuantity,value}', '')::numeric AS value_quantity,
        component_item.component #>> '{valueQuantity,unit}' AS value_quantity_unit,
        component_item.component #>> '{valueQuantity,code}' AS value_quantity_code,
        component_item.component #>> '{valueQuantity,system}' AS value_quantity_system,

        CASE
            WHEN NULLIF(component_item.component ->> 'valueDateTime', '') IS NOT NULL THEN
                NULLIF(component_item.component ->> 'valueDateTime', '')::timestamptz
            ELSE NULL
        END AS value_datetime,

        component_item.component #>> '{valueCodeableConcept,coding,0,code}' AS value_codeable_concept_code,
        component_item.component #>> '{valueCodeableConcept,coding,0,system}' AS value_codeable_concept_system,
        component_item.component #>> '{valueCodeableConcept,coding,0,display}' AS value_codeable_concept_display,
        component_item.component #>> '{valueCodeableConcept,text}' AS value_codeable_concept_text,

        COALESCE(
            component_item.component ->> 'valueString',
            component_item.component #>> '{valueCodeableConcept,coding,0,display}',
            component_item.component #>> '{valueCodeableConcept,text}',
            component_item.component #>> '{valueQuantity,value}',
            component_item.component ->> 'valueBoolean',
            component_item.component ->> 'valueDateTime'
        ) AS component_value_text,

        o.practitioner_tag_id,
        o.care_team_tag_id,
        o.organization_tag_id,
        o.location_tag_id,
        o.app_version,

        o.version_id,
        o.last_updated,
        o.airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.fact_observations o
    JOIN airbyte.observation raw_observation
        ON raw_observation.resource ->> 'id' = o.observation_id
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(raw_observation.resource -> 'component', '[]'::jsonb)
    ) WITH ORDINALITY AS component_item(component, ordinality)
    WHERE o.category_1_system = 'http://moh.go.ug/CodeSystem/cebs-category'
      AND o.category_1_code IN (
          'surveillance',
          'surveillance-no-signal'
      );

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    -------------------------------------------------------------------
    -- 6. CEBS wide/reporting observations
    -------------------------------------------------------------------

    INSERT INTO dwh.fact_cebs_observations (
        observation_id,

        effective_datetime,
        issued_datetime,

        observation_status,
        cebs_status_label,
        has_signal,

        location_id,
        encounter_id,
        performer_practitioner_id,

        signal_system,
        signal_code,
        signal_label,
        reviewed_signal_label,
        signal_description,

        cebs_category_system,
        cebs_category_code,
        cebs_category_display,

        vht_name,
        vht_phone,
        vht_village,
        reporter_practitioner_id,

        latitude,
        longitude,

        verification_method,
        supervisor_signal_description,
        vht_signal_description,

        chew_people_ill,
        chew_people_dead,
        chew_animals_involved,
        chew_animals_affected,
        chew_animals_dead,

        threat_start_time,
        threat_start_datetime,

        facility_informed_date,
        facility_informed_datetime,

        animal_health_referral,
        additional_information,

        chew_verification_timestamp,
        chew_verification_datetime,

        chew_name,
        chew_phone,

        verifier_practitioner_id,

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
        c.observation_id,

        MAX(c.effective_datetime) AS effective_datetime,
        MAX(c.issued_datetime) AS issued_datetime,

        MAX(c.observation_status) AS observation_status,

        CASE
            WHEN MAX(c.observation_status) = 'preliminary' THEN 'awaiting_verification'
            WHEN MAX(c.observation_status) = 'final'
                 AND MAX(c.cebs_category_code) = 'surveillance' THEN 'verified_threat'
            WHEN MAX(c.observation_status) = 'final'
                 AND MAX(c.cebs_category_code) = 'surveillance-no-signal' THEN 'no_signal'
            WHEN MAX(c.observation_status) = 'cancelled' THEN 'dismissed'
            ELSE MAX(c.observation_status)
        END AS cebs_status_label,

        CASE
            WHEN MAX(c.cebs_category_code) = 'surveillance-no-signal' THEN false
            WHEN MAX(c.cebs_category_code) = 'surveillance' THEN true
            ELSE NULL
        END AS has_signal,

        MAX(c.location_id) AS location_id,
        MAX(c.encounter_id) AS encounter_id,
        MAX(c.performer_practitioner_id) AS performer_practitioner_id,

        MAX(c.signal_system) AS signal_system,
        MAX(c.signal_code) AS signal_code,
        MAX(c.signal_label) AS signal_label,
        COALESCE(MAX(r.signal_label), MAX(c.signal_label)) AS reviewed_signal_label,
        MAX(c.signal_description) AS signal_description,

        MAX(c.cebs_category_system) AS cebs_category_system,
        MAX(c.cebs_category_code) AS cebs_category_code,
        MAX(c.cebs_category_display) AS cebs_category_display,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-data'
              AND c.component_code = 'vht-name'
        ) AS vht_name,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-data'
              AND c.component_code = 'vht-phone'
        ) AS vht_phone,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-data'
              AND c.component_code = 'vht-village'
        ) AS vht_village,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-data'
              AND c.component_code = 'reporter-id'
        ) AS reporter_practitioner_id,

        MAX(c.value_quantity) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-location'
              AND c.component_code = 'latitude'
        ) AS latitude,

        MAX(c.value_quantity) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-location'
              AND c.component_code = 'longitude'
        ) AS longitude,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'verification-method'
        ) AS verification_method,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'supervisor-signal-description'
        ) AS supervisor_signal_description,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'vht-signal-description'
        ) AS vht_signal_description,

        MAX(c.value_quantity) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-people-ill'
        ) AS chew_people_ill,

        MAX(c.value_quantity) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-people-dead'
        ) AS chew_people_dead,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-animals-involved'
        ) AS chew_animals_involved,

        MAX(c.value_quantity) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-animals-affected'
        ) AS chew_animals_affected,

        MAX(c.value_quantity) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-animals-dead'
        ) AS chew_animals_dead,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'threat-start-time'
        ) AS threat_start_time,

        MAX(c.value_datetime) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'threat-start-time'
        ) AS threat_start_datetime,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'facility-informed-date'
        ) AS facility_informed_date,

        MAX(c.value_datetime) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'facility-informed-date'
        ) AS facility_informed_datetime,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'animal-health-referral'
        ) AS animal_health_referral,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'additional-information'
        ) AS additional_information,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-verification-timestamp'
        ) AS chew_verification_timestamp,

        MAX(c.value_datetime) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-verification-timestamp'
        ) AS chew_verification_datetime,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-name'
        ) AS chew_name,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-verification'
              AND c.component_code = 'chew-phone'
        ) AS chew_phone,

        MAX(c.component_value_text) FILTER (
            WHERE c.component_system = 'http://moh.go.ug/CodeSystem/cebs-data'
              AND c.component_code = 'verifier-id'
        ) AS verifier_practitioner_id,

        MAX(c.practitioner_tag_id) AS practitioner_tag_id,
        MAX(c.care_team_tag_id) AS care_team_tag_id,
        MAX(c.organization_tag_id) AS organization_tag_id,
        MAX(c.location_tag_id) AS location_tag_id,
        MAX(c.app_version) AS app_version,

        MAX(c.version_id) AS version_id,
        MAX(c.last_updated) AS last_updated,
        MAX(c.airbyte_extracted_at) AS airbyte_extracted_at,
        clock_timestamp()
    FROM dwh.fact_cebs_observation_components c
    LEFT JOIN dwh.ref_cebs_signal_types r
        ON r.signal_code = c.signal_code
       AND r.include_in_reporting = true
    GROUP BY c.observation_id;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;
    v_total_rows_processed := v_total_rows_processed + v_rows_processed;

    -------------------------------------------------------------------
    -- Refresh state success
    -------------------------------------------------------------------

    UPDATE dwh.refresh_state
    SET
        last_run_completed_at = clock_timestamp(),
        status = 'success',
        rows_processed = v_total_rows_processed,
        error_message = NULL
    WHERE table_name = 'dwh.supply_cebs_reporting';

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET
        last_run_completed_at = clock_timestamp(),
        status = 'failed',
        error_message = SQLERRM
    WHERE table_name = 'dwh.supply_cebs_reporting';

    RAISE;
END;

$$;
