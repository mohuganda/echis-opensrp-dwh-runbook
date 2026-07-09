-- eCHIS OpenSRP DWH - Immunization monthly aggregate and report MV
--
-- Architecture:
--   dwh.fact_immunizations             — administered doses, kept forever
--   dwh.fact_immunization_status       — operational line-list (managed by 03-create-refresh-procedures.sql)
--   dwh.agg_immunization_monthly       — permanent monthly aggregate history (Sept 2023 onwards)
--   dwh.mv_immunization_monthly_report — BI-friendly view over the aggregate
--
-- The aggregate is built directly from fact_immunizations + dim_patients + ref_immunization_vaccine_map.
-- It has no dependency on fact_immunization_status.
--
-- Daily call (after refresh_immunization_facts):
--   CALL dwh.refresh_immunization_monthly_aggregates();
--   CALL dwh.refresh_immunization_monthly_report_mv();
--
-- One-time historical backfill (run once after initial setup):
--   CALL dwh.refresh_immunization_monthly_aggregate_backfill('2023-09-01');

BEGIN;

CREATE TABLE IF NOT EXISTS dwh.agg_immunization_monthly (
    reporting_month             date        NOT NULL,
    reporting_period_start      date        NOT NULL,
    reporting_period_end        date        NOT NULL,

    location_level              text        NOT NULL,
    location_id                 text        NOT NULL,
    location_name               text,

    district_id                 text,
    district_name               text,
    subcounty_id                text,
    subcounty_name              text,
    parish_id                   text,
    parish_name                 text,
    health_facility_id          text,
    health_facility_name        text,
    village_id                  text,
    village_name                text,
    reporting_dhis2_orgunit_uid text,

    report_section              text        NOT NULL,
    indicator_code              text        NOT NULL,
    indicator_name              text        NOT NULL,
    indicator_group             text        NOT NULL,

    programme                   text,
    antigen_group               text,
    vaccine_name                text,
    dose_label                  text,
    dose_number                 integer,
    dimension_key               text        NOT NULL DEFAULT 'all',

    numerator                   numeric,
    denominator                 numeric,
    indicator_value             numeric,

    eligible_count              integer     NOT NULL DEFAULT 0,
    due_count                   integer     NOT NULL DEFAULT 0,
    received_count              integer     NOT NULL DEFAULT 0,
    missed_count                integer     NOT NULL DEFAULT 0,
    late_received_count         integer     NOT NULL DEFAULT 0,
    zero_dose_count             integer     NOT NULL DEFAULT 0,
    under_immunised_count       integer     NOT NULL DEFAULT 0,
    recovered_this_period_count integer     NOT NULL DEFAULT 0,
    fic_eligible_count          integer     NOT NULL DEFAULT 0,
    fully_immunised_count       integer     NOT NULL DEFAULT 0,

    dwh_updated_at              timestamptz NOT NULL DEFAULT clock_timestamp(),

    PRIMARY KEY (reporting_month, location_level, location_id, indicator_code, dimension_key)
);

CREATE INDEX IF NOT EXISTS idx_agg_immunization_monthly_month
    ON dwh.agg_immunization_monthly (reporting_month);

CREATE INDEX IF NOT EXISTS idx_agg_immunization_monthly_location
    ON dwh.agg_immunization_monthly (
        location_level, district_id, subcounty_id, parish_id, health_facility_id, village_id
    );

CREATE INDEX IF NOT EXISTS idx_agg_immunization_monthly_indicator
    ON dwh.agg_immunization_monthly (report_section, indicator_code, programme, antigen_group, dose_label);

CREATE INDEX IF NOT EXISTS idx_agg_immunization_monthly_dhis2
    ON dwh.agg_immunization_monthly (reporting_dhis2_orgunit_uid);

COMMIT;

-- =============================================================================
-- Procedure: refresh one month of aggregates
-- Builds directly from fact_immunizations + dim_patients + ref_immunization_vaccine_map.
-- =============================================================================

CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_monthly_aggregate(
    p_reporting_month date
)
LANGUAGE plpgsql AS $$
DECLARE
    v_period_start   date    := date_trunc('month', p_reporting_month)::date;
    v_period_end     date    := (date_trunc('month', p_reporting_month) + INTERVAL '1 month')::date;
    v_table_name     text    := 'dwh.agg_immunization_monthly:' || date_trunc('month', p_reporting_month)::date::text;
    v_rows_processed integer := 0;
