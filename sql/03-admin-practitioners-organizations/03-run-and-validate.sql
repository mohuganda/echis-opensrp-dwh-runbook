CALL dwh.refresh_admin_dimensions();

SELECT *
FROM dwh.refresh_state
WHERE table_name IN ('dwh.dim_practitioner_assignments', 'dwh.admin_dimensions')
ORDER BY last_run_started_at DESC NULLS LAST;

SELECT COUNT(*) AS total_practitioner_assignments
FROM dwh.dim_practitioner_assignments;

SELECT
    user_type,
    assignment_level,
    COUNT(*) AS total
FROM dwh.dim_practitioner_assignments
GROUP BY user_type, assignment_level
ORDER BY total DESC;

SELECT
    practitioner_name,
    practitioner_role_id,
    role_code,
    role_display,
    specialty_code,
    specialty_display,
    user_type,
    care_team_id,
    organization_id,
    assigned_location_id
FROM dwh.dim_practitioner_assignments
WHERE assigned_location_id IS NULL
ORDER BY practitioner_name;
