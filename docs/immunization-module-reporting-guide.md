# Immunization Module Reporting Guide

This document explains the immunization reporting layer added to the `dwh` schema, covering routine child immunization, malaria vaccine doses, and HPV vaccination.

---

## 1. Why QuestionnaireResponse is the data source

In FHIR, immunization records are typically stored in `Immunization` resources or captured as `Observation` resources. In this implementation, **neither of those sources is used**. The `airbyte.immunization` and `airbyte.observation` tables had extraction errors during the Airbyte replication setup that made them unreliable for immunization reporting.

Instead, all immunization data is extracted from `airbyte.questionnaire_response`. The eCHIS app records immunizations through QuestionnaireResponse forms, and those forms carry the full vaccination record: the vaccine name, the administered date, the patient ID, and the standard location and practitioner metadata tags.

This is important to understand when troubleshooting or extending the system. If a vaccine dose is missing from the DWH, the investigation starts with `airbyte.questionnaire_response`, not `airbyte.immunization`.

The source questionnaire forms are:

| Form | Questionnaire ID | What it captures |
|---|---|---|
| Child immunization (multi-dose) | `Questionnaire/child-immunization-record-all` | All routine child vaccines in one form submission |
| Malaria vaccine | `Questionnaire/malaria-vaccine-record` | Malaria vaccine doses 1–4 |
| HPV vaccine | `Questionnaire/hpv-vaccine-record` | HPV dose for girls 9–19 |
| Legacy single-dose | `Questionnaire/6965f0fc-e0e9-449e-941a-c6e708cc9dd6` | Older single-vaccine record form |

---

## 2. The three-table model

| Table | Purpose |
|---|---|
| `dwh.ref_immunization_vaccine_map` | Reference schedule: one row per expected vaccine dose across all programmes. Used to normalize vaccine names and calculate due dates. |
| `dwh.fact_immunizations` | Administered doses: one row per vaccine dose actually given to a patient. Extracted from QuestionnaireResponse. |
| `dwh.fact_immunization_status` | Coverage and tracking: one row per patient × expected dose × reporting period. The main table for all coverage, zero-dose, under-immunized, and recovery reporting. |

---

## 3. How to think about `fact_immunization_status`

Think of each row as the answer to one question: **"Did this patient receive this specific dose by the end of this reporting period?"**

A single under-5 child will have many rows for any given month — one for every dose they are eligible for:

```text
Patient: Apio Grace, born 2024-10-15, reporting period: July 2025

  BCG Birth             → due Day 0    → received 2024-10-15 → is_received = true
  HepB 0 Birth          → due Day 0    → received 2024-10-15 → is_received = true
  Polio 0 Birth         → due Day 0    → received 2024-10-15 → is_received = true
  Polio 1 (6 weeks)     → due Day 42   → received 2024-11-26 → is_received = true
  DPT-HepB-Hib 1        → due Day 42   → received 2024-11-26 → is_received = true
  PCV 1                 → due Day 42   → received 2024-11-26 → is_received = true
  Polio 2 (10 weeks)    → due Day 70   → received            → is_received = false, is_under_immunised = true
  DPT-HepB-Hib 2        → due Day 70   → received            → is_received = false, is_under_immunised = true
  ...
  Malaria Dose 1        → due Day 180  → not yet due          → is_due = false
  ...
```

Each row tells you:
- Was this child **eligible** for this dose?
- Was this dose **due** by the end of the reporting period?
- Was it **received** before period end?
- If missing, how **overdue** is it?
- If received during this month, was it a **recovery**?

Because flags like `is_zero_dose` and `is_under_immunised` are repeated across all rows for the same child, always use `SELECT DISTINCT patient_id` when **counting children** — not rows.

---

## 4. Key columns in `fact_immunization_status`

| Column | Meaning |
|---|---|
| `programme` | `child_immunization`, `malaria_vaccine`, or `hpv_vaccine` |
| `antigen_group` | Normalized antigen: BCG, Polio, DPT-HepB-Hib, Malaria, HPV, etc. |
| `dose_label` | Dose label, e.g. `Dose 1`, `Dose 2`, `Birth` |
| `due_date` | Date the dose became due (calculated from birth date + `due_age_days`) |
| `max_due_date` | End of the expected vaccination window |
| `is_due` | Dose was due before the reporting period ended |
| `is_received` | Patient received that specific dose before period end |
| `received_date` | Actual vaccination date |
| `is_under_immunised` | Dose was due but not received |
| `is_zero_dose` | Child has received no under-5 vaccines by period end |
| `is_recovered_this_period` | Dose was received during this reporting period (not in a prior period) |
| `is_late_received` | Dose was received after `max_due_date` |
| `is_fully_immunised_child` | All FIC-required doses have been received |
| `follow_up_status` | `not_due`, `received`, `due_missing`, or `eligible` |
| `days_overdue` | How many days past `due_date` the dose remains unreceived |