BEGIN
    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES (v_table_name, clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET
        last_run_started_at = EXCLUDED.last_run_started_at,
        status              = 'running',
        error_message       = NULL;

    DROP TABLE IF EXISTS _agg_pd;
    DROP TABLE IF EXISTS _agg_ps;

    -- -------------------------------------------------------------------------
    -- Step 1: patient × dose temp table
    -- One row per patient × expected vaccine dose.
    -- Equivalent to fact_immunization_status but not written to that table.
    -- -------------------------------------------------------------------------
    CREATE TEMP TABLE _agg_pd ON COMMIT DROP AS
    WITH received AS (
        SELECT DISTINCT ON (patient_id, programme, vaccine_name, dose_label)
            patient_id,
            programme,
            vaccine_name,
            dose_label,
            administered_date AS received_date
        FROM dwh.fact_immunizations
        WHERE administered_date < v_period_end
        ORDER BY patient_id, programme, vaccine_name, dose_label, administered_date
    ),
    under5_counts AS (
        SELECT
            patient_id,
            COUNT(*) FILTER (
                WHERE administered_date < v_period_end
                  AND programme = 'child_immunization'
            ) AS under5_received_count
        FROM dwh.fact_immunizations
        GROUP BY patient_id
    )
    SELECT
        p.patient_id,
        p.district_id,        p.district_name,
        p.subcounty_id,       p.subcounty_name,
        p.parish_id,          p.parish_name,
        p.health_facility_id, p.health_facility_name,
        p.village_id,         p.village_name,
        p.reporting_dhis2_orgunit_uid,
        m.programme,
        m.antigen_group,
        m.vaccine_name,
        m.dose_label,
        m.dose_number,
        m.is_fic_required,
        m.include_in_under5_reports,
        (p.birth_date + (m.due_age_days || ' days')::interval)::date              AS due_date,
        (p.birth_date + (m.max_age_days  || ' days')::interval)::date             AS max_due_date,
        COALESCE(
            (p.birth_date + (m.due_age_days || ' days')::interval)::date < v_period_end,
            false
        )                                                                           AS is_due,
        (r.received_date IS NOT NULL)                                               AS is_received,
        r.received_date,
        CASE
            WHEN r.received_date IS NOT NULL
             AND m.max_age_days IS NOT NULL
             AND r.received_date > (p.birth_date + (m.max_age_days || ' days')::interval)::date
            THEN true ELSE false
        END                                                                         AS is_late_received,
        CASE
            WHEN r.received_date >= v_period_start
             AND r.received_date <  v_period_end
            THEN true ELSE false
        END                                                                         AS is_received_this_period,
        CASE
            WHEN m.include_in_under5_reports
             AND COALESCE(u.under5_received_count, 0) = 0
            THEN true ELSE false
        END                                                                         AS is_zero_dose,
        CASE
            WHEN (p.birth_date + (m.due_age_days || ' days')::interval)::date < v_period_end
             AND r.received_date IS NULL
            THEN true ELSE false
        END                                                                         AS is_under_immunised
    FROM dwh.dim_patients p
    JOIN dwh.ref_immunization_vaccine_map m ON true
    LEFT JOIN received r
           ON r.patient_id                        = p.patient_id
          AND r.programme                         = m.programme
          AND REPLACE(r.vaccine_name, '_', '-')   = m.vaccine_name
          AND r.dose_label                        = m.dose_label
    LEFT JOIN under5_counts u ON u.patient_id = p.patient_id
    WHERE p.birth_date IS NOT NULL
      AND COALESCE(p.active,      true)  = true
      AND COALESCE(p.is_deceased, false) = false
      AND (
          (
              (m.include_in_child_immunization_reports OR m.include_in_malaria_reports)
              AND p.birth_date > v_period_end - INTERVAL '5 years'
          )
          OR (
              m.include_in_hpv_reports
              AND lower(COALESCE(p.gender, '')) IN ('female', 'f')
              AND dwh.age_in_years(p.birth_date, v_period_end) BETWEEN 9 AND 19
          )
      );

    -- -------------------------------------------------------------------------
    -- Step 2: patient summary flags — one row per patient
    -- -------------------------------------------------------------------------
    CREATE TEMP TABLE _agg_ps ON COMMIT DROP AS
    SELECT
        patient_id,
        district_id,        district_name,
        subcounty_id,       subcounty_name,
        parish_id,          parish_name,
        health_facility_id, health_facility_name,
        village_id,         village_name,
        reporting_dhis2_orgunit_uid,
        bool_or(is_zero_dose)                                                    AS is_zero_dose,
        bool_or(is_under_immunised)                                              AS is_under_immunised,
        bool_or(is_received_this_period)                                         AS recovered_this_period,
        COALESCE(
            bool_and(is_received)
                FILTER (WHERE programme = 'child_immunization' AND is_fic_required AND is_due),
            false
        )                                                                         AS is_fic,
        bool_or(programme = 'child_immunization' AND is_fic_required AND is_due) AS has_fic_doses_due
    FROM _agg_pd
    GROUP BY
        patient_id,
        district_id,        district_name,
        subcounty_id,       subcounty_name,
        parish_id,          parish_name,
        health_facility_id, health_facility_name,
        village_id,         village_name,
        reporting_dhis2_orgunit_uid;

    -- Remove previous data for this period
    DELETE FROM dwh.agg_immunization_monthly
    WHERE reporting_month = v_period_start;

    -- -------------------------------------------------------------------------
    -- Step 3: Insert aggregates for all location levels
    --
    -- The CROSS JOIN LATERAL includes parent context columns scoped to each level:
    --   national      → all parent columns NULL          (one row per antigen/dose)
    --   district      → district columns set, rest NULL  (one row per district)
    --   subcounty     → district + subcounty set, rest NULL
    --   parish        → district + subcounty + parish set, rest NULL
    --   health_facility → all except village set
    --   village       → all set
    -- -------------------------------------------------------------------------
    INSERT INTO dwh.agg_immunization_monthly (
        reporting_month, reporting_period_start, reporting_period_end,
        location_level, location_id, location_name,
        district_id, district_name, subcounty_id, subcounty_name,
        parish_id, parish_name, health_facility_id, health_facility_name,
        village_id, village_name, reporting_dhis2_orgunit_uid,
        report_section, indicator_code, indicator_name, indicator_group,
        programme, antigen_group, vaccine_name, dose_label, dose_number,
        dimension_key,
        numerator, denominator, indicator_value,
        eligible_count, due_count, received_count, missed_count, late_received_count,
        zero_dose_count, under_immunised_count, recovered_this_period_count,
        fic_eligible_count, fully_immunised_count,
        dwh_updated_at
    )

    -- ----- Dose coverage rows -----------------------------------------------
    SELECT
        v_period_start, v_period_start, v_period_end,
        l.location_level,
        l.location_id,
        MAX(l.location_name),
        MAX(l.district_id),        MAX(l.district_name),
        MAX(l.subcounty_id),       MAX(l.subcounty_name),
        MAX(l.parish_id),          MAX(l.parish_name),
        MAX(l.health_facility_id), MAX(l.health_facility_name),
        MAX(l.village_id),         MAX(l.village_name),
        MAX(l.reporting_dhis2_orgunit_uid),
        'coverage_by_antigen',
        upper(
            'IMM-COV-' ||
            regexp_replace(COALESCE(pd.programme,    'unknown'), '[^a-zA-Z0-9]+', '_', 'g') || '-' ||
            regexp_replace(COALESCE(pd.antigen_group,'unknown'), '[^a-zA-Z0-9]+', '_', 'g') || '-' ||
            COALESCE(
                pd.dose_number::text,
                regexp_replace(COALESCE(pd.dose_label, 'unknown'), '[^a-zA-Z0-9]+', '_', 'g')
            )
        ),
        COALESCE(pd.antigen_group, MAX(pd.vaccine_name), 'Unknown')
            || ' ' || COALESCE(pd.dose_label, '') || ' coverage',
        'Immunization coverage',
        pd.programme, pd.antigen_group, MAX(pd.vaccine_name), pd.dose_label, pd.dose_number,
        COALESCE(pd.programme, '') || '|' || COALESCE(pd.antigen_group, '') || '|' || COALESCE(pd.dose_label, ''),
        COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_due AND pd.is_received)::numeric,
        COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_due)::numeric,
        ROUND(
            100.0
            * COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_due AND pd.is_received)
            / NULLIF(COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_due), 0),
            1
        ),
        COUNT(DISTINCT pd.patient_id),
        COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_due),
        COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_due AND pd.is_received),
        COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_due AND NOT pd.is_received),
        COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_late_received),
        0, 0,
        COUNT(DISTINCT pd.patient_id) FILTER (WHERE pd.is_received_this_period),
        0, 0,
        clock_timestamp()
    FROM _agg_pd pd
    CROSS JOIN LATERAL (
        VALUES
            (
                'national'::text, 'national'::text, 'Uganda'::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'district',
                COALESCE(pd.district_id,   'unknown'), COALESCE(pd.district_name,   'Unknown District'),
                pd.district_id,   pd.district_name,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'subcounty',
                COALESCE(pd.subcounty_id,  'unknown'), COALESCE(pd.subcounty_name,  'Unknown Subcounty'),
                pd.district_id,   pd.district_name,
                pd.subcounty_id,  pd.subcounty_name,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'parish',
                COALESCE(pd.parish_id,     'unknown'), COALESCE(pd.parish_name,     'Unknown Parish'),
                pd.district_id,   pd.district_name,
                pd.subcounty_id,  pd.subcounty_name,
                pd.parish_id,     pd.parish_name,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'health_facility',
                COALESCE(pd.health_facility_id,   'unknown'), COALESCE(pd.health_facility_name,   'Unknown Health Facility'),
                pd.district_id,        pd.district_name,
                pd.subcounty_id,       pd.subcounty_name,
                pd.parish_id,          pd.parish_name,
                pd.health_facility_id, pd.health_facility_name,
                NULL::text, NULL::text,
                pd.reporting_dhis2_orgunit_uid
            ),
            (
                'village',
                COALESCE(pd.village_id,   'unknown'), COALESCE(pd.village_name,   'Unknown Village'),
                pd.district_id,        pd.district_name,
                pd.subcounty_id,       pd.subcounty_name,
                pd.parish_id,          pd.parish_name,
                pd.health_facility_id, pd.health_facility_name,
                pd.village_id,         pd.village_name,
                pd.reporting_dhis2_orgunit_uid
            )
    ) AS l(
        location_level, location_id, location_name,
        district_id, district_name,
        subcounty_id, subcounty_name,
        parish_id, parish_name,
        health_facility_id, health_facility_name,
        village_id, village_name,
        reporting_dhis2_orgunit_uid
    )
    GROUP BY
        l.location_level, l.location_id,
        pd.programme, pd.antigen_group, pd.dose_label, pd.dose_number

    UNION ALL

    -- ----- Patient KPI rows --------------------------------------------------
    SELECT
        v_period_start, v_period_start, v_period_end,
        l.location_level,
        l.location_id,
        MAX(l.location_name),
        MAX(l.district_id),        MAX(l.district_name),
        MAX(l.subcounty_id),       MAX(l.subcounty_name),
        MAX(l.parish_id),          MAX(l.parish_name),
        MAX(l.health_facility_id), MAX(l.health_facility_name),
        MAX(l.village_id),         MAX(l.village_name),
        MAX(l.reporting_dhis2_orgunit_uid),
        'facility_kpi_summary',
        x.indicator_code,
        x.indicator_name,
        x.indicator_group,
        NULL::text, NULL::text, NULL::text, NULL::text, NULL::integer,
        'all',
        SUM(x.numerator_val),
        SUM(x.denominator_val),
        CASE
            WHEN x.indicator_code = 'IMM-FIC-COV'
            THEN ROUND(100.0 * SUM(x.numerator_val) / NULLIF(SUM(x.denominator_val), 0), 1)
            ELSE SUM(x.numerator_val)
        END,
        COUNT(DISTINCT ps.patient_id),
        0, 0, 0, 0,
        SUM(x.zero_dose_val),
        SUM(x.under_imm_val),
        SUM(x.recovered_val),
        SUM(x.fic_elig_val),
        SUM(x.fic_val),
        clock_timestamp()
    FROM _agg_ps ps
    CROSS JOIN LATERAL (
        VALUES
            (
                'national'::text, 'national'::text, 'Uganda'::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'district',
                COALESCE(ps.district_id,   'unknown'), COALESCE(ps.district_name,   'Unknown District'),
                ps.district_id,   ps.district_name,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'subcounty',
                COALESCE(ps.subcounty_id,  'unknown'), COALESCE(ps.subcounty_name,  'Unknown Subcounty'),
                ps.district_id,   ps.district_name,
                ps.subcounty_id,  ps.subcounty_name,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'parish',
                COALESCE(ps.parish_id,     'unknown'), COALESCE(ps.parish_name,     'Unknown Parish'),
                ps.district_id,   ps.district_name,
                ps.subcounty_id,  ps.subcounty_name,
                ps.parish_id,     ps.parish_name,
                NULL::text, NULL::text,
                NULL::text, NULL::text,
                NULL::text
            ),
            (
                'health_facility',
                COALESCE(ps.health_facility_id,   'unknown'), COALESCE(ps.health_facility_name,   'Unknown Health Facility'),
                ps.district_id,        ps.district_name,
                ps.subcounty_id,       ps.subcounty_name,
                ps.parish_id,          ps.parish_name,
                ps.health_facility_id, ps.health_facility_name,
                NULL::text, NULL::text,
                ps.reporting_dhis2_orgunit_uid
            ),
            (
                'village',
                COALESCE(ps.village_id,   'unknown'), COALESCE(ps.village_name,   'Unknown Village'),
                ps.district_id,        ps.district_name,
                ps.subcounty_id,       ps.subcounty_name,
                ps.parish_id,          ps.parish_name,
                ps.health_facility_id, ps.health_facility_name,
                ps.village_id,         ps.village_name,
                ps.reporting_dhis2_orgunit_uid
            )
    ) AS l(
        location_level, location_id, location_name,
        district_id, district_name,
        subcounty_id, subcounty_name,
        parish_id, parish_name,
        health_facility_id, health_facility_name,
        village_id, village_name,
        reporting_dhis2_orgunit_uid
    )
    CROSS JOIN LATERAL (
        VALUES
            (
                'IMM-ZD-OPEN'::text,
                'Zero-dose children'::text,
                'Zero-dose'::text,
                ps.is_zero_dose::int::numeric,
                NULL::numeric,
                ps.is_zero_dose::int,  0, 0, 0, 0
            ),
            (
                'IMM-UI-OPEN',
                'Under-immunised children',
                'Under-immunised',
                ps.is_under_immunised::int::numeric,
                NULL::numeric,
                0, ps.is_under_immunised::int, 0, 0, 0
            ),
            (
                'IMM-RECOVERED',
                'Children immunized this period',
                'Recovery',
                ps.recovered_this_period::int::numeric,
                NULL::numeric,
                0, 0, ps.recovered_this_period::int, 0, 0
            ),
            (
                'IMM-FIC-COV',
                'Fully immunised child coverage',
                'FIC',
                ps.is_fic::int::numeric,
                ps.has_fic_doses_due::int::numeric,
                0, 0, 0, ps.has_fic_doses_due::int, ps.is_fic::int
            )
    ) AS x(
        indicator_code, indicator_name, indicator_group,
        numerator_val, denominator_val,
        zero_dose_val, under_imm_val, recovered_val, fic_elig_val, fic_val
    )
    GROUP BY
        l.location_level, l.location_id,
        x.indicator_code, x.indicator_name, x.indicator_group;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;

    UPDATE dwh.refresh_state
    SET
        status                = 'success',
        rows_processed        = v_rows_processed,
        last_run_completed_at = clock_timestamp(),
        error_message         = NULL
    WHERE table_name = v_table_name;

    RAISE NOTICE 'Completed %. Rows inserted: %', v_table_name, v_rows_processed;

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET
        status                = 'failed',
        last_run_completed_at = clock_timestamp(),
        error_message         = SQLERRM
    WHERE table_name = v_table_name;
    RAISE;
