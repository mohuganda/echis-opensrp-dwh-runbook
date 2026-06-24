SELECT
    COUNT(*) AS total_patients,
    COUNT(*) FILTER (WHERE is_current_visitor) AS visitors,
    COUNT(*) FILTER (WHERE has_hiv_condition) AS hiv_clients,
    COUNT(*) FILTER (WHERE has_tb_condition) AS tb_clients,
    COUNT(*) FILTER (WHERE is_under_fp) AS fp_clients,
    COUNT(*) FILTER (WHERE is_anc_client) AS anc_clients,
    COUNT(*) FILTER (WHERE is_pnc_client) AS pnc_clients,
    COUNT(*) FILTER (WHERE is_sick_child) AS sick_child_clients
FROM dwh.dim_patient_program_status;
