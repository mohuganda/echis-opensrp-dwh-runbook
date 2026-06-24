-- 00-check-airbyte-source.sql
-- Purpose: confirm that the required Airbyte source schema and tables exist.

SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema = 'airbyte'
ORDER BY table_name;

-- Required source tables for this DWH layer.
WITH required_tables(table_name) AS (
    VALUES
        ('patient'),
        ('group'),
        ('location'),
        ('organization'),
        ('organization_affiliation'),
        ('practitioner'),
        ('practitioner_role'),
        ('care_team'),
        ('encounter'),
        ('condition'),
        ('flag'),
        ('observation')
)
SELECT
    r.table_name,
    CASE WHEN t.table_name IS NULL THEN 'MISSING' ELSE 'OK' END AS status
FROM required_tables r
LEFT JOIN information_schema.tables t
    ON t.table_schema = 'airbyte'
   AND t.table_name = r.table_name
ORDER BY r.table_name;

-- Confirm important Airbyte columns exist.
SELECT
    table_name,
    column_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'airbyte'
  AND table_name IN (
      'patient', 'group', 'location', 'organization', 'organization_affiliation',
      'practitioner', 'practitioner_role', 'care_team', 'encounter', 'condition',
      'flag', 'observation'
  )
  AND column_name IN ('resource', '_airbyte_extracted_at', '_airbyte_raw_id', '_airbyte_meta')
ORDER BY table_name, column_name;