END;
$$;

-- =============================================================================
-- Daily wrapper — refreshes previous month and current month
-- No arguments. Called from refresh_all_daily after refresh_immunization_facts.
-- =============================================================================

CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_monthly_aggregates()
LANGUAGE plpgsql AS $$
DECLARE
    v_current_month date := date_trunc('month', current_date)::date;
    v_prev_month    date := (date_trunc('month', current_date) - INTERVAL '1 month')::date;
BEGIN
    CALL dwh.refresh_immunization_monthly_aggregate(v_prev_month);
    CALL dwh.refresh_immunization_monthly_aggregate(v_current_month);
END;
$$;

-- =============================================================================
-- Historical backfill — run once after initial setup
-- =============================================================================

CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_monthly_aggregate_backfill(
    p_from_date date DEFAULT '2023-09-01'::date
)
LANGUAGE plpgsql AS $$
DECLARE
    v_month date;
BEGIN
    v_month := date_trunc('month', p_from_date)::date;
    WHILE v_month <= date_trunc('month', current_date)::date LOOP
        RAISE NOTICE 'Refreshing aggregate for %', v_month;
        CALL dwh.refresh_immunization_monthly_aggregate(v_month);
        v_month := (v_month + INTERVAL '1 month')::date;
    END LOOP;
