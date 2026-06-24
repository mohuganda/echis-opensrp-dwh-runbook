-- Current stock by commodity
SELECT
    cs.commodity_name,
    cs.running_balance,
    cs.running_balance_unit,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    cs.last_updated
FROM dwh.dim_current_commodity_stock cs
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(cs.location_id, cs.location_tag_id)
ORDER BY dl.reporting_facility_name, cs.commodity_name;

-- Monthly consumption
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    m.commodity_name,
    DATE_TRUNC('month', m.effective_datetime)::date AS report_month,
    SUM(COALESCE(m.event_quantity, 0)) AS quantity_consumed
FROM dwh.fact_commodity_stock_movements m
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(m.location_id, m.location_tag_id)
WHERE m.movement_type = 'consumption'
GROUP BY dl.reporting_facility_name, dl.reporting_dhis2_orgunit_uid, m.commodity_name, DATE_TRUNC('month', m.effective_datetime)::date
ORDER BY report_month, dl.reporting_facility_name, m.commodity_name;

-- Current stockouts
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    s.commodity_name,
    s.stockout_started_at,
    s.stockout_ended_at,
    s.stockout_duration
FROM dwh.fact_commodity_stockout_periods s
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = s.location_tag_id
WHERE s.is_current_stockout = true
ORDER BY s.stockout_started_at DESC;