---

## 5. Key definitions

### Zero-dose child

The current implementation marks a child as zero-dose if:

```text
child is under 5
AND no qualifying child or malaria vaccine dose has been received before the reporting period end
```

A stricter Penta/DPT1-based definition can be added later if MoH wants zero-dose to follow the standard EPI proxy:

```text
child is under 5
AND DPT-HepB-Hib Dose 1 is due
AND DPT-HepB-Hib Dose 1 has not been received before the reporting period end
```

### Under-immunized

A child is under-immunized if at least one dose that was due before the reporting period end has not been received. Since `fact_immunization_status` has one row per patient per expected dose, use `DISTINCT patient_id` when counting under-immunized children.

### Fully immunized child (FIC)

A child is marked `is_fully_immunised_child = true` when all doses with `is_fic_required = true` in the vaccine reference map have been received by the reporting period end. The FIC flag is computed across the full set of required doses and is the same value on every row for that child in the period.

---

## 6. Vaccine schedule

### Routine child immunization

| Stage | Schedule group | Due age | Antigen / Dose | Window |
|---|---|---:|---|---:|
| At Birth | `immunization_at_birth` | Day 0 | BCG at Birth | +7 days |
| At Birth | `immunization_at_birth` | Day 0 | HepB 0 at Birth | +7 days |
| At Birth | `immunization_at_birth` | Day 0 | Polio 0 at Birth | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | Polio 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | Rota 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | PCV 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | IPV 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | DPT-HepB-Hib 1 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | Polio 2 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | Rota 2 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | PCV 2 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | DPT-HepB-Hib 2 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | Polio 3 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | PCV 3 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | IPV 2 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | DPT-HepB-Hib 3 | +14 days |
| 9 Months | `immunization_at_9_months` | Day 270 | Measles-Rubella 1 | +14 days |
| 9 Months | `immunization_at_9_months` | Day 270 | Yellow Fever | +14 days |
| 18 Months | `immunization_at_18_months` | Day 540 | Measles-Rubella 2 | +14 days |

### Malaria vaccine

| Dose | Due age | Window end |
|---|---:|---:|
| Malaria Vaccine Dose 1 | Day 180 | Day 194 |
| Malaria Vaccine Dose 2 | Day 210 | Day 224 |
| Malaria Vaccine Dose 3 | Day 240 | Day 254 |
| Malaria Vaccine Dose 4 | Day 540 | Day 554 |

### HPV vaccine

Eligible group: girls aged 9–19 years. One dose tracked: HPV Vaccine Dose 1.

---

## 7. How `refresh_immunization_status` works

Unlike the incremental fact procedures, `refresh_immunization_status` uses a **full delete and insert** for the given reporting period. Each time it runs for a period, it deletes all existing rows for that period and rebuilds them from scratch.

The rebuild process:

1. **VHT lookup**: Build a deduplicated lookup of VHT practitioners from `dim_practitioner_assignments` (one row per practitioner where `is_vht = true`).

2. **Eligible schedule**: Cross join `dim_patients` (active, non-deceased children in the eligible age range) with `ref_immunization_vaccine_map` to generate every expected dose for every eligible patient. Due dates are calculated per child: `birth_date + due_age_days`. VHT name is joined here from the VHT lookup using the patient's assigned practitioner.

3. **Received doses**: Look up which doses from `fact_immunizations` were administered before `p_period_end` for each patient.

4. **Status flags**: For each patient × dose combination, set `is_due`, `is_received`, `is_under_immunised`, `is_zero_dose`, `is_recovered_this_period`, etc.

5. **FIC calculation**: After computing all rows, aggregate across required doses to set `is_fully_immunised_child` consistently on every row for the patient.

---

## 8. Two-tier storage design

The immunization module uses two storage tiers to keep the database size manageable while supporting both operational follow-up and historical coverage reporting.

### Tier 1 — `dwh.fact_immunization_status` (rolling window)

Row-level data: one row per patient × expected dose × reporting period.

**Purpose**: Operational. Used for follow-up line lists — who is zero-dose right now, which children need a visit this month, which VHT should act.

**Retention**: The daily wrapper keeps only the current month, previous month, and the month before that (3 months). Older periods are deleted automatically. This limits the table to roughly 3–4 million rows regardless of how long the programme runs.