END;
$$;

-- =============================================================================
-- Materialized view — BI-facing layer over the aggregate table
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS dwh.mv_immunization_monthly_report;

CREATE MATERIALIZED VIEW dwh.mv_immunization_monthly_report AS
SELECT
    reporting_month,
    reporting_period_start,
    reporting_period_end,
    report_section,
    indicator_code,
    indicator_name,
    indicator_group,
    location_level,
    location_id,
    location_name,
    district_id,        district_name,
    subcounty_id,       subcounty_name,
    parish_id,          parish_name,
    health_facility_id, health_facility_name,
    village_id,         village_name,
    reporting_dhis2_orgunit_uid,
    programme,
    antigen_group,
    vaccine_name,
    dose_label,
    dose_number,
    dimension_key,
    numerator,
    denominator,
    indicator_value,
    eligible_count,
    due_count,
    received_count,
    missed_count,
    late_received_count,
    zero_dose_count,
    under_immunised_count,
    recovered_this_period_count,
    fic_eligible_count,
    fully_immunised_count,
    dwh_updated_at
FROM dwh.agg_immunization_monthly;

CREATE UNIQUE INDEX idx_mv_immunization_monthly_report_unique
    ON dwh.mv_immunization_monthly_report (
        reporting_month, location_level, location_id, indicator_code, dimension_key
    );

