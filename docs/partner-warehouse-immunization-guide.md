# Partner Warehouse Immunization Reporting Guide

This guide covers everything the partner/MoH BI team needs to run immunization reports from their warehouse, and everything their ETL development team needs to fix and extend the underlying data.

---

## 1. The short version

The partner warehouse holds eCHIS immunization data in a set of tables under the `dwh` schema. We built a **materialized view** on top of those tables called `dwh.mv_imm_patient_status`. This view does all the hard work — joining, cleaning, and computing status flags — so BI analysts can query one table and get answers, rather than writing complex multi-table SQL.

Two example SQL files in this repo contain copy-paste-ready queries for every report widget:

| File | What it contains |
|---|---|
| `examples/partner-warehouse-immunization-mv.sql` | The SQL that creates the materialized view and its indexes. Run this once to build the view. |
| `examples/partner-warehouse-report-queries.sql` | Ready-to-run report queries — KPI summary, antigen coverage, line lists, VHT caseload, village burden table, and malaria summary. |

---

## 2. What tables are involved

The materialized view is built from five tables. Here is what each one is and where it comes from.

### `dwh.fact_opensrp_immunizations`

This is the core immunization record table. One row = one vaccine dose given to one patient.

It is populated by the ETL from `airbyte.questionnaire_response`. When a VHT submits a child immunization form on the eCHIS app, the app sends a FHIR QuestionnaireResponse record to the server. Airbyte picks that up and puts it in `airbyte.questionnaire_response`. The ETL then reads the answers out of the JSON, extracts the vaccine name, the date administered, and the patient ID, and writes a clean row into `dwh.fact_opensrp_immunizations`.

Key columns used in reports:

| Column | What it holds |
|---|---|
| `patient_id` | Links the dose to a child in `dim_opensrp_patient` |
| `vaccine_name` | Name of the vaccine, e.g. `DPT-HepB Hib 1`, `BCG`, `Measles-Rubella 1` |
| `administered_date` | Date the dose was given |
| `programme` | Which programme: `child_immunization`, `malaria_vaccine`, `hpv_vaccine` — **see note on the ETL bug below** |

### `dwh.dim_opensrp_patient`

The patient/child dimension. One row = one registered child (the current version of their record).

Key columns:

| Column | What it holds |
|---|---|
| `patient_id` | Unique child identifier |
| `patient_name` | Child's full name |
| `date_of_birth` | Used to calculate age and eligibility |
| `gender` | M / F |
| `community_location_uuid` | The village/location where this child is registered — links to `dim_opensrp_locations_mapping` |
| `practitioner` | The VHT ID assigned to this child — links to `dim_opensrp_practitioner` |
| `is_current_flag` | `'true'` for the current record. The table is a Type 2 slowly changing dimension, meaning old versions of a record are kept. **Always filter `WHERE is_current_flag = 'true'`** when querying this table directly. |
| `deceased` | `'true'` if the child has been marked as deceased. The MV excludes deceased children. |

### `dwh.dim_opensrp_locations_mapping`

The location hierarchy. One row = one location (village, parish, subcounty, etc.) with its full path from village up to region.

Key columns:

| Column | What it holds |
|---|---|
| `location_id` | Unique location identifier — joins to `dim_opensrp_patient.community_location_uuid` |
| `village_name` | Village-level name |
| `parish_name` | Parish |
| `health_facility_name` | The health facility that serves this village |
| `subcounty_name` | Subcounty / division |
| `county_name` | County (not all districts have counties) |
| `district_name` | District |
| `region_name` | Region |

### `dwh.dim_opensrp_practitioner`

The VHT (Village Health Team) dimension. One row = one active VHT worker.

Key columns:

| Column | What it holds |
|---|---|
| `practitioner_id` | Unique VHT identifier — joins to `dim_opensrp_patient.practitioner` |
| `name` | VHT name |
| `is_current_flag` | Always filter `'true'` when joining |

