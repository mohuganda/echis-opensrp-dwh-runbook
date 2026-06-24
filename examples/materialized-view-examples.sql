CREATE SCHEMA IF NOT EXISTS reporting;

CREATE MATERIALIZED VIEW IF NOT EXISTS reporting.mv_monthly_cebs_summary AS
SELECT
    DATE_TRUNC('month', c.effective_datetime)::date AS report_month,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label,
    COUNT(*) AS total_records
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
GROUP BY
    DATE_TRUNC('month', c.effective_datetime)::date,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label;

CREATE MATERIALIZED VIEW IF NOT EXISTS reporting.mv_commodity_monthly_consumption AS
SELECT
    DATE_TRUNC('month', m.effective_datetime)::date AS report_month,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    m.commodity_name,
    SUM(COALESCE(m.event_quantity, 0)) AS quantity_consumed
FROM dwh.fact_commodity_stock_movements m
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(m.location_id, m.location_tag_id)
WHERE m.movement_type = 'consumption'
GROUP BY
    DATE_TRUNC('month', m.effective_datetime)::date,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    m.commodity_name;

CREATE OR REPLACE PROCEDURE reporting.refresh_bi_materialized_views()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW reporting.mv_monthly_cebs_summary;
    REFRESH MATERIALIZED VIEW reporting.mv_commodity_monthly_consumption;
END;
$$;