CREATE INDEX idx_mv_immunization_monthly_report_month
    ON dwh.mv_immunization_monthly_report (reporting_month);

CREATE INDEX idx_mv_immunization_monthly_report_indicator
    ON dwh.mv_immunization_monthly_report (
        report_section, indicator_code, programme, antigen_group, dose_label
    );

CREATE INDEX idx_mv_immunization_monthly_report_location
    ON dwh.mv_immunization_monthly_report (
        location_level, district_id, subcounty_id, parish_id, health_facility_id, village_id
    );

CREATE INDEX idx_mv_immunization_monthly_report_dhis2
    ON dwh.mv_immunization_monthly_report (reporting_dhis2_orgunit_uid);

CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_monthly_report_mv()
LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY dwh.mv_immunization_monthly_report;
END;
$$;

-- =============================================================================
-- Usage
-- =============================================================================
--
-- One-time backfill from programme start:
--   CALL dwh.refresh_immunization_monthly_aggregate_backfill('2023-09-01');
--
-- Daily (called from refresh_all_daily after refresh_immunization_facts):
--   CALL dwh.refresh_immunization_monthly_aggregates();
--   CALL dwh.refresh_immunization_monthly_report_mv();
--
-- Manual single-month refresh:
--   CALL dwh.refresh_immunization_monthly_aggregate('2026-05-01'::date);
--
-- BI queries — use mv_immunization_monthly_report:
--
--   Antigen coverage for one facility:
--   SELECT indicator_code, indicator_name, due_count, received_count, indicator_value AS coverage_pct
--   FROM dwh.mv_immunization_monthly_report
--   WHERE reporting_month     = '2026-05-01'
--     AND location_level      = 'health_facility'
--     AND health_facility_id  = '<id>'
--     AND report_section      = 'coverage_by_antigen'
--   ORDER BY indicator_code;
--
--   Zero-dose / FIC KPIs for all districts:
--   SELECT district_name, indicator_code, indicator_name, indicator_value
--   FROM dwh.mv_immunization_monthly_report
--   WHERE reporting_month = '2026-05-01'
--     AND location_level  = 'district'
--     AND report_section  = 'facility_kpi_summary'
--   ORDER BY district_name, indicator_code;
--
--   FIC coverage trend — one facility, 12 months:
--   SELECT reporting_month, indicator_value AS fic_pct
--   FROM dwh.mv_immunization_monthly_report
--   WHERE location_level     = 'health_facility'
--     AND health_facility_id = '<id>'
--     AND indicator_code     = 'IMM-FIC-COV'
--     AND reporting_month   >= date_trunc('month', current_date)::date - INTERVAL '11 months'
--   ORDER BY reporting_month;
