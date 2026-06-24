-- 01-core-schema-functions.sql
-- Purpose: create core DWH schema, refresh state table, and reusable helper functions.

CREATE SCHEMA IF NOT EXISTS dwh;

CREATE TABLE IF NOT EXISTS dwh.refresh_state (
    table_name text PRIMARY KEY,
    last_successful_airbyte_extracted_at timestamptz,
    last_successful_fhir_last_updated timestamptz,
    last_run_started_at timestamptz,
    last_run_completed_at timestamptz,
    status text,
    rows_processed integer,
    error_message text
);

ALTER TABLE dwh.refresh_state ADD COLUMN IF NOT EXISTS last_successful_airbyte_extracted_at timestamptz;
ALTER TABLE dwh.refresh_state ADD COLUMN IF NOT EXISTS last_successful_fhir_last_updated timestamptz;
ALTER TABLE dwh.refresh_state ADD COLUMN IF NOT EXISTS last_run_started_at timestamptz;
ALTER TABLE dwh.refresh_state ADD COLUMN IF NOT EXISTS last_run_completed_at timestamptz;
ALTER TABLE dwh.refresh_state ADD COLUMN IF NOT EXISTS status text;
ALTER TABLE dwh.refresh_state ADD COLUMN IF NOT EXISTS rows_processed integer;
ALTER TABLE dwh.refresh_state ADD COLUMN IF NOT EXISTS error_message text;

CREATE OR REPLACE FUNCTION dwh.fhir_ref_id(p_reference text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(
        CASE
            WHEN p_reference IS NULL OR trim(p_reference) = '' THEN NULL
            WHEN strpos(p_reference, '/') > 0 THEN split_part(p_reference, '/', 2)
            ELSE p_reference
        END,
        ''
    );
$$;

CREATE OR REPLACE FUNCTION dwh.safe_timestamptz(p_value text)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_value IS NULL OR trim(p_value) = '' THEN
        RETURN NULL;
    END IF;

    RETURN p_value::timestamptz;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.safe_numeric(p_value text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_value IS NULL OR trim(p_value) = '' THEN
        RETURN NULL;
    END IF;

    RETURN p_value::numeric;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.fhir_human_name(p_name jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(
        trim(
            concat_ws(
                ' ',
                p_name -> 0 ->> 'prefix',
                p_name -> 0 -> 'given' ->> 0,
                p_name -> 0 -> 'given' ->> 1,
                p_name -> 0 ->> 'family'
            )
        ),
        ''
    );
$$;

CREATE OR REPLACE FUNCTION dwh.fhir_meta_tag_code(p_resource jsonb, p_system text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT tag_item ->> 'code'
    FROM jsonb_array_elements(COALESCE(p_resource -> 'meta' -> 'tag', '[]'::jsonb)) AS tag_item
    WHERE tag_item ->> 'system' = p_system
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION dwh.age_in_days(p_birth_date date, p_as_of_date date DEFAULT CURRENT_DATE)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN p_birth_date IS NULL THEN NULL ELSE (p_as_of_date - p_birth_date)::integer END;
$$;

CREATE OR REPLACE FUNCTION dwh.age_in_months(p_birth_date date, p_as_of_date date DEFAULT CURRENT_DATE)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_birth_date IS NULL THEN NULL
        ELSE (EXTRACT(YEAR FROM age(p_as_of_date, p_birth_date))::int * 12)
           + EXTRACT(MONTH FROM age(p_as_of_date, p_birth_date))::int
    END;
$$;

CREATE OR REPLACE FUNCTION dwh.age_in_years(p_birth_date date, p_as_of_date date DEFAULT CURRENT_DATE)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN p_birth_date IS NULL THEN NULL ELSE EXTRACT(YEAR FROM age(p_as_of_date, p_birth_date))::int END;
$$;

CREATE OR REPLACE FUNCTION dwh.reporting_age_group(p_birth_date date, p_as_of_date date DEFAULT CURRENT_DATE)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_birth_date IS NULL THEN 'unknown'
        WHEN dwh.age_in_days(p_birth_date, p_as_of_date) < 30 THEN 'under_1_month'
        WHEN dwh.age_in_months(p_birth_date, p_as_of_date) < 2 THEN 'under_2_months'
        WHEN dwh.age_in_years(p_birth_date, p_as_of_date) < 1 THEN 'under_1'
        WHEN dwh.age_in_years(p_birth_date, p_as_of_date) BETWEEN 1 AND 4 THEN '1_to_4'
        WHEN dwh.age_in_years(p_birth_date, p_as_of_date) BETWEEN 5 AND 10 THEN '5_to_10'
        WHEN dwh.age_in_years(p_birth_date, p_as_of_date) BETWEEN 11 AND 19 THEN '11_to_19'
        WHEN dwh.age_in_years(p_birth_date, p_as_of_date) BETWEEN 20 AND 24 THEN '20_to_24'
        WHEN dwh.age_in_years(p_birth_date, p_as_of_date) > 24 THEN 'over_24'
        ELSE 'unknown'
    END;
$$;

CREATE OR REPLACE FUNCTION dwh.is_woman_of_reproductive_age(
    p_gender text,
    p_birth_date date,
    p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN lower(COALESCE(p_gender, '')) <> 'female' THEN false
        WHEN p_birth_date IS NULL THEN false
        WHEN dwh.age_in_years(p_birth_date, p_as_of_date) BETWEEN 15 AND 49 THEN true
        ELSE false
    END;
$$;

-- Validation
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema = 'dwh'
ORDER BY routine_name;
