CALL dwh.refresh_client_dimensions();

SELECT *
FROM dwh.refresh_state
WHERE table_name = 'dwh.client_dimensions';

SELECT
    COUNT(*) AS total_patients,
    COUNT(*) FILTER (WHERE phone_number IS NOT NULL) AS patients_with_phone,
    COUNT(*) FILTER (WHERE birth_date IS NOT NULL) AS patients_with_birth_date,
    COUNT(*) FILTER (WHERE is_deceased = true) AS deceased_patients
FROM dwh.dim_patients;

SELECT COUNT(*) AS total_households FROM dwh.dim_households;
SELECT COUNT(*) AS total_household_members FROM dwh.bridge_household_members;

SELECT patient_id, full_name, gender, birth_date, phone_number, household_id, reporting_facility_name
FROM dwh.dim_patients
ORDER BY last_updated DESC NULLS LAST
LIMIT 50;
