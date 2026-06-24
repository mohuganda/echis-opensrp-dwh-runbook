SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
GROUP BY dl.reporting_facility_name, dl.reporting_dhis2_orgunit_uid, c.cebs_status_label, c.reviewed_signal_label
ORDER BY dl.reporting_facility_name, c.cebs_status_label, c.reviewed_signal_label;
