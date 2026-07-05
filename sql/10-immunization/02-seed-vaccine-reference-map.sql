-- Seed the vaccine schedule reference table.
--
-- This table defines every expected vaccine dose across all three immunization
-- programmes: child_immunization, malaria_vaccine, and hpv_vaccine.
--
-- The refresh procedures join fact_immunizations to this table to normalize
-- vaccine names, antigen groups, dose numbers, and schedule groups.
--
-- The due_age_days and max_age_days columns are used by refresh_immunization_status()
-- to calculate each child's due_date and max_due_date for a given reporting period.
--
-- Re-run this file whenever the vaccine schedule changes. ON CONFLICT keeps
-- existing rows updated without needing to truncate first.

INSERT INTO dwh.ref_immunization_vaccine_map
(
    programme,
    vaccine_name,
    antigen_group,
    dose_label,
    dose_number,
    schedule_group,
    due_age_days,
    max_age_days,
    eligibility_sex,
    min_age_years,
    max_age_years,
    include_in_under5_reports,
    include_in_child_immunization_reports,
    include_in_malaria_reports,
    include_in_hpv_reports,
    is_fic_required
)
VALUES
-- At birth
('child_immunization','BCG at Birth Vaccine',               'BCG',          'Birth',  0, 'immunization_at_birth',   0,   7,   NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','HepB 0 at Birth Vaccine',            'HepB',         'Dose 0', 0, 'immunization_at_birth',   0,   7,   NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','Polio 0 at Birth Vaccine',           'Polio',        'Dose 0', 0, 'immunization_at_birth',   0,   14,  NULL, NULL, NULL, true,  true,  false, false, true),
-- 6 weeks
('child_immunization','Polio 1 at 6 weeks Vaccine',         'Polio',        'Dose 1', 1, 'immunization_at_6_weeks', 42,  56,  NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','Rota 1 at 6 weeks Vaccine',          'Rota',         'Dose 1', 1, 'immunization_at_6_weeks', 42,  56,  NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','PCV 1 at 6 weeks Vaccine',           'PCV',          'Dose 1', 1, 'immunization_at_6_weeks', 42,  56,  NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','IPV 1 at 6 weeks Vaccine',           'IPV',          'Dose 1', 1, 'immunization_at_6_weeks', 42,  56,  NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','DPT-HepB Hib 1 at 6 weeks Vaccine', 'DPT-HepB-Hib', 'Dose 1', 1, 'immunization_at_6_weeks', 42,  56,  NULL, NULL, NULL, true,  true,  false, false, true),
-- 10 weeks
('child_immunization','Polio 2 at 10 weeks Vaccine',        'Polio',        'Dose 2', 2, 'immunization_at_10_weeks',70,  84,  NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','Rota 2 at 10 weeks Vaccine',         'Rota',         'Dose 2', 2, 'immunization_at_10_weeks',70,  84,  NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','PCV 2 at 10 weeks Vaccine',          'PCV',          'Dose 2', 2, 'immunization_at_10_weeks',70,  84,  NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','DPT-HepB Hib 2 at 10 weeks Vaccine','DPT-HepB-Hib', 'Dose 2', 2, 'immunization_at_10_weeks',70,  84,  NULL, NULL, NULL, true,  true,  false, false, true),
-- 14 weeks
('child_immunization','Polio 3 at 14 weeks Vaccine',        'Polio',        'Dose 3', 3, 'immunization_at_14_weeks',98,  112, NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','PCV 3 at 14 weeks Vaccine',          'PCV',          'Dose 3', 3, 'immunization_at_14_weeks',98,  112, NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','IPV 2 at 14 weeks Vaccine',          'IPV',          'Dose 2', 2, 'immunization_at_14_weeks',98,  112, NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','DPT-HepB Hib 3 at 14 weeks Vaccine','DPT-HepB-Hib', 'Dose 3', 3, 'immunization_at_14_weeks',98,  112, NULL, NULL, NULL, true,  true,  false, false, true),
-- 9 months
('child_immunization','Measles Rubella 1 at 9 months Vaccine','Measles-Rubella','Dose 1',1,'immunization_at_9_months',270,284,NULL, NULL, NULL, true,  true,  false, false, true),
('child_immunization','Yellow Fever at 9 months Vaccine',   'Yellow Fever', 'Dose 1', 1, 'immunization_at_9_months', 270, 284, NULL, NULL, NULL, true,  true,  false, false, true),
-- 18 months
('child_immunization','Measles Rubella 2 at 18 months Vaccine','Measles-Rubella','Dose 2',2,'immunization_at_18_months',540,554,NULL,NULL,NULL,true,true,false,false,true),
-- Malaria vaccine
('malaria_vaccine',   'Malaria Vaccine Dose 1',             'Malaria',      'Dose 1', 1, 'malaria_dose_1',           180, 194, NULL, NULL, NULL, true,  false, true,  false, false),
('malaria_vaccine',   'Malaria Vaccine Dose 2',             'Malaria',      'Dose 2', 2, 'malaria_dose_2',           210, 224, NULL, NULL, NULL, true,  false, true,  false, false),
('malaria_vaccine',   'Malaria Vaccine Dose 3',             'Malaria',      'Dose 3', 3, 'malaria_dose_3',           240, 254, NULL, NULL, NULL, true,  false, true,  false, false),
('malaria_vaccine',   'Malaria Vaccine Dose 4',             'Malaria',      'Dose 4', 4, 'malaria_dose_4',           540, 554, NULL, NULL, NULL, true,  false, true,  false, false),
-- HPV vaccine
('hpv_vaccine',       'HPV Vaccine',                        'HPV',          'Dose 1', 1, 'hpv_dose_1',               NULL,NULL,'female',9,  19,  false, false, false, true,  false)
ON CONFLICT (programme, vaccine_name, dose_label)
DO UPDATE SET
    antigen_group                       = EXCLUDED.antigen_group,
    dose_number                         = EXCLUDED.dose_number,
    schedule_group                      = EXCLUDED.schedule_group,
    due_age_days                        = EXCLUDED.due_age_days,
    max_age_days                        = EXCLUDED.max_age_days,
    eligibility_sex                     = EXCLUDED.eligibility_sex,
    min_age_years                       = EXCLUDED.min_age_years,
    max_age_years                       = EXCLUDED.max_age_years,
    include_in_under5_reports           = EXCLUDED.include_in_under5_reports,
    include_in_child_immunization_reports = EXCLUDED.include_in_child_immunization_reports,
    include_in_malaria_reports          = EXCLUDED.include_in_malaria_reports,
    include_in_hpv_reports              = EXCLUDED.include_in_hpv_reports,
    is_fic_required                     = EXCLUDED.is_fic_required,
    dwh_updated_at                      = clock_timestamp();

-- Validate the seed loaded correctly.
SELECT
    programme,
    COUNT(*) AS doses
FROM dwh.ref_immunization_vaccine_map
GROUP BY programme
ORDER BY programme;