**Why 3 months is enough**: Follow-up questions are time-bound. "Who was zero-dose in November 2024?" is not an actionable follow-up question anymore — the child has either been vaccinated or has aged out. For historical patient-level data, use `fact_immunizations` which keeps all records.

### Tier 2 — `dwh.agg_immunization_monthly` (permanent history)

Aggregated data: one row per month × location level × programme × antigen × dose.

**Purpose**: Historical coverage reporting, trend charts, and DHIS2 submissions. Covers national, district, subcounty, parish, health facility, and village levels in one table via the `location_level` column.

**Retention**: Kept for all months from programme start (September 2023 onwards). The table grows by roughly one new month's worth of rows each cycle — manageable forever.

**antigen_group = 'ALL' rows**: Patient-level KPIs (zero_dose_count, fic_count, under_immunised_count) are stored on special summary rows where `antigen_group = 'ALL'` and `dose_label = 'ALL'`. Antigen-specific rows carry coverage metrics only (due_count, received_count). Use antigen-specific rows for Section 6 coverage indicators and `ALL` rows for Section 1 KPI counts.

### Daily wrapper

The daily wrapper `refresh_immunization_status_current_and_previous_month()` does all of this in sequence:

1. Refresh `fact_immunization_status` for previous month
2. Refresh `fact_immunization_status` for current month
3. Refresh `agg_immunization_monthly` for previous month
4. Refresh `agg_immunization_monthly` for current month
5. Delete `fact_immunization_status` rows older than 3 months

---

## 9. Daily refresh order

The immunization procedures run after `refresh_program_facts_base()` (because they depend on `dim_patients`) and before `refresh_patient_program_status()`:

```sql
CALL dwh.refresh_program_facts_base();

CALL dwh.refresh_immunization_facts();
CALL dwh.refresh_immunization_status_current_and_previous_month();

CALL dwh.refresh_patient_program_status();
CALL dwh.refresh_supply_cebs_reporting();
```

`refresh_immunization_status_current_and_previous_month()` internally refreshes both the row-level status table and the monthly aggregate, and runs the rolling window cleanup.

---

## 10. Manual refresh

Refresh administered facts only (incremental):

```sql
CALL dwh.refresh_immunization_facts();
```

Refresh row-level status for the current month:

```sql
CALL dwh.refresh_immunization_status(
    date_trunc('month', current_date)::date,
    (date_trunc('month', current_date) + INTERVAL '1 month')::date
);
```

Refresh row-level status for the previous month:

```sql
CALL dwh.refresh_immunization_status(
    (date_trunc('month', current_date) - INTERVAL '1 month')::date,
    date_trunc('month', current_date)::date
);
```

Refresh the monthly aggregate for a specific month:

```sql
CALL dwh.refresh_immunization_monthly_aggregate(
    '2026-05-01'::date,
    '2026-06-01'::date
);
```

Run the full historical backfill from programme start (one-time, run after initial setup):

```sql
CALL dwh.refresh_immunization_monthly_aggregate_backfill('2023-09-01');
```

Check refresh state:

```sql
SELECT *
FROM dwh.refresh_state
WHERE table_name LIKE 'dwh.immunization%'
ORDER BY last_run_started_at DESC;
```

---

## 11. Notes and known limitations

- **Zero-dose Penta1 proxy**: Add `is_zero_dose_penta1` if MoH wants to align with the standard EPI zero-dose definition based on DPT-HepB-Hib Dose 1.
- **VHT name**: `assigned_vht_name` is now populated from `dim_practitioner_assignments` in the refresh procedure. `assigned_vht_phone` remains NULL — phone numbers are not available in the current DWH for practitioners.
- **Historical period refresh**: The daily wrapper only refreshes the current and previous month. If backdated corrections arrive for older periods, manually refresh both the status table and the aggregate: `CALL dwh.refresh_immunization_status(start, end)` and `CALL dwh.refresh_immunization_monthly_aggregate(start, end)`.
- **Aggregate backfill**: After initial setup, run `CALL dwh.refresh_immunization_monthly_aggregate_backfill('2023-09-01')` once to populate all historical months. Expect 5–15 minutes total.
- **Source form coverage**: The refresh procedure includes a fallback filter (`resource::text ILIKE '%vaccine%'`) to catch any immunization QuestionnaireResponse forms not matched by the explicit questionnaire ID list. Review and add new questionnaire IDs to the explicit list as new forms are introduced.

See [`examples/immunization-reports.sql`](../examples/immunization-reports.sql) for report queries.
