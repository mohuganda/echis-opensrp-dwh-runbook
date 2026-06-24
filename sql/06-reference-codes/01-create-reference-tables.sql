CREATE TABLE IF NOT EXISTS dwh.ref_encounter_codes (
    encounter_system text,
    encounter_code text,
    encounter_display text,
    encounter_text text,
    usage_count integer,
    first_seen_at timestamptz,
    last_seen_at timestamptz,
    include_in_reporting boolean DEFAULT true,
    is_reviewed boolean DEFAULT false,
    notes text,
    last_refreshed_at timestamptz DEFAULT now(),
    PRIMARY KEY (encounter_system, encounter_code, encounter_text)
);

CREATE TABLE IF NOT EXISTS dwh.ref_condition_codes (
    condition_system text,
    condition_code text,
    condition_display text,
    condition_text text,
    usage_count integer,
    first_seen_at timestamptz,
    last_seen_at timestamptz,
    include_in_reporting boolean DEFAULT true,
    is_reviewed boolean DEFAULT false,
    notes text,
    last_refreshed_at timestamptz DEFAULT now(),
    PRIMARY KEY (condition_system, condition_code, condition_text)
);

CREATE TABLE IF NOT EXISTS dwh.ref_flag_codes (
    flag_system text,
    flag_code text,
    flag_display text,
    flag_text text,
    usage_count integer,
    first_seen_at timestamptz,
    last_seen_at timestamptz,
    include_in_reporting boolean DEFAULT true,
    is_reviewed boolean DEFAULT false,
    notes text,
    last_refreshed_at timestamptz DEFAULT now(),
    PRIMARY KEY (flag_system, flag_code, flag_text)
);

CREATE TABLE IF NOT EXISTS dwh.ref_observation_codes (
    category_1_system text,
    category_1_code text,
    observation_system text,
    observation_code text,
    observation_display text,
    observation_text text,
    usage_count integer,
    first_seen_at timestamptz,
    last_seen_at timestamptz,
    include_in_reporting boolean DEFAULT true,
    is_reviewed boolean DEFAULT false,
    notes text,
    last_refreshed_at timestamptz DEFAULT now(),
    PRIMARY KEY (category_1_system, category_1_code, observation_system, observation_code, observation_text)
);

CREATE TABLE IF NOT EXISTS dwh.ref_observation_component_codes (
    component_system text,
    component_code text,
    component_display text,
    component_text text,
    usage_count integer,
    include_in_reporting boolean DEFAULT true,
    is_reviewed boolean DEFAULT false,
    notes text,
    last_refreshed_at timestamptz DEFAULT now(),
    PRIMARY KEY (component_system, component_code, component_text)
);