### `dwh.ref_immunization_vaccine_map`

The Uganda EPI reference schedule. One row = one expected vaccine dose. Defines which doses are required for FIC (Fully Immunized Child) status.

This table does not change frequently. It only needs to be updated if the national immunization schedule changes.

---

## 3. The materialized view: `dwh.mv_imm_patient_status`

### What it is

A materialized view is a query whose results are saved as a table. It looks and behaves like a regular table but is derived from the five source tables above. Querying it is fast because the heavy joining and computation has already been done.

### What it contains

One row per registered child under 5 years old (excluding deceased children and children with no date of birth recorded).

Each row has:
- Child's name, gender, date of birth, age in days and months
- The date they received each vaccine (NULL if not yet received)
- Pre-computed status flags: `is_zero_dose`, `is_under_immunised`, `is_fic`
- The full location hierarchy (village through region)
- Their assigned VHT name
- A `snapshot_date` column showing the date the view was last refreshed

The dose columns are:

| Column | Vaccine | Due age |
|---|---|---|
| `bcg_date` | BCG | Birth |
| `hepb0_date` | HepB 0 | Birth |
| `opv0_date` | OPV 0 | Birth |
| `opv1_date` | OPV 1 | 6 weeks |
| `dpt1_date` | DPT-HepB-Hib 1 | 6 weeks |
| `pcv1_date` | PCV 1 | 6 weeks |
| `rota1_date` | Rota 1 | 6 weeks |
| `ipv1_date` | IPV 1 | 6 weeks |
| `opv2_date` | OPV 2 | 10 weeks |
| `dpt2_date` | DPT-HepB-Hib 2 | 10 weeks |
| `pcv2_date` | PCV 2 | 10 weeks |
| `rota2_date` | Rota 2 | 10 weeks |
| `opv3_date` | OPV 3 | 14 weeks |
| `dpt3_date` | DPT-HepB-Hib 3 | 14 weeks |
| `pcv3_date` | PCV 3 | 14 weeks |
| `ipv2_date` | IPV 2 | 14 weeks |
| `mr1_date` | Measles-Rubella 1 | 9 months |
| `yf_date` | Yellow Fever | 9 months |
| `mr2_date` | Measles-Rubella 2 | 18 months |
| `malaria1_date` | Malaria Dose 1 | 5 months |
| `malaria2_date` | Malaria Dose 2 | 6 months |
| `malaria3_date` | Malaria Dose 3 | 7 months |
| `malaria_booster_date` | Malaria Booster | 15–18 months |
| `hpv1_date` | HPV Dose 1 | Girls 9–14 years |
| `hpv2_date` | HPV Dose 2 | Girls 9–14 years |

### Status flag definitions

| Flag | Definition |
|---|---|
| `is_zero_dose` | Child is aged 0–24 months AND has received zero child immunization doses (malaria and HPV do not count) |
| `is_under_immunised` | Child has received at least one child dose but has not yet received all 19 required doses, and is under 5 years old |
| `is_fic` | Child has received all 19 Uganda EPI doses (all birth doses + all 6-week doses + all 10-week + all 14-week + MR1 + YF + MR2) |

A child can only be in one category at a time. Zero-dose and under-immunised are mutually exclusive. FIC requires all 19 doses — if even one is missing, the child is under-immunised, not FIC.

### How to create the view

Run the file `examples/partner-warehouse-immunization-mv.sql` in full, in order:
1. Section 1 creates the materialized view
2. Section 2 creates the indexes (makes queries fast)
3. Section 3 creates the `v_imm_location_summary` summary view on top of it

This takes 3–10 minutes on first run. You can run it from the terminal using:

```bash
psql -h <host> -U <user> -d <database> -f examples/partner-warehouse-immunization-mv.sql
```

Or paste the contents into pgAdmin and run it there.

### How to refresh the view

