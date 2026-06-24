CREATE INDEX IF NOT EXISTS idx_fact_encounters_patient_id ON dwh.fact_encounters(patient_id);
CREATE INDEX IF NOT EXISTS idx_fact_encounters_period_start ON dwh.fact_encounters(period_start);
CREATE INDEX IF NOT EXISTS idx_fact_encounters_location_tag_id ON dwh.fact_encounters(location_tag_id);
CREATE INDEX IF NOT EXISTS idx_fact_encounters_airbyte_extracted_at ON dwh.fact_encounters(airbyte_extracted_at);

CREATE INDEX IF NOT EXISTS idx_fact_conditions_patient_id ON dwh.fact_conditions(patient_id);
CREATE INDEX IF NOT EXISTS idx_fact_conditions_code ON dwh.fact_conditions(condition_system, condition_code);
CREATE INDEX IF NOT EXISTS idx_fact_conditions_active ON dwh.fact_conditions(is_active_condition);
CREATE INDEX IF NOT EXISTS idx_fact_conditions_airbyte_extracted_at ON dwh.fact_conditions(airbyte_extracted_at);

CREATE INDEX IF NOT EXISTS idx_fact_flags_patient_id ON dwh.fact_flags(patient_id);
CREATE INDEX IF NOT EXISTS idx_fact_flags_group_id ON dwh.fact_flags(group_id);
CREATE INDEX IF NOT EXISTS idx_fact_flags_code ON dwh.fact_flags(flag_system, flag_code);
CREATE INDEX IF NOT EXISTS idx_fact_flags_period_start ON dwh.fact_flags(period_start);
CREATE INDEX IF NOT EXISTS idx_fact_flags_airbyte_extracted_at ON dwh.fact_flags(airbyte_extracted_at);

CREATE INDEX IF NOT EXISTS idx_fact_observations_patient_id ON dwh.fact_observations(patient_id);
CREATE INDEX IF NOT EXISTS idx_fact_observations_group_id ON dwh.fact_observations(group_id);
CREATE INDEX IF NOT EXISTS idx_fact_observations_location_id ON dwh.fact_observations(location_id);
CREATE INDEX IF NOT EXISTS idx_fact_observations_code ON dwh.fact_observations(observation_system, observation_code);
CREATE INDEX IF NOT EXISTS idx_fact_observations_category_1 ON dwh.fact_observations(category_1_system, category_1_code);
CREATE INDEX IF NOT EXISTS idx_fact_observations_effective_datetime ON dwh.fact_observations(effective_datetime);
CREATE INDEX IF NOT EXISTS idx_fact_observations_airbyte_extracted_at ON dwh.fact_observations(airbyte_extracted_at);

CREATE INDEX IF NOT EXISTS idx_fact_obs_components_observation_id ON dwh.fact_observation_components(observation_id);
CREATE INDEX IF NOT EXISTS idx_fact_obs_components_code ON dwh.fact_observation_components(component_system, component_code);