The view does not update itself. Run this command whenever you want fresh data:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY dwh.mv_imm_patient_status;
```

The word `CONCURRENTLY` means other users can keep querying the old data while the new data is being built in the background. Once the refresh finishes, everyone automatically sees the new snapshot. This is the safe way to refresh — it avoids locking the table.

To check when the view was last refreshed:

```sql
SELECT MAX(snapshot_date) FROM dwh.mv_imm_patient_status;
```

**Recommended**: add this refresh command to the nightly ETL job, after all the source tables have been updated.

---

## 4. Using the report queries

Open `examples/partner-warehouse-report-queries.sql`. It has 8 query blocks. You can run any block independently — copy the block, paste it into pgAdmin or your SQL tool, and run it.

### The location filter pattern

Every query has commented-out WHERE lines that look like this:

```sql
FROM dwh.mv_imm_patient_status
-- WHERE district_name        = 'Kampala'
-- WHERE subcounty_name       = 'Kawempe Division'
-- WHERE health_facility_name = 'Kawempe HC IV'
```

To filter to a specific location:
1. Find the line for the level you need
2. Remove the `--` at the start of that line
3. Replace the example name with the actual location name

**National level** — remove all `--` lines and run as-is. The query covers all locations.

**District level** — uncomment one `WHERE district_name` line:
```sql
FROM dwh.mv_imm_patient_status
WHERE district_name = 'Kampala'
```

**Subcounty level** — uncomment one `WHERE subcounty_name` line:
```sql
FROM dwh.mv_imm_patient_status
WHERE subcounty_name = 'Kawempe Division'
```

**Health facility level** — uncomment one `WHERE health_facility_name` line:
```sql
FROM dwh.mv_imm_patient_status
WHERE health_facility_name = 'Kawempe HC IV'
```

**Village level** — uncomment one `WHERE village_name` line:
```sql
FROM dwh.mv_imm_patient_status
WHERE village_name = 'Bwaise I'
```

To find the exact location names in your data:

```sql
-- List all districts
SELECT DISTINCT district_name FROM dwh.mv_imm_patient_status ORDER BY 1;

-- List all subcounties in a district
SELECT DISTINCT subcounty_name FROM dwh.mv_imm_patient_status
WHERE district_name = 'Kampala' ORDER BY 1;

-- List all health facilities in a subcounty
SELECT DISTINCT health_facility_name FROM dwh.mv_imm_patient_status
WHERE subcounty_name = 'Kawempe Division' ORDER BY 1;
```

You can also combine filters — for example, all villages under a specific health facility:

```sql
WHERE health_facility_name = 'Kawempe HC IV'
  AND village_name = 'Bwaise I'
```

### Month and date filtering

The MV is a **snapshot of current status** — it reflects the data as of the last refresh. It does not have a month dimension built in. The `snapshot_date` column tells you the date the snapshot was taken, not the child's immunization dates.

For most dashboard widgets (zero-dose count, under-immunised count, FIC coverage), the relevant question is "what is the situation right now?" — and the MV answers that directly without any date filter.

If you need to filter by when a specific dose was received — for example, "how many children received their BCG this month?" — filter on the dose date column:

```sql
-- Children who received BCG in July 2025
SELECT COUNT(*) FROM dwh.mv_imm_patient_status
WHERE bcg_date BETWEEN '2025-07-01' AND '2025-07-31';

-- Children who received DPT dose 1 in the last 30 days
SELECT COUNT(*) FROM dwh.mv_imm_patient_status
WHERE dpt1_date >= CURRENT_DATE - INTERVAL '30 days';
```

If you need monthly trend data — i.e., how did zero-dose numbers change from month to month — the MV alone cannot answer this. The MV needs to be snapshotted at the end of each month and the snapshots compared. If monthly trending is a reporting requirement, the ETL team should set up a nightly or monthly snapshot copy into a separate history table. See the note in section 6 below.

### The antigen coverage query (Query 2)

This query scans the table once using a CTE and then unpivots into one row per vaccine using `LATERAL VALUES`. This is more efficient than 19 separate queries and easier to read. The location filter goes inside the CTE at the top — you only need to set it once:

```sql
WITH cohort AS (
    SELECT *
    FROM dwh.mv_imm_patient_status
    WHERE district_name = 'Kampala'  -- <-- change this one line
),
...
```

### The missing doses column (Query 4)

The under-immunised line list includes a `missing_doses` column that lists which doses a child still needs:

```
missing_doses: OPV2, DPT2, PCV2, Rota2, OPV3, DPT3, PCV3, IPV2, MR1, YF, MR2
```

This column only shows doses that are **due based on the child's age**. A 3-month-old child will not show MR1 as missing even if they have not received it, because they are not yet old enough. The age threshold per dose is applied in the `CASE WHEN ... AND age_days >= N` conditions inside the query.

---

## 5. Connecting this to your BI tool (Tableau, Power BI, etc.)

### Option A: Connect directly to the view

In your BI tool, create a live connection to the `dwh.mv_imm_patient_status` view. The tool will see it as a flat table with ~30 columns. You can build all your dashboard filters on top of it without writing any SQL.

Set up the following dimensions in your BI tool:
- `district_name`, `subcounty_name`, `parish_name`, `health_facility_name`, `village_name` — for location slicers
- `vht_name` — for VHT-level filtering
- `gender`, `age_months` — for demographic filtering
- `snapshot_date` — to show the data freshness date on the dashboard

Set up the following measures:
- `COUNT(patient_id)` → registered children
- `COUNT(patient_id) WHERE is_zero_dose = true` → zero-dose count
- `COUNT(patient_id) WHERE is_fic = true` → FIC count
- etc.

### Option B: Use the pre-aggregated summary view

`dwh.v_imm_location_summary` is already grouped by district, subcounty, parish, health facility, and village, with all counts and percentages pre-computed. It is much smaller and faster for dashboards that only need location-level aggregates rather than patient-level detail.

Connect to this view for national and district-level summary dashboards. Use `mv_imm_patient_status` when you need patient-level drill-down or line lists.

---

## 6. Known data gaps and what the ETL team needs to do

### Gap 1: Caregiver phone number is NULL

The `caregiver_phone` column in `mv_imm_patient_status` is NULL for all children right now.

**Why:** The phone number is stored in the FHIR `Patient` resource under `resource->'telecom'`. The ETL is currently extracting the telecom system label (`"phone"`) rather than the actual number value.

**How to fix:** Update the ETL that loads `airbyte.patient` into `dwh.dim_opensrp_patient` to extract the phone number correctly:

```sql
-- Phone number is in the telecom array, pick the entry where system = 'phone'
SELECT elem->>'value' AS phone_number
FROM jsonb_array_elements(resource->'telecom') elem
WHERE elem->>'system' = 'phone'
LIMIT 1;
```

Store this in a `phone_number` or `contact` column on `dim_opensrp_patient`. The MV will automatically pick it up on next refresh.

### Gap 2: VHT phone number is NULL

Same issue as caregiver phone. The `airbyte.practitioner` resource has a `telecom` array with the VHT's phone. The ETL needs to extract it the same way:

```sql
SELECT elem->>'value' AS phone_number
FROM jsonb_array_elements(resource->'telecom') elem
WHERE elem->>'system' = 'phone'
LIMIT 1;
```

### Gap 3: No caregiver / household head details

The MV currently has no caregiver name or contact because the partner warehouse does not have a household membership table. In the eCHIS app, each child is registered under a household, and the household head is the caregiver. To surface caregiver details in reports, the ETL team needs to build:

**Table A: Household dimension**

Source: `airbyte.group` where the group code is `35359004` (household).

```sql
-- Identify household records
SELECT
    resource->>'id' AS household_id,
    resource->'name' AS household_name,
    -- extract location tag the same way as for patients
    (SELECT tag->>'code'
     FROM jsonb_array_elements(COALESCE(resource#>'{meta,tag}','[]'::jsonb)) tag
     WHERE tag->>'system' = 'https://smartregister.org/location-tag-id'
     LIMIT 1) AS location_tag_id
FROM airbyte.group
WHERE resource->'code'->'coding' @> '[{"code":"35359004"}]';
```

**Table B: Household members bridge**

Source: same `airbyte.group` records. The `member` array inside each group lists the patients who belong to that household.

```sql
-- Expand each household's member list
SELECT
    resource->>'id' AS household_id,
    split_part(member_entry->>'entity', '/', 2) AS patient_id  -- strips 'Patient/' prefix
FROM airbyte.group,
     jsonb_array_elements(resource->'member') AS member_entry
WHERE resource->'code'->'coding' @> '[{"code":"35359004"}]'
  AND member_entry->>'inactive' IS DISTINCT FROM 'true';
```

**Table C: Caregiver contact from RelatedPerson**

Caregiver details are stored in `airbyte.related_person`. Each RelatedPerson record links to a patient and holds the caregiver's name and phone.

```sql
SELECT
    resource->>'id' AS related_person_id,
    split_part(resource->'patient'->>'reference', '/', 2) AS patient_id,
    resource->'name'->0->>'text' AS caregiver_name,
    (SELECT elem->>'value'
     FROM jsonb_array_elements(resource->'telecom') elem
     WHERE elem->>'system' = 'phone'
     LIMIT 1) AS caregiver_phone
FROM airbyte.related_person;
```

Once these three tables exist, the MV can be updated to join household members → household head → caregiver name and phone.

### Gap 4: ETL programme mapping is incomplete (the `programme = 'unknown'` bug)

About 99% of records in `dwh.fact_opensrp_immunizations` have `programme = 'unknown'` and `antigen_group = NULL`. This happens because the ETL matches questionnaire form submissions to a programme by their questionnaire ID, and the main child immunization questionnaire ID is missing from the ETL mapping.

**Impact on the MV:** The MV ignores `programme` and `antigen_group` entirely. It derives all doses directly from the `vaccine_name` text field using pattern matching. So the MV numbers are correct despite this bug.

**Impact on direct queries against `fact_opensrp_immunizations`:** Anyone querying the raw fact table and filtering on `programme` or `antigen_group` will get wrong results. About 99% of child immunization records will be excluded.

**How to fix:** Add the missing questionnaire IDs to the ETL questionnaire-to-programme mapping:

| Questionnaire ID | Programme value |
|---|---|
| `Questionnaire/child-immunization-record-all` | `child_immunization` |
| `Questionnaire/malaria-vaccine-record` | `malaria_vaccine` |
| `Questionnaire/hpv-vaccine-record` | `hpv_vaccine` |
| `Questionnaire/6965f0fc-e0e9-449e-941a-c6e708cc9dd6` | `child_immunization` |

There is also a naming inconsistency to fix: DPT dose 3 arrives from some form submissions as `DPT_HepB Hib 3` (with an underscore instead of a hyphen). The ETL should normalize this to `DPT-HepB Hib 3` on load using `REPLACE(vaccine_name, '_', '-')`.

---

## 7. If monthly trend snapshots are needed

The current MV shows the situation as of today. If the reporting requirement is "show me how zero-dose numbers changed between January and June", that needs historical snapshots.

The simplest way to set this up:

1. Create a table called `dwh.hist_imm_patient_status` with the same columns as `mv_imm_patient_status` plus a `report_month` column (date).
2. On the last day of each month (or the first day of the next month), run:

```sql
INSERT INTO dwh.hist_imm_patient_status
SELECT *, DATE_TRUNC('month', CURRENT_DATE)::date AS report_month
FROM dwh.mv_imm_patient_status;
```

3. Query the history table with a `WHERE report_month = '2025-06-01'` filter to see any month's snapshot.

This is a lightweight approach that costs only disk space and a one-off insert per month. The ETL team can automate it with a cron job or pg_cron.
