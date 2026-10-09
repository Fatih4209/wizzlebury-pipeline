create table public."approval_requests" (
    "id" uuid default gen_random_uuid() not null,
    "scope_type" text not null,
    "scope_id" uuid not null,
    "scope_version" integer,
    "token_hash" text not null,
    "status" text default 'PENDING'::text not null,
    "requested_by" text not null,
    "summary" jsonb default '{}'::jsonb not null,
    "expires_at" timestamptz not null,
    "decided_at" timestamptz,
    "decided_by" text,
    "decision_channel" text,
    "decision_note" text,
    "created_at" timestamptz default now() not null
);
create table public."asset_qualification_tests" (
    "id" uuid default gen_random_uuid() not null,
    "asset_id" uuid not null,
    "test_type" text not null,
    "provider" text,
    "model" text,
    "result" text default 'PENDING'::text not null,
    "score" numeric,
    "notes" text,
    "created_at" timestamptz default now() not null,
    "reviewed_at" timestamptz
);
create table public."asset_registry" (
    "id" uuid default gen_random_uuid() not null,
    "series_id" uuid not null,
    "asset_code" text not null,
    "asset_type" text not null,
    "character_id" uuid,
    "location_id" uuid,
    "outfit_id" uuid,
    "prop_id" uuid,
    "voice_identity_id" uuid,
    "storage_provider" text,
    "storage_path" text,
    "mime_type" text,
    "checksum_sha256" text,
    "metadata" jsonb default '{}'::jsonb not null,
    "status" text default 'DRAFT'::text not null,
    "version" integer default 1 not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null
);
create table public."attempts" (
    "id" uuid default gen_random_uuid() not null,
    "shot_id" uuid not null,
    "attempt_no" integer not null,
    "idempotency_key" text not null,
    "provider" text not null,
    "model" text not null,
    "prompt_version" integer not null,
    "model_version" text,
    "status" text default 'CREATED'::text not null,
    "provider_job_id" text,
    "estimated_cost" numeric not null,
    "actual_cost" numeric,
    "error_code" text,
    "error_detail" text,
    "created_at" timestamptz default now() not null,
    "started_at" timestamptz,
    "finished_at" timestamptz,
    "last_provider_check_at" timestamptz,
    "provider_result_url" text,
    "heartbeat_at" timestamptz,
    "recovery_count" integer default 0 not null,
    "routing_decision_id" uuid,
    "monthly_budget_id" uuid,
    "episode_budget_id" uuid,
    "shot_budget_id" uuid,
    "submission_claimed_at" timestamptz,
    "submission_claimed_by" text
);
create table public."budgets" (
    "id" uuid default gen_random_uuid() not null,
    "budget_type" text not null,
    "reference_id" uuid,
    "currency" text default 'USD'::text not null,
    "hard_limit" numeric not null,
    "reserved_amount" numeric default 0 not null,
    "settled_amount" numeric default 0 not null,
    "period_start" timestamptz,
    "period_end" timestamptz,
    "is_active" boolean default true not null,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."character_outfits" (
    "id" uuid default gen_random_uuid() not null,
    "character_id" uuid not null,
    "outfit_code" text not null,
    "name" text not null,
    "description" text,
    "rules" jsonb default '{}'::jsonb not null,
    "status" text default 'DRAFT'::text not null,
    "version" integer default 1 not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null
);
create table public."characters" (
    "id" uuid default gen_random_uuid() not null,
    "series_id" uuid not null,
    "character_code" text not null,
    "name" text not null,
    "role_type" text,
    "age" integer,
    "gender_identity" text,
    "personality" jsonb default '{}'::jsonb not null,
    "appearance" jsonb default '{}'::jsonb not null,
    "behavior_rules" jsonb default '{}'::jsonb not null,
    "relationship_rules" jsonb default '{}'::jsonb not null,
    "canonical_description" text,
    "status" text default 'DRAFT'::text not null,
    "version" integer default 1 not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."cost_ledger" (
    "id" uuid default gen_random_uuid() not null,
    "attempt_id" uuid,
    "episode_id" uuid,
    "shot_id" uuid,
    "entry_type" text not null,
    "amount" numeric not null,
    "currency" text default 'USD'::text not null,
    "description" text,
    "created_at" timestamptz default now() not null
);
create table public."episodes" (
    "id" uuid default gen_random_uuid() not null,
    "content_id" text not null,
    "series_id" uuid not null,
    "title" text,
    "concept" text,
    "state" text default 'PLANNED'::text not null,
    "human_approved" boolean default false not null,
    "maximum_budget" numeric,
    "currency" text default 'USD'::text not null,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null,
    "schema_version" integer default 1 not null,
    "production_version" integer default 1 not null,
    "production_authorized" boolean default false not null,
    "authorized_at" timestamptz,
    "production_mode" text default 'SERIES_EPISODE'::text not null,
    "creative_profile_id" uuid,
    "blocked_from_state" text
);
create table public."events" (
    "id" uuid default gen_random_uuid() not null,
    "event_type" text not null,
    "episode_id" uuid,
    "shot_id" uuid,
    "attempt_id" uuid,
    "severity" text default 'INFO'::text not null,
    "source" text not null,
    "message" text,
    "metadata" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null
);
create table public."generation_benchmark_cases" (
    "id" uuid default gen_random_uuid() not null,
    "benchmark_run_id" uuid not null,
    "case_code" text not null,
    "case_order" integer not null,
    "title" text not null,
    "generation_prompt" text not null,
    "negative_prompt" text,
    "duration_seconds" numeric not null,
    "aspect_ratio" text default '16:9'::text not null,
    "resolution" text default '720p'::text not null,
    "reference_metadata" jsonb default '{}'::jsonb not null,
    "evaluation_profile" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null
);
create table public."generation_benchmark_job_authorizations" (
    "id" uuid default gen_random_uuid() not null,
    "benchmark_run_id" uuid not null,
    "benchmark_job_id" uuid not null,
    "authorization_stage" text not null,
    "authorization_status" text default 'PLANNED'::text not null,
    "authorized_estimated_cost" numeric not null,
    "authorization_reason" text not null,
    "metadata" jsonb default '{}'::jsonb not null,
    "authorized_at" timestamptz,
    "consumed_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."generation_benchmark_jobs" (
    "id" uuid default gen_random_uuid() not null,
    "benchmark_run_id" uuid not null,
    "benchmark_case_id" uuid not null,
    "model_id" uuid not null,
    "pricing_id" uuid not null,
    "attempt_no" integer not null,
    "estimated_cost" numeric not null,
    "actual_cost" numeric,
    "status" text default 'CREATED'::text not null,
    "provider_job_id" text,
    "output_url" text,
    "storage_path" text,
    "error_code" text,
    "error_detail" text,
    "created_at" timestamptz default now() not null,
    "submitted_at" timestamptz,
    "completed_at" timestamptz
);
create table public."generation_benchmark_runs" (
    "id" uuid default gen_random_uuid() not null,
    "run_code" text not null,
    "benchmark_name" text not null,
    "status" text default 'DRAFT'::text not null,
    "hard_budget_usd" numeric not null,
    "reserved_usd" numeric default 0 not null,
    "settled_usd" numeric default 0 not null,
    "max_generation_count" integer not null,
    "generation_count" integer default 0 not null,
    "human_approved" boolean default false not null,
    "approved_at" timestamptz,
    "started_at" timestamptz,
    "completed_at" timestamptz,
    "metadata" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."generation_model_benchmarks" (
    "id" uuid default gen_random_uuid() not null,
    "model_id" uuid not null,
    "benchmark_version" integer not null,
    "benchmark_name" text not null,
    "benchmark_status" text default 'DRAFT'::text not null,
    "continuity_score" numeric,
    "motion_score" numeric,
    "face_score" numeric,
    "anatomy_score" numeric,
    "prompt_adherence_score" numeric,
    "camera_score" numeric,
    "expression_score" numeric,
    "lip_sync_score" numeric,
    "overall_quality_score" numeric,
    "pass_rate" numeric,
    "average_generation_seconds" numeric,
    "sample_size" integer default 0 not null,
    "test_profile" jsonb default '{}'::jsonb not null,
    "notes" text,
    "tested_at" timestamptz,
    "approved_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "source_benchmark_job_id" uuid
);
create table public."generation_model_health" (
    "model_id" uuid not null,
    "availability_status" text default 'UNKNOWN'::text not null,
    "success_rate" numeric,
    "average_latency_seconds" numeric,
    "last_checked_at" timestamptz,
    "failure_reason" text,
    "metadata" jsonb default '{}'::jsonb not null,
    "updated_at" timestamptz default now() not null
);
create table public."generation_model_health_history" (
    "id" uuid default gen_random_uuid() not null,
    "model_id" uuid not null,
    "previous_status" text,
    "new_status" text not null,
    "check_source" text not null,
    "reason" text not null,
    "success_rate" numeric,
    "average_latency_seconds" numeric,
    "provider_http_status" integer,
    "provider_request_id" text,
    "metadata" jsonb default '{}'::jsonb not null,
    "checked_at" timestamptz default now() not null,
    "created_at" timestamptz default now() not null
);
create table public."generation_model_pricing" (
    "id" uuid default gen_random_uuid() not null,
    "model_id" uuid not null,
    "pricing_version" integer not null,
    "billing_unit" text not null,
    "currency" text default 'USD'::text not null,
    "unit_price" numeric not null,
    "minimum_charge" numeric default 0 not null,
    "effective_from" timestamptz not null,
    "effective_to" timestamptz,
    "source_reference" text,
    "is_verified" boolean default false not null,
    "verified_at" timestamptz,
    "metadata" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null
);
create table public."generation_models" (
    "id" uuid default gen_random_uuid() not null,
    "provider_id" uuid not null,
    "model_code" text not null,
    "display_name" text not null,
    "model_version" text,
    "media_type" text default 'VIDEO'::text not null,
    "status" text default 'DISABLED'::text not null,
    "priority" integer default 100 not null,
    "supports_text_to_video" boolean default false not null,
    "supports_image_to_video" boolean default false not null,
    "supports_reference_images" boolean default false not null,
    "supports_character_consistency" boolean default false not null,
    "supports_camera_control" boolean default false not null,
    "supports_native_audio" boolean default false not null,
    "supports_lip_sync" boolean default false not null,
    "supports_seed" boolean default false not null,
    "min_duration_seconds" numeric,
    "max_duration_seconds" numeric,
    "supported_aspect_ratios" jsonb default '[]'::jsonb not null,
    "supported_resolutions" jsonb default '[]'::jsonb not null,
    "capability_metadata" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."generation_outputs" (
    "id" uuid default gen_random_uuid() not null,
    "attempt_id" uuid not null,
    "shot_id" uuid not null,
    "output_no" integer default 1 not null,
    "storage_provider" text,
    "storage_path" text,
    "source_url" text,
    "mime_type" text,
    "checksum_sha256" text,
    "duration_seconds" numeric,
    "width" integer,
    "height" integer,
    "fps" numeric,
    "file_size_bytes" bigint,
    "qc_status" text default 'PENDING'::text not null,
    "qc_score" numeric,
    "qc_notes" text,
    "qc_details" jsonb default '{}'::jsonb not null,
    "reviewed_at" timestamptz,
    "is_canonical" boolean default false not null,
    "canonical_at" timestamptz,
    "status" text default 'REGISTERED'::text not null,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."generation_policy_models" (
    "id" uuid default gen_random_uuid() not null,
    "policy_id" uuid not null,
    "model_id" uuid not null,
    "route_role" text not null,
    "route_priority" integer default 100 not null,
    "enabled" boolean default true not null,
    "minimum_quality_override" numeric,
    "maximum_estimated_cost" numeric,
    "metadata" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null
);
create table public."generation_providers" (
    "id" uuid default gen_random_uuid() not null,
    "provider_code" text not null,
    "display_name" text not null,
    "provider_type" text default 'VIDEO'::text not null,
    "status" text default 'DISABLED'::text not null,
    "priority" integer default 100 not null,
    "api_base_url" text,
    "metadata" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."generation_routing_decisions" (
    "id" uuid default gen_random_uuid() not null,
    "shot_id" uuid not null,
    "shot_specification_id" uuid not null,
    "policy_id" uuid not null,
    "attempt_no" integer not null,
    "selected_model_id" uuid,
    "selected_pricing_id" uuid,
    "route_role" text,
    "estimated_cost" numeric,
    "decision_status" text default 'PENDING'::text not null,
    "decision_reason" text,
    "candidate_scores" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null,
    "decision_revision" integer default 1 not null,
    "is_current" boolean default true not null
);
create table public."generation_routing_policies" (
    "id" uuid default gen_random_uuid() not null,
    "policy_code" text not null,
    "version" integer default 1 not null,
    "display_name" text not null,
    "status" text default 'DRAFT'::text not null,
    "minimum_quality_score" numeric default 0 not null,
    "minimum_pass_rate" numeric default 0 not null,
    "quality_weight" numeric default 0.50 not null,
    "cost_weight" numeric default 0.30 not null,
    "reliability_weight" numeric default 0.15 not null,
    "latency_weight" numeric default 0.05 not null,
    "max_attempts" integer default 2 not null,
    "fallback_on_second_attempt" boolean default true not null,
    "require_verified_pricing" boolean default true not null,
    "require_available_health" boolean default true not null,
    "metadata" jsonb default '{}'::jsonb not null,
    "approved_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."location_asset_plan" (
    "id" uuid default gen_random_uuid() not null,
    "series_id" uuid not null,
    "location_id" uuid not null,
    "asset_code" text not null,
    "asset_role" text not null,
    "view_type" text not null,
    "priority" text not null,
    "generation_required" boolean default true not null,
    "production_rules" jsonb default '{}'::jsonb not null,
    "status" text default 'PLANNED'::text not null,
    "created_at" timestamptz default now() not null
);
create table public."location_relationships" (
    "id" uuid default gen_random_uuid() not null,
    "series_id" uuid not null,
    "from_location_id" uuid not null,
    "to_location_id" uuid not null,
    "relationship_type" text not null,
    "approximate_travel_minutes" integer,
    "travel_mode" text,
    "geography_rules" jsonb default '{}'::jsonb not null,
    "created_at" timestamptz default now() not null
);
create table public."locations" (
    "id" uuid default gen_random_uuid() not null,
    "series_id" uuid not null,
    "location_code" text not null,
    "name" text not null,
    "location_type" text,
    "canonical_description" text,
    "visual_rules" jsonb default '{}'::jsonb not null,
    "lighting_rules" jsonb default '{}'::jsonb not null,
    "continuity_rules" jsonb default '{}'::jsonb not null,
    "status" text default 'DRAFT'::text not null,
    "version" integer default 1 not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."production_creative_profiles" (
    "id" uuid default gen_random_uuid() not null,
    "profile_code" text not null,
    "version" integer not null,
    "production_mode" text not null,
    "profile_name" text not null,
    "status" text default 'DRAFT'::text not null,
    "aspect_ratio" text not null,
    "target_duration_min_seconds" numeric not null,
    "target_duration_max_seconds" numeric not null,
    "hard_duration_max_seconds" numeric not null,
    "hook_deadline_seconds" numeric not null,
    "max_paid_attempts" integer not null,
    "creative_rules" jsonb default '{}'::jsonb not null,
    "quality_rules" jsonb default '{}'::jsonb not null,
    "learning_rules" jsonb default '{}'::jsonb not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."production_manifest_shots" (
    "id" uuid default gen_random_uuid() not null,
    "manifest_id" uuid not null,
    "shot_id" uuid not null,
    "shot_specification_id" uuid not null,
    "manifest_order" integer not null,
    "created_at" timestamptz default now() not null
);
create table public."production_manifests" (
    "id" uuid default gen_random_uuid() not null,
    "episode_id" uuid not null,
    "production_version" integer default 1 not null,
    "manifest_code" text not null,
    "status" text default 'DRAFT'::text not null,
    "human_approved" boolean default false not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null,
    "pilot_shot_id" uuid not null
);
create table public."props" (
    "id" uuid default gen_random_uuid() not null,
    "series_id" uuid not null,
    "prop_code" text not null,
    "name" text not null,
    "canonical_description" text,
    "visual_rules" jsonb default '{}'::jsonb not null,
    "status" text default 'DRAFT'::text not null,
    "version" integer default 1 not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null
);
create table public."scenes" (
    "id" uuid default gen_random_uuid() not null,
    "episode_id" uuid not null,
    "scene_code" text not null,
    "scene_order" integer not null,
    "title" text,
    "description" text,
    "location_id" uuid,
    "time_of_day" text,
    "story_purpose" text,
    "emotional_tone" text,
    "estimated_duration_seconds" numeric,
    "state" text default 'PLANNED'::text not null,
    "schema_version" integer default 1 not null,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."series" (
    "id" uuid default gen_random_uuid() not null,
    "series_code" text not null,
    "name" text not null,
    "target_audience" text,
    "target_age_min" integer,
    "target_age_max" integer,
    "primary_language" text default 'en'::text not null,
    "premise" text,
    "world_rules" jsonb default '{}'::jsonb not null,
    "creative_rules" jsonb default '{}'::jsonb not null,
    "forbidden_rules" jsonb default '{}'::jsonb not null,
    "status" text default 'DRAFT'::text not null,
    "version" integer default 1 not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."shot_audio_productions" (
    "id" uuid default gen_random_uuid() not null,
    "shot_specification_id" uuid not null,
    "character_id" uuid not null,
    "voice_identity_id" uuid not null,
    "audio_order" integer default 1 not null,
    "dialogue_text" text not null,
    "language" text default 'en'::text not null,
    "provider" text,
    "model" text,
    "provider_job_id" text,
    "storage_provider" text,
    "storage_path" text,
    "source_url" text,
    "mime_type" text,
    "checksum_sha256" text,
    "duration_seconds" numeric,
    "start_offset_seconds" numeric default 0 not null,
    "end_offset_seconds" numeric,
    "lip_sync_required" boolean default true not null,
    "lip_sync_status" text default 'PENDING'::text not null,
    "timing_metadata" jsonb default '{}'::jsonb not null,
    "qc_status" text default 'PENDING'::text not null,
    "qc_score" numeric,
    "qc_notes" text,
    "reviewed_at" timestamptz,
    "status" text default 'PLANNED'::text not null,
    "is_canonical" boolean default false not null,
    "canonical_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null,
    "take_no" integer default 1 not null
);
create table public."shot_reference_assets" (
    "id" uuid default gen_random_uuid() not null,
    "shot_specification_id" uuid not null,
    "asset_id" uuid not null,
    "reference_role" text not null,
    "reference_order" integer default 1 not null,
    "is_required" boolean default true not null,
    "usage_notes" text,
    "created_at" timestamptz default now() not null
);
create table public."shot_specifications" (
    "id" uuid default gen_random_uuid() not null,
    "shot_id" uuid not null,
    "version" integer default 1 not null,
    "is_active" boolean default true not null,
    "narrative_action" text not null,
    "dialogue" text,
    "emotion" text,
    "shot_size" text not null,
    "camera_angle" text,
    "camera_movement" text,
    "duration_seconds" numeric not null,
    "generation_prompt" text not null,
    "negative_prompt" text,
    "aspect_ratio" text default '16:9'::text not null,
    "fps" integer default 24 not null,
    "resolution" text default '1920x1080'::text not null,
    "character_codes" jsonb default '[]'::jsonb not null,
    "required_asset_codes" jsonb default '[]'::jsonb not null,
    "continuity_notes" text,
    "audio_required" boolean default false not null,
    "voice_required" boolean default false not null,
    "preferred_provider" text,
    "preferred_model" text,
    "status" text default 'DRAFT'::text not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."shots" (
    "id" uuid default gen_random_uuid() not null,
    "episode_id" uuid not null,
    "shot_code" text not null,
    "shot_order" integer not null,
    "state" text default 'PLANNED'::text not null,
    "prompt_version" integer default 1 not null,
    "asset_version" integer default 1 not null,
    "model_version" text,
    "maximum_budget" numeric,
    "currency" text default 'USD'::text not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null,
    "schema_version" integer default 1 not null,
    "scene_id" uuid
);
create table public."storyboard_reviews" (
    "id" uuid default gen_random_uuid() not null,
    "shot_specification_id" uuid not null,
    "storyboard_asset_id" uuid,
    "status" text default 'PENDING'::text not null,
    "reviewer_type" text,
    "score" numeric,
    "notes" text,
    "reviewed_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."style_bibles" (
    "id" uuid default gen_random_uuid() not null,
    "series_id" uuid not null,
    "version" integer default 1 not null,
    "visual_style" text,
    "color_language" text,
    "lighting_language" text,
    "camera_language" text,
    "texture_language" text,
    "animation_language" text,
    "negative_rules" jsonb default '[]'::jsonb not null,
    "technical_rules" jsonb default '{}'::jsonb not null,
    "status" text default 'DRAFT'::text not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null,
    "updated_at" timestamptz default now() not null
);
create table public."system_flags" (
    "key" text not null,
    "value" boolean not null,
    "description" text,
    "updated_at" timestamptz default now() not null
);
create table public."system_settings" (
    "key" text not null,
    "value_numeric" numeric not null,
    "description" text,
    "updated_at" timestamptz default now() not null
);
create table public."voice_identities" (
    "id" uuid default gen_random_uuid() not null,
    "character_id" uuid not null,
    "voice_code" text not null,
    "provider" text,
    "provider_voice_id" text,
    "language" text default 'en'::text not null,
    "voice_description" text,
    "speech_rate" numeric,
    "energy_level" text,
    "pronunciation_rules" jsonb default '{}'::jsonb not null,
    "emotion_rules" jsonb default '{}'::jsonb not null,
    "status" text default 'DRAFT'::text not null,
    "version" integer default 1 not null,
    "locked_at" timestamptz,
    "created_at" timestamptz default now() not null
);
alter table public."system_flags" add constraint "system_flags_pkey" PRIMARY KEY (key);
alter table public."budgets" add constraint "budgets_pkey" PRIMARY KEY (id);
alter table public."episodes" add constraint "episodes_pkey" PRIMARY KEY (id);
alter table public."shots" add constraint "shots_pkey" PRIMARY KEY (id);
alter table public."attempts" add constraint "attempts_pkey" PRIMARY KEY (id);
alter table public."cost_ledger" add constraint "cost_ledger_pkey" PRIMARY KEY (id);
alter table public."events" add constraint "events_pkey" PRIMARY KEY (id);
alter table public."series" add constraint "series_pkey" PRIMARY KEY (id);
alter table public."style_bibles" add constraint "style_bibles_pkey" PRIMARY KEY (id);
alter table public."characters" add constraint "characters_pkey" PRIMARY KEY (id);
alter table public."character_outfits" add constraint "character_outfits_pkey" PRIMARY KEY (id);
alter table public."locations" add constraint "locations_pkey" PRIMARY KEY (id);
alter table public."voice_identities" add constraint "voice_identities_pkey" PRIMARY KEY (id);
alter table public."props" add constraint "props_pkey" PRIMARY KEY (id);
alter table public."asset_registry" add constraint "asset_registry_pkey" PRIMARY KEY (id);
alter table public."asset_qualification_tests" add constraint "asset_qualification_tests_pkey" PRIMARY KEY (id);
alter table public."location_relationships" add constraint "location_relationships_pkey" PRIMARY KEY (id);
alter table public."location_asset_plan" add constraint "location_asset_plan_pkey" PRIMARY KEY (id);
alter table public."scenes" add constraint "scenes_pkey" PRIMARY KEY (id);
alter table public."shot_specifications" add constraint "shot_specifications_pkey" PRIMARY KEY (id);
alter table public."production_manifests" add constraint "production_manifests_pkey" PRIMARY KEY (id);
alter table public."production_manifest_shots" add constraint "production_manifest_shots_pkey" PRIMARY KEY (id);
alter table public."generation_outputs" add constraint "generation_outputs_pkey" PRIMARY KEY (id);
alter table public."shot_reference_assets" add constraint "shot_reference_assets_pkey" PRIMARY KEY (id);
alter table public."storyboard_reviews" add constraint "storyboard_reviews_pkey" PRIMARY KEY (id);
alter table public."shot_audio_productions" add constraint "shot_audio_productions_pkey" PRIMARY KEY (id);
alter table public."generation_providers" add constraint "generation_providers_pkey" PRIMARY KEY (id);
alter table public."generation_models" add constraint "generation_models_pkey" PRIMARY KEY (id);
alter table public."generation_model_pricing" add constraint "generation_model_pricing_pkey" PRIMARY KEY (id);
alter table public."generation_model_health" add constraint "generation_model_health_pkey" PRIMARY KEY (model_id);
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_pkey" PRIMARY KEY (id);
alter table public."generation_routing_policies" add constraint "generation_routing_policies_pkey" PRIMARY KEY (id);
alter table public."generation_policy_models" add constraint "generation_policy_models_pkey" PRIMARY KEY (id);
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_pkey" PRIMARY KEY (id);
alter table public."generation_benchmark_runs" add constraint "generation_benchmark_runs_pkey" PRIMARY KEY (id);
alter table public."generation_benchmark_cases" add constraint "generation_benchmark_cases_pkey" PRIMARY KEY (id);
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_pkey" PRIMARY KEY (id);
alter table public."generation_model_health_history" add constraint "generation_model_health_history_pkey" PRIMARY KEY (id);
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_pkey" PRIMARY KEY (id);
alter table public."production_creative_profiles" add constraint "production_creative_profiles_pkey" PRIMARY KEY (id);
alter table public."system_settings" add constraint "system_settings_pkey" PRIMARY KEY (key);
alter table public."approval_requests" add constraint "approval_requests_pkey" PRIMARY KEY (id);
alter table public."episodes" add constraint "episodes_content_id_key" UNIQUE (content_id);
alter table public."shots" add constraint "shots_episode_id_shot_code_key" UNIQUE (episode_id, shot_code);
alter table public."shots" add constraint "shots_episode_id_shot_order_key" UNIQUE (episode_id, shot_order);
alter table public."attempts" add constraint "attempts_idempotency_key_key" UNIQUE (idempotency_key);
alter table public."attempts" add constraint "attempts_shot_id_attempt_no_key" UNIQUE (shot_id, attempt_no);
alter table public."series" add constraint "series_series_code_key" UNIQUE (series_code);
alter table public."style_bibles" add constraint "style_bibles_series_id_version_key" UNIQUE (series_id, version);
alter table public."characters" add constraint "characters_series_id_character_code_version_key" UNIQUE (series_id, character_code, version);
alter table public."character_outfits" add constraint "character_outfits_character_id_outfit_code_version_key" UNIQUE (character_id, outfit_code, version);
alter table public."locations" add constraint "locations_series_id_location_code_version_key" UNIQUE (series_id, location_code, version);
alter table public."voice_identities" add constraint "voice_identities_character_id_voice_code_version_key" UNIQUE (character_id, voice_code, version);
alter table public."props" add constraint "props_series_id_prop_code_version_key" UNIQUE (series_id, prop_code, version);
alter table public."asset_registry" add constraint "asset_registry_series_id_asset_code_version_key" UNIQUE (series_id, asset_code, version);
alter table public."location_relationships" add constraint "location_relationships_unique" UNIQUE (series_id, from_location_id, to_location_id, relationship_type);
alter table public."location_asset_plan" add constraint "location_asset_plan_series_id_location_id_asset_code_key" UNIQUE (series_id, location_id, asset_code);
alter table public."scenes" add constraint "scenes_episode_scene_code_key" UNIQUE (episode_id, scene_code);
alter table public."scenes" add constraint "scenes_episode_scene_order_key" UNIQUE (episode_id, scene_order);
alter table public."shot_specifications" add constraint "shot_specifications_shot_version_key" UNIQUE (shot_id, version);
alter table public."production_manifests" add constraint "production_manifests_episode_version_key" UNIQUE (episode_id, production_version);
alter table public."production_manifests" add constraint "production_manifests_manifest_code_key" UNIQUE (manifest_code);
alter table public."production_manifest_shots" add constraint "production_manifest_shots_manifest_order_key" UNIQUE (manifest_id, manifest_order);
alter table public."production_manifest_shots" add constraint "production_manifest_shots_manifest_shot_key" UNIQUE (manifest_id, shot_id);
alter table public."generation_outputs" add constraint "generation_outputs_attempt_output_key" UNIQUE (attempt_id, output_no);
alter table public."shot_reference_assets" add constraint "shot_reference_assets_spec_asset_role_key" UNIQUE (shot_specification_id, asset_id, reference_role);
alter table public."storyboard_reviews" add constraint "storyboard_reviews_spec_key" UNIQUE (shot_specification_id);
alter table public."shot_audio_productions" add constraint "shot_audio_productions_spec_order_take_key" UNIQUE (shot_specification_id, audio_order, take_no);
alter table public."generation_providers" add constraint "generation_providers_provider_code_key" UNIQUE (provider_code);
alter table public."generation_models" add constraint "generation_models_provider_code_key" UNIQUE (provider_id, model_code);
alter table public."generation_model_pricing" add constraint "generation_model_pricing_version_key" UNIQUE (model_id, pricing_version);
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_version_key" UNIQUE (model_id, benchmark_version);
alter table public."generation_routing_policies" add constraint "generation_routing_policies_code_version_key" UNIQUE (policy_code, version);
alter table public."generation_policy_models" add constraint "generation_policy_models_policy_model_key" UNIQUE (policy_id, model_id);
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_shot_attempt_revision_key" UNIQUE (shot_id, attempt_no, decision_revision);
alter table public."generation_benchmark_runs" add constraint "generation_benchmark_runs_run_code_key" UNIQUE (run_code);
alter table public."generation_benchmark_cases" add constraint "generation_benchmark_cases_unique_code" UNIQUE (benchmark_run_id, case_code);
alter table public."generation_benchmark_cases" add constraint "generation_benchmark_cases_unique_order" UNIQUE (benchmark_run_id, case_order);
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_unique_attempt" UNIQUE (benchmark_case_id, model_id, attempt_no);
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_job_key" UNIQUE (benchmark_job_id);
alter table public."production_creative_profiles" add constraint "production_creative_profiles_code_version_key" UNIQUE (profile_code, version);
alter table public."approval_requests" add constraint "approval_requests_token_hash_key" UNIQUE (token_hash);
alter table public."budgets" add constraint "budgets_budget_type_check" CHECK ((budget_type = ANY (ARRAY['MONTHLY'::text, 'EPISODE'::text, 'SHOT'::text])));
alter table public."budgets" add constraint "budgets_check" CHECK (((period_end IS NULL) OR (period_start IS NULL) OR (period_end > period_start)));
alter table public."budgets" add constraint "budgets_currency_check" CHECK ((currency = 'USD'::text));
alter table public."budgets" add constraint "budgets_hard_limit_check" CHECK ((hard_limit >= (0)::numeric));
alter table public."budgets" add constraint "budgets_reserved_amount_check" CHECK ((reserved_amount >= (0)::numeric));
alter table public."budgets" add constraint "budgets_settled_amount_check" CHECK ((settled_amount >= (0)::numeric));
alter table public."episodes" add constraint "episodes_currency_check" CHECK ((currency = 'USD'::text));
alter table public."episodes" add constraint "episodes_maximum_budget_check" CHECK (((maximum_budget IS NULL) OR (maximum_budget >= (0)::numeric)));
alter table public."episodes" add constraint "episodes_production_mode_check" CHECK ((production_mode = ANY (ARRAY['MICRO_SHORT'::text, 'SERIES_EPISODE'::text])));
alter table public."episodes" add constraint "episodes_state_check" CHECK ((state = ANY (ARRAY['PLANNED'::text, 'PREPRODUCTION'::text, 'APPROVED'::text, 'PRODUCTION'::text, 'ASSEMBLY'::text, 'FINAL_QC'::text, 'READY_TO_PUBLISH'::text, 'PUBLISHED'::text, 'BLOCKED'::text, 'CANCELLED'::text])));
alter table public."shots" add constraint "shots_asset_version_check" CHECK ((asset_version > 0));
alter table public."shots" add constraint "shots_currency_check" CHECK ((currency = 'USD'::text));
alter table public."shots" add constraint "shots_maximum_budget_check" CHECK (((maximum_budget IS NULL) OR (maximum_budget >= (0)::numeric)));
alter table public."shots" add constraint "shots_prompt_version_check" CHECK ((prompt_version > 0));
alter table public."shots" add constraint "shots_shot_order_check" CHECK ((shot_order > 0));
alter table public."shots" add constraint "shots_state_check" CHECK ((state = ANY (ARRAY['PLANNED'::text, 'STORYBOARD_PENDING'::text, 'STORYBOARD_APPROVED'::text, 'AUDIO_READY'::text, 'QUEUED'::text, 'GENERATING'::text, 'GENERATED'::text, 'QC_PENDING'::text, 'LOCKED'::text, 'RETRY_REQUIRED'::text, 'ESCALATED'::text, 'FAILED_TECHNICAL'::text, 'CANCELLED'::text])));
alter table public."attempts" add constraint "attempts_actual_cost_check" CHECK (((actual_cost IS NULL) OR (actual_cost >= (0)::numeric)));
alter table public."attempts" add constraint "attempts_attempt_no_check" CHECK (((attempt_no >= 1) AND (attempt_no <= 2)));
alter table public."attempts" add constraint "attempts_estimated_cost_check" CHECK ((estimated_cost >= (0)::numeric));
alter table public."attempts" add constraint "attempts_prompt_version_check" CHECK ((prompt_version > 0));
alter table public."attempts" add constraint "attempts_recovery_count_nonnegative" CHECK ((recovery_count >= 0));
alter table public."attempts" add constraint "attempts_status_check" CHECK ((status = ANY (ARRAY['CREATED'::text, 'BUDGET_RESERVED'::text, 'SUBMITTED'::text, 'GENERATING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'CANCELLED'::text, 'ESCALATED'::text])));
alter table public."cost_ledger" add constraint "cost_ledger_amount_check" CHECK ((amount >= (0)::numeric));
alter table public."cost_ledger" add constraint "cost_ledger_currency_check" CHECK ((currency = 'USD'::text));
alter table public."cost_ledger" add constraint "cost_ledger_entry_type_check" CHECK ((entry_type = ANY (ARRAY['RESERVE'::text, 'SETTLE'::text, 'RELEASE'::text, 'ADJUSTMENT'::text])));
alter table public."events" add constraint "events_severity_check" CHECK ((severity = ANY (ARRAY['INFO'::text, 'WARNING'::text, 'ERROR'::text, 'CRITICAL'::text])));
alter table public."series" add constraint "series_check" CHECK (((target_age_max IS NULL) OR (target_age_max >= target_age_min)));
alter table public."series" add constraint "series_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."series" add constraint "series_target_age_min_check" CHECK (((target_age_min IS NULL) OR (target_age_min >= 0)));
alter table public."series" add constraint "series_version_check" CHECK ((version > 0));
alter table public."style_bibles" add constraint "style_bibles_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."style_bibles" add constraint "style_bibles_version_check" CHECK ((version > 0));
alter table public."characters" add constraint "characters_age_check" CHECK (((age IS NULL) OR (age >= 0)));
alter table public."characters" add constraint "characters_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."characters" add constraint "characters_version_check" CHECK ((version > 0));
alter table public."character_outfits" add constraint "character_outfits_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."character_outfits" add constraint "character_outfits_version_check" CHECK ((version > 0));
alter table public."locations" add constraint "locations_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."locations" add constraint "locations_version_check" CHECK ((version > 0));
alter table public."voice_identities" add constraint "voice_identities_speech_rate_check" CHECK (((speech_rate IS NULL) OR (speech_rate > (0)::numeric)));
alter table public."voice_identities" add constraint "voice_identities_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."voice_identities" add constraint "voice_identities_version_check" CHECK ((version > 0));
alter table public."props" add constraint "props_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."props" add constraint "props_version_check" CHECK ((version > 0));
alter table public."asset_registry" add constraint "asset_registry_asset_type_check" CHECK ((asset_type = ANY (ARRAY['STYLE_REFERENCE'::text, 'CHARACTER_REFERENCE'::text, 'CHARACTER_EXPRESSION'::text, 'CHARACTER_OUTFIT'::text, 'LOCATION_REFERENCE'::text, 'PROP_REFERENCE'::text, 'VOICE_REFERENCE'::text, 'OTHER'::text])));
alter table public."asset_registry" add constraint "asset_registry_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'ARCHIVED'::text])));
alter table public."asset_registry" add constraint "asset_registry_version_check" CHECK ((version > 0));
alter table public."asset_qualification_tests" add constraint "asset_qualification_tests_result_check" CHECK ((result = ANY (ARRAY['PENDING'::text, 'PASS'::text, 'FAIL'::text, 'HUMAN_REVIEW'::text])));
alter table public."asset_qualification_tests" add constraint "asset_qualification_tests_score_check" CHECK (((score IS NULL) OR ((score >= (0)::numeric) AND (score <= (100)::numeric))));
alter table public."location_relationships" add constraint "location_relationships_not_self" CHECK ((from_location_id <> to_location_id));
alter table public."location_relationships" add constraint "location_relationships_travel_minutes" CHECK (((approximate_travel_minutes IS NULL) OR (approximate_travel_minutes >= 0)));
alter table public."location_asset_plan" add constraint "location_asset_plan_priority_check" CHECK ((priority = ANY (ARRAY['CRITICAL'::text, 'HIGH'::text, 'MEDIUM'::text, 'LOW'::text])));
alter table public."location_asset_plan" add constraint "location_asset_plan_status_check" CHECK ((status = ANY (ARRAY['PLANNED'::text, 'GENERATED'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'REJECTED'::text])));
alter table public."scenes" add constraint "scenes_duration_check" CHECK (((estimated_duration_seconds IS NULL) OR (estimated_duration_seconds > (0)::numeric)));
alter table public."scenes" add constraint "scenes_scene_order_check" CHECK ((scene_order > 0));
alter table public."scenes" add constraint "scenes_state_check" CHECK ((state = ANY (ARRAY['PLANNED'::text, 'SCRIPTED'::text, 'STORYBOARD_PENDING'::text, 'STORYBOARD_APPROVED'::text, 'PRODUCTION_READY'::text, 'IN_PRODUCTION'::text, 'COMPLETE'::text, 'BLOCKED'::text, 'CANCELLED'::text])));
alter table public."shot_specifications" add constraint "shot_specifications_aspect_ratio_check" CHECK ((aspect_ratio = ANY (ARRAY['16:9'::text, '9:16'::text, '1:1'::text, '4:3'::text])));
alter table public."shot_specifications" add constraint "shot_specifications_duration_check" CHECK (((duration_seconds >= (1)::numeric) AND (duration_seconds <= (15)::numeric)));
alter table public."shot_specifications" add constraint "shot_specifications_fps_check" CHECK ((fps = ANY (ARRAY[24, 25, 30, 50, 60])));
alter table public."shot_specifications" add constraint "shot_specifications_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'REVIEW_PENDING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'SUPERSEDED'::text])));
alter table public."shot_specifications" add constraint "shot_specifications_version_check" CHECK ((version > 0));
alter table public."production_manifests" add constraint "production_manifests_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'REVIEW_PENDING'::text, 'HUMAN_APPROVED'::text, 'LOCKED'::text, 'SUPERSEDED'::text, 'CANCELLED'::text])));
alter table public."production_manifests" add constraint "production_manifests_version_check" CHECK ((production_version > 0));
alter table public."production_manifest_shots" add constraint "production_manifest_shots_order_check" CHECK ((manifest_order > 0));
alter table public."generation_outputs" add constraint "generation_outputs_duration_check" CHECK (((duration_seconds IS NULL) OR (duration_seconds > (0)::numeric)));
alter table public."generation_outputs" add constraint "generation_outputs_file_size_check" CHECK (((file_size_bytes IS NULL) OR (file_size_bytes >= 0)));
alter table public."generation_outputs" add constraint "generation_outputs_fps_check" CHECK (((fps IS NULL) OR (fps > (0)::numeric)));
alter table public."generation_outputs" add constraint "generation_outputs_height_check" CHECK (((height IS NULL) OR (height > 0)));
alter table public."generation_outputs" add constraint "generation_outputs_output_no_check" CHECK ((output_no > 0));
alter table public."generation_outputs" add constraint "generation_outputs_qc_score_check" CHECK (((qc_score IS NULL) OR ((qc_score >= (0)::numeric) AND (qc_score <= (100)::numeric))));
alter table public."generation_outputs" add constraint "generation_outputs_qc_status_check" CHECK ((qc_status = ANY (ARRAY['PENDING'::text, 'IN_REVIEW'::text, 'PASS'::text, 'FAIL'::text, 'HUMAN_REVIEW'::text])));
alter table public."generation_outputs" add constraint "generation_outputs_status_check" CHECK ((status = ANY (ARRAY['REGISTERED'::text, 'AVAILABLE'::text, 'REJECTED'::text, 'CANONICAL'::text, 'ARCHIVED'::text])));
alter table public."generation_outputs" add constraint "generation_outputs_width_check" CHECK (((width IS NULL) OR (width > 0)));
alter table public."shot_reference_assets" add constraint "shot_reference_assets_order_check" CHECK ((reference_order > 0));
alter table public."shot_reference_assets" add constraint "shot_reference_assets_role_check" CHECK ((reference_role = ANY (ARRAY['STYLE'::text, 'CHARACTER'::text, 'EXPRESSION'::text, 'OUTFIT'::text, 'LOCATION'::text, 'PROP'::text, 'STORYBOARD'::text, 'COMPOSITION'::text, 'OTHER'::text])));
alter table public."storyboard_reviews" add constraint "storyboard_reviews_score_check" CHECK (((score IS NULL) OR ((score >= (0)::numeric) AND (score <= (100)::numeric))));
alter table public."storyboard_reviews" add constraint "storyboard_reviews_status_check" CHECK ((status = ANY (ARRAY['PENDING'::text, 'IN_REVIEW'::text, 'APPROVED'::text, 'REJECTED'::text])));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_dialogue_check" CHECK ((btrim(dialogue_text) <> ''::text));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_duration_check" CHECK (((duration_seconds IS NULL) OR (duration_seconds > (0)::numeric)));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_end_check" CHECK (((end_offset_seconds IS NULL) OR (end_offset_seconds >= start_offset_seconds)));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_lip_sync_status_check" CHECK ((lip_sync_status = ANY (ARRAY['PENDING'::text, 'NOT_REQUIRED'::text, 'READY'::text, 'PASS'::text, 'FAIL'::text])));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_order_check" CHECK ((audio_order > 0));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_qc_score_check" CHECK (((qc_score IS NULL) OR ((qc_score >= (0)::numeric) AND (qc_score <= (100)::numeric))));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_qc_status_check" CHECK ((qc_status = ANY (ARRAY['PENDING'::text, 'IN_REVIEW'::text, 'PASS'::text, 'FAIL'::text])));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_start_check" CHECK ((start_offset_seconds >= (0)::numeric));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_status_check" CHECK ((status = ANY (ARRAY['PLANNED'::text, 'GENERATING'::text, 'GENERATED'::text, 'QC_PENDING'::text, 'APPROVED'::text, 'REJECTED'::text, 'ARCHIVED'::text])));
alter table public."shot_audio_productions" add constraint "shot_audio_productions_take_check" CHECK ((take_no > 0));
alter table public."generation_providers" add constraint "generation_providers_code_check" CHECK ((btrim(provider_code) <> ''::text));
alter table public."generation_providers" add constraint "generation_providers_name_check" CHECK ((btrim(display_name) <> ''::text));
alter table public."generation_providers" add constraint "generation_providers_priority_check" CHECK ((priority > 0));
alter table public."generation_providers" add constraint "generation_providers_status_check" CHECK ((status = ANY (ARRAY['DISABLED'::text, 'TESTING'::text, 'ACTIVE'::text, 'DEGRADED'::text, 'SUSPENDED'::text])));
alter table public."generation_providers" add constraint "generation_providers_type_check" CHECK ((provider_type = ANY (ARRAY['VIDEO'::text, 'IMAGE'::text, 'AUDIO'::text, 'MULTIMODAL'::text])));
alter table public."generation_models" add constraint "generation_models_aspect_ratios_array_check" CHECK ((jsonb_typeof(supported_aspect_ratios) = 'array'::text));
alter table public."generation_models" add constraint "generation_models_code_check" CHECK ((btrim(model_code) <> ''::text));
alter table public."generation_models" add constraint "generation_models_duration_range_check" CHECK (((min_duration_seconds IS NULL) OR (max_duration_seconds IS NULL) OR (max_duration_seconds >= min_duration_seconds)));
alter table public."generation_models" add constraint "generation_models_max_duration_check" CHECK (((max_duration_seconds IS NULL) OR (max_duration_seconds > (0)::numeric)));
alter table public."generation_models" add constraint "generation_models_media_type_check" CHECK ((media_type = ANY (ARRAY['VIDEO'::text, 'IMAGE'::text, 'AUDIO'::text, 'MULTIMODAL'::text])));
alter table public."generation_models" add constraint "generation_models_min_duration_check" CHECK (((min_duration_seconds IS NULL) OR (min_duration_seconds > (0)::numeric)));
alter table public."generation_models" add constraint "generation_models_name_check" CHECK ((btrim(display_name) <> ''::text));
alter table public."generation_models" add constraint "generation_models_priority_check" CHECK ((priority > 0));
alter table public."generation_models" add constraint "generation_models_resolutions_array_check" CHECK ((jsonb_typeof(supported_resolutions) = 'array'::text));
alter table public."generation_models" add constraint "generation_models_status_check" CHECK ((status = ANY (ARRAY['DISABLED'::text, 'TESTING'::text, 'ACTIVE'::text, 'DEGRADED'::text, 'SUSPENDED'::text])));
alter table public."generation_model_pricing" add constraint "generation_model_pricing_currency_check" CHECK ((currency = 'USD'::text));
alter table public."generation_model_pricing" add constraint "generation_model_pricing_minimum_check" CHECK ((minimum_charge >= (0)::numeric));
alter table public."generation_model_pricing" add constraint "generation_model_pricing_period_check" CHECK (((effective_to IS NULL) OR (effective_to > effective_from)));
alter table public."generation_model_pricing" add constraint "generation_model_pricing_price_check" CHECK ((unit_price >= (0)::numeric));
alter table public."generation_model_pricing" add constraint "generation_model_pricing_unit_check" CHECK ((billing_unit = ANY (ARRAY['PER_SECOND'::text, 'PER_GENERATION'::text, 'PER_CREDIT'::text, 'PER_IMAGE'::text, 'PER_AUDIO_SECOND'::text, 'CUSTOM'::text])));
alter table public."generation_model_pricing" add constraint "generation_model_pricing_verified_check" CHECK (((is_verified = false) OR (verified_at IS NOT NULL)));
alter table public."generation_model_pricing" add constraint "generation_model_pricing_version_check" CHECK ((pricing_version > 0));
alter table public."generation_model_health" add constraint "generation_model_health_latency_check" CHECK (((average_latency_seconds IS NULL) OR (average_latency_seconds >= (0)::numeric)));
alter table public."generation_model_health" add constraint "generation_model_health_status_check" CHECK ((availability_status = ANY (ARRAY['UNKNOWN'::text, 'AVAILABLE'::text, 'DEGRADED'::text, 'UNAVAILABLE'::text])));
alter table public."generation_model_health" add constraint "generation_model_health_success_rate_check" CHECK (((success_rate IS NULL) OR ((success_rate >= (0)::numeric) AND (success_rate <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_anatomy_check" CHECK (((anatomy_score IS NULL) OR ((anatomy_score >= (0)::numeric) AND (anatomy_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_approval_check" CHECK (((benchmark_status <> 'HUMAN_APPROVED'::text) OR (approved_at IS NOT NULL)));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_camera_check" CHECK (((camera_score IS NULL) OR ((camera_score >= (0)::numeric) AND (camera_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_continuity_check" CHECK (((continuity_score IS NULL) OR ((continuity_score >= (0)::numeric) AND (continuity_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_expression_check" CHECK (((expression_score IS NULL) OR ((expression_score >= (0)::numeric) AND (expression_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_face_check" CHECK (((face_score IS NULL) OR ((face_score >= (0)::numeric) AND (face_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_generation_time_check" CHECK (((average_generation_seconds IS NULL) OR (average_generation_seconds >= (0)::numeric)));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_lipsync_check" CHECK (((lip_sync_score IS NULL) OR ((lip_sync_score >= (0)::numeric) AND (lip_sync_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_motion_check" CHECK (((motion_score IS NULL) OR ((motion_score >= (0)::numeric) AND (motion_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_name_check" CHECK ((btrim(benchmark_name) <> ''::text));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_overall_check" CHECK (((overall_quality_score IS NULL) OR ((overall_quality_score >= (0)::numeric) AND (overall_quality_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_pass_rate_check" CHECK (((pass_rate IS NULL) OR ((pass_rate >= (0)::numeric) AND (pass_rate <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_prompt_check" CHECK (((prompt_adherence_score IS NULL) OR ((prompt_adherence_score >= (0)::numeric) AND (prompt_adherence_score <= (100)::numeric))));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_sample_check" CHECK ((sample_size >= 0));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_status_check" CHECK ((benchmark_status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'HUMAN_APPROVED'::text, 'SUPERSEDED'::text])));
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_version_check" CHECK ((benchmark_version > 0));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_activation_check" CHECK (((status <> 'ACTIVE'::text) OR (approved_at IS NOT NULL)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_attempt_check" CHECK (((max_attempts >= 1) AND (max_attempts <= 2)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_code_check" CHECK ((btrim(policy_code) <> ''::text));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_cost_weight_check" CHECK (((cost_weight >= (0)::numeric) AND (cost_weight <= (1)::numeric)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_latency_weight_check" CHECK (((latency_weight >= (0)::numeric) AND (latency_weight <= (1)::numeric)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_name_check" CHECK ((btrim(display_name) <> ''::text));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_pass_floor_check" CHECK (((minimum_pass_rate >= (0)::numeric) AND (minimum_pass_rate <= (100)::numeric)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_quality_floor_check" CHECK (((minimum_quality_score >= (0)::numeric) AND (minimum_quality_score <= (100)::numeric)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_quality_weight_check" CHECK (((quality_weight >= (0)::numeric) AND (quality_weight <= (1)::numeric)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_reliability_weight_check" CHECK (((reliability_weight >= (0)::numeric) AND (reliability_weight <= (1)::numeric)));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'TESTING'::text, 'ACTIVE'::text, 'SUPERSEDED'::text, 'DISABLED'::text])));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_version_check" CHECK ((version > 0));
alter table public."generation_routing_policies" add constraint "generation_routing_policies_weights_check" CHECK ((abs(((((quality_weight + cost_weight) + reliability_weight) + latency_weight) - 1.0)) < 0.000001));
alter table public."generation_policy_models" add constraint "generation_policy_models_cost_check" CHECK (((maximum_estimated_cost IS NULL) OR (maximum_estimated_cost >= (0)::numeric)));
alter table public."generation_policy_models" add constraint "generation_policy_models_priority_check" CHECK ((route_priority > 0));
alter table public."generation_policy_models" add constraint "generation_policy_models_quality_check" CHECK (((minimum_quality_override IS NULL) OR ((minimum_quality_override >= (0)::numeric) AND (minimum_quality_override <= (100)::numeric))));
alter table public."generation_policy_models" add constraint "generation_policy_models_role_check" CHECK ((route_role = ANY (ARRAY['PRIMARY'::text, 'FALLBACK'::text, 'EMERGENCY'::text])));
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_attempt_check" CHECK (((attempt_no >= 1) AND (attempt_no <= 2)));
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_cost_check" CHECK (((estimated_cost IS NULL) OR (estimated_cost >= (0)::numeric)));
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_revision_check" CHECK ((decision_revision >= 1));
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_role_check" CHECK (((route_role IS NULL) OR (route_role = ANY (ARRAY['PRIMARY'::text, 'FALLBACK'::text, 'EMERGENCY'::text]))));
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_status_check" CHECK ((decision_status = ANY (ARRAY['PENDING'::text, 'SELECTED'::text, 'NO_ELIGIBLE_MODEL'::text, 'BUDGET_BLOCKED'::text, 'HEALTH_BLOCKED'::text, 'PRICING_BLOCKED'::text])));
alter table public."generation_benchmark_runs" add constraint "generation_benchmark_runs_approval_check" CHECK (((status <> 'HUMAN_APPROVED'::text) OR ((human_approved = true) AND (approved_at IS NOT NULL))));
alter table public."generation_benchmark_runs" add constraint "generation_benchmark_runs_budget_check" CHECK (((hard_budget_usd >= (0)::numeric) AND (reserved_usd >= (0)::numeric) AND (settled_usd >= (0)::numeric)));
alter table public."generation_benchmark_runs" add constraint "generation_benchmark_runs_count_check" CHECK (((max_generation_count > 0) AND (generation_count >= 0) AND (generation_count <= max_generation_count)));
alter table public."generation_benchmark_runs" add constraint "generation_benchmark_runs_running_check" CHECK (((status <> 'RUNNING'::text) OR ((human_approved = true) AND (approved_at IS NOT NULL) AND (started_at IS NOT NULL))));
alter table public."generation_benchmark_runs" add constraint "generation_benchmark_runs_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'HUMAN_APPROVED'::text, 'RUNNING'::text, 'COMPLETED'::text, 'CANCELLED'::text, 'BLOCKED'::text])));
alter table public."generation_benchmark_cases" add constraint "generation_benchmark_cases_aspect_check" CHECK ((aspect_ratio = ANY (ARRAY['16:9'::text, '9:16'::text, '1:1'::text, '4:3'::text])));
alter table public."generation_benchmark_cases" add constraint "generation_benchmark_cases_duration_check" CHECK (((duration_seconds > (0)::numeric) AND (duration_seconds <= (15)::numeric)));
alter table public."generation_benchmark_cases" add constraint "generation_benchmark_cases_order_check" CHECK ((case_order > 0));
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_attempt_check" CHECK (((attempt_no >= 1) AND (attempt_no <= 2)));
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_cost_check" CHECK (((estimated_cost >= (0)::numeric) AND ((actual_cost IS NULL) OR (actual_cost >= (0)::numeric))));
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_status_check" CHECK ((status = ANY (ARRAY['CREATED'::text, 'BUDGET_RESERVED'::text, 'SUBMITTED'::text, 'GENERATING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'CANCELLED'::text])));
alter table public."generation_model_health_history" add constraint "generation_model_health_history_latency_check" CHECK (((average_latency_seconds IS NULL) OR (average_latency_seconds >= (0)::numeric)));
alter table public."generation_model_health_history" add constraint "generation_model_health_history_new_status_check" CHECK ((new_status = ANY (ARRAY['UNKNOWN'::text, 'AVAILABLE'::text, 'DEGRADED'::text, 'UNAVAILABLE'::text])));
alter table public."generation_model_health_history" add constraint "generation_model_health_history_previous_status_check" CHECK (((previous_status IS NULL) OR (previous_status = ANY (ARRAY['UNKNOWN'::text, 'AVAILABLE'::text, 'DEGRADED'::text, 'UNAVAILABLE'::text]))));
alter table public."generation_model_health_history" add constraint "generation_model_health_history_source_check" CHECK ((check_source = ANY (ARRAY['API_HEALTH_CHECK'::text, 'BENCHMARK'::text, 'PROVIDER_RESPONSE'::text, 'MANUAL_INCIDENT'::text, 'SYSTEM_RECOVERY'::text])));
alter table public."generation_model_health_history" add constraint "generation_model_health_history_success_rate_check" CHECK (((success_rate IS NULL) OR ((success_rate >= (0)::numeric) AND (success_rate <= (1)::numeric))));
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_authorized_check" CHECK (((authorization_status <> ALL (ARRAY['AUTHORIZED'::text, 'CONSUMED'::text])) OR (authorized_at IS NOT NULL)));
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_consumed_check" CHECK (((authorization_status <> 'CONSUMED'::text) OR (consumed_at IS NOT NULL)));
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_cost_check" CHECK ((authorized_estimated_cost >= (0)::numeric));
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_stage_check" CHECK ((authorization_stage = ANY (ARRAY['PILOT'::text, 'EXPANSION'::text])));
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_status_check" CHECK ((authorization_status = ANY (ARRAY['PLANNED'::text, 'AUTHORIZED'::text, 'CONSUMED'::text, 'REVOKED'::text])));
alter table public."production_creative_profiles" add constraint "production_creative_profiles_attempt_check" CHECK (((max_paid_attempts >= 1) AND (max_paid_attempts <= 2)));
alter table public."production_creative_profiles" add constraint "production_creative_profiles_duration_check" CHECK (((target_duration_min_seconds > (0)::numeric) AND (target_duration_max_seconds >= target_duration_min_seconds) AND (hard_duration_max_seconds >= target_duration_max_seconds)));
alter table public."production_creative_profiles" add constraint "production_creative_profiles_hook_check" CHECK (((hook_deadline_seconds > (0)::numeric) AND (hook_deadline_seconds <= hard_duration_max_seconds)));
alter table public."production_creative_profiles" add constraint "production_creative_profiles_mode_check" CHECK ((production_mode = ANY (ARRAY['MICRO_SHORT'::text, 'SERIES_EPISODE'::text])));
alter table public."production_creative_profiles" add constraint "production_creative_profiles_ratio_check" CHECK ((aspect_ratio = ANY (ARRAY['9:16'::text, '16:9'::text, '1:1'::text, '4:3'::text])));
alter table public."production_creative_profiles" add constraint "production_creative_profiles_status_check" CHECK ((status = ANY (ARRAY['DRAFT'::text, 'ACTIVE'::text, 'LOCKED'::text, 'SUPERSEDED'::text])));
alter table public."production_creative_profiles" add constraint "production_creative_profiles_version_check" CHECK ((version > 0));
alter table public."approval_requests" add constraint "approval_requests_decision_check" CHECK (((status <> ALL (ARRAY['APPROVED'::text, 'REJECTED'::text])) OR ((decided_at IS NOT NULL) AND (decided_by IS NOT NULL) AND (btrim(decided_by) <> ''::text))));
alter table public."approval_requests" add constraint "approval_requests_scope_check" CHECK ((scope_type = ANY (ARRAY['EPISODE_PRODUCTION'::text, 'EPISODE_PUBLISH'::text, 'SHOT_ESCALATION'::text])));
alter table public."approval_requests" add constraint "approval_requests_status_check" CHECK ((status = ANY (ARRAY['PENDING'::text, 'APPROVED'::text, 'REJECTED'::text, 'EXPIRED'::text, 'SUPERSEDED'::text])));
alter table public."episodes" add constraint "episodes_creative_profile_id_fkey" FOREIGN KEY (creative_profile_id) REFERENCES production_creative_profiles(id) ON DELETE RESTRICT;
alter table public."episodes" add constraint "episodes_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE RESTRICT;
alter table public."shots" add constraint "shots_episode_id_fkey" FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE RESTRICT;
alter table public."shots" add constraint "shots_scene_id_fkey" FOREIGN KEY (scene_id) REFERENCES scenes(id) ON DELETE RESTRICT;
alter table public."attempts" add constraint "attempts_episode_budget_id_fkey" FOREIGN KEY (episode_budget_id) REFERENCES budgets(id) ON DELETE RESTRICT;
alter table public."attempts" add constraint "attempts_monthly_budget_id_fkey" FOREIGN KEY (monthly_budget_id) REFERENCES budgets(id) ON DELETE RESTRICT;
alter table public."attempts" add constraint "attempts_routing_decision_fkey" FOREIGN KEY (routing_decision_id) REFERENCES generation_routing_decisions(id) ON DELETE RESTRICT;
alter table public."attempts" add constraint "attempts_shot_budget_id_fkey" FOREIGN KEY (shot_budget_id) REFERENCES budgets(id) ON DELETE RESTRICT;
alter table public."attempts" add constraint "attempts_shot_id_fkey" FOREIGN KEY (shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."cost_ledger" add constraint "cost_ledger_attempt_id_fkey" FOREIGN KEY (attempt_id) REFERENCES attempts(id) ON DELETE RESTRICT;
alter table public."cost_ledger" add constraint "cost_ledger_episode_id_fkey" FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE RESTRICT;
alter table public."cost_ledger" add constraint "cost_ledger_shot_id_fkey" FOREIGN KEY (shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."events" add constraint "events_attempt_id_fkey" FOREIGN KEY (attempt_id) REFERENCES attempts(id) ON DELETE RESTRICT;
alter table public."events" add constraint "events_episode_id_fkey" FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE RESTRICT;
alter table public."events" add constraint "events_shot_id_fkey" FOREIGN KEY (shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."style_bibles" add constraint "style_bibles_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE RESTRICT;
alter table public."characters" add constraint "characters_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE RESTRICT;
alter table public."character_outfits" add constraint "character_outfits_character_id_fkey" FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE RESTRICT;
alter table public."locations" add constraint "locations_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE RESTRICT;
alter table public."voice_identities" add constraint "voice_identities_character_id_fkey" FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE RESTRICT;
alter table public."props" add constraint "props_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE RESTRICT;
alter table public."asset_registry" add constraint "asset_registry_character_id_fkey" FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE RESTRICT;
alter table public."asset_registry" add constraint "asset_registry_location_id_fkey" FOREIGN KEY (location_id) REFERENCES locations(id) ON DELETE RESTRICT;
alter table public."asset_registry" add constraint "asset_registry_outfit_id_fkey" FOREIGN KEY (outfit_id) REFERENCES character_outfits(id) ON DELETE RESTRICT;
alter table public."asset_registry" add constraint "asset_registry_prop_id_fkey" FOREIGN KEY (prop_id) REFERENCES props(id) ON DELETE RESTRICT;
alter table public."asset_registry" add constraint "asset_registry_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE RESTRICT;
alter table public."asset_registry" add constraint "asset_registry_voice_identity_id_fkey" FOREIGN KEY (voice_identity_id) REFERENCES voice_identities(id) ON DELETE RESTRICT;
alter table public."asset_qualification_tests" add constraint "asset_qualification_tests_asset_id_fkey" FOREIGN KEY (asset_id) REFERENCES asset_registry(id) ON DELETE RESTRICT;
alter table public."location_relationships" add constraint "location_relationships_from_location_id_fkey" FOREIGN KEY (from_location_id) REFERENCES locations(id) ON DELETE CASCADE;
alter table public."location_relationships" add constraint "location_relationships_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE CASCADE;
alter table public."location_relationships" add constraint "location_relationships_to_location_id_fkey" FOREIGN KEY (to_location_id) REFERENCES locations(id) ON DELETE CASCADE;
alter table public."location_asset_plan" add constraint "location_asset_plan_location_id_fkey" FOREIGN KEY (location_id) REFERENCES locations(id) ON DELETE CASCADE;
alter table public."location_asset_plan" add constraint "location_asset_plan_series_id_fkey" FOREIGN KEY (series_id) REFERENCES series(id) ON DELETE CASCADE;
alter table public."scenes" add constraint "scenes_episode_id_fkey" FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE RESTRICT;
alter table public."scenes" add constraint "scenes_location_id_fkey" FOREIGN KEY (location_id) REFERENCES locations(id) ON DELETE RESTRICT;
alter table public."shot_specifications" add constraint "shot_specifications_shot_id_fkey" FOREIGN KEY (shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."production_manifests" add constraint "production_manifests_episode_id_fkey" FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE RESTRICT;
alter table public."production_manifests" add constraint "production_manifests_pilot_shot_id_fkey" FOREIGN KEY (pilot_shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."production_manifest_shots" add constraint "production_manifest_shots_manifest_id_fkey" FOREIGN KEY (manifest_id) REFERENCES production_manifests(id) ON DELETE RESTRICT;
alter table public."production_manifest_shots" add constraint "production_manifest_shots_shot_id_fkey" FOREIGN KEY (shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."production_manifest_shots" add constraint "production_manifest_shots_spec_id_fkey" FOREIGN KEY (shot_specification_id) REFERENCES shot_specifications(id) ON DELETE RESTRICT;
alter table public."generation_outputs" add constraint "generation_outputs_attempt_id_fkey" FOREIGN KEY (attempt_id) REFERENCES attempts(id) ON DELETE RESTRICT;
alter table public."generation_outputs" add constraint "generation_outputs_shot_id_fkey" FOREIGN KEY (shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."shot_reference_assets" add constraint "shot_reference_assets_asset_fkey" FOREIGN KEY (asset_id) REFERENCES asset_registry(id) ON DELETE RESTRICT;
alter table public."shot_reference_assets" add constraint "shot_reference_assets_spec_fkey" FOREIGN KEY (shot_specification_id) REFERENCES shot_specifications(id) ON DELETE RESTRICT;
alter table public."storyboard_reviews" add constraint "storyboard_reviews_asset_fkey" FOREIGN KEY (storyboard_asset_id) REFERENCES asset_registry(id) ON DELETE RESTRICT;
alter table public."storyboard_reviews" add constraint "storyboard_reviews_spec_fkey" FOREIGN KEY (shot_specification_id) REFERENCES shot_specifications(id) ON DELETE RESTRICT;
alter table public."shot_audio_productions" add constraint "shot_audio_productions_character_fkey" FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE RESTRICT;
alter table public."shot_audio_productions" add constraint "shot_audio_productions_spec_fkey" FOREIGN KEY (shot_specification_id) REFERENCES shot_specifications(id) ON DELETE RESTRICT;
alter table public."shot_audio_productions" add constraint "shot_audio_productions_voice_fkey" FOREIGN KEY (voice_identity_id) REFERENCES voice_identities(id) ON DELETE RESTRICT;
alter table public."generation_models" add constraint "generation_models_provider_fkey" FOREIGN KEY (provider_id) REFERENCES generation_providers(id) ON DELETE RESTRICT;
alter table public."generation_model_pricing" add constraint "generation_model_pricing_model_fkey" FOREIGN KEY (model_id) REFERENCES generation_models(id) ON DELETE RESTRICT;
alter table public."generation_model_health" add constraint "generation_model_health_model_fkey" FOREIGN KEY (model_id) REFERENCES generation_models(id) ON DELETE RESTRICT;
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_model_fkey" FOREIGN KEY (model_id) REFERENCES generation_models(id) ON DELETE RESTRICT;
alter table public."generation_model_benchmarks" add constraint "generation_model_benchmarks_source_job_fk" FOREIGN KEY (source_benchmark_job_id) REFERENCES generation_benchmark_jobs(id) ON DELETE RESTRICT;
alter table public."generation_policy_models" add constraint "generation_policy_models_model_fkey" FOREIGN KEY (model_id) REFERENCES generation_models(id) ON DELETE RESTRICT;
alter table public."generation_policy_models" add constraint "generation_policy_models_policy_fkey" FOREIGN KEY (policy_id) REFERENCES generation_routing_policies(id) ON DELETE RESTRICT;
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_model_fkey" FOREIGN KEY (selected_model_id) REFERENCES generation_models(id) ON DELETE RESTRICT;
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_policy_fkey" FOREIGN KEY (policy_id) REFERENCES generation_routing_policies(id) ON DELETE RESTRICT;
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_pricing_fkey" FOREIGN KEY (selected_pricing_id) REFERENCES generation_model_pricing(id) ON DELETE RESTRICT;
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_shot_fkey" FOREIGN KEY (shot_id) REFERENCES shots(id) ON DELETE RESTRICT;
alter table public."generation_routing_decisions" add constraint "generation_routing_decisions_spec_fkey" FOREIGN KEY (shot_specification_id) REFERENCES shot_specifications(id) ON DELETE RESTRICT;
alter table public."generation_benchmark_cases" add constraint "generation_benchmark_cases_run_fk" FOREIGN KEY (benchmark_run_id) REFERENCES generation_benchmark_runs(id) ON DELETE RESTRICT;
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_case_fk" FOREIGN KEY (benchmark_case_id) REFERENCES generation_benchmark_cases(id) ON DELETE RESTRICT;
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_model_fk" FOREIGN KEY (model_id) REFERENCES generation_models(id) ON DELETE RESTRICT;
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_pricing_fk" FOREIGN KEY (pricing_id) REFERENCES generation_model_pricing(id) ON DELETE RESTRICT;
alter table public."generation_benchmark_jobs" add constraint "generation_benchmark_jobs_run_fk" FOREIGN KEY (benchmark_run_id) REFERENCES generation_benchmark_runs(id) ON DELETE RESTRICT;
alter table public."generation_model_health_history" add constraint "generation_model_health_history_model_fk" FOREIGN KEY (model_id) REFERENCES generation_models(id) ON DELETE RESTRICT;
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_benchmark_job_id_fkey" FOREIGN KEY (benchmark_job_id) REFERENCES generation_benchmark_jobs(id) ON DELETE RESTRICT;
alter table public."generation_benchmark_job_authorizations" add constraint "generation_benchmark_job_authorizations_benchmark_run_id_fkey" FOREIGN KEY (benchmark_run_id) REFERENCES generation_benchmark_runs(id) ON DELETE RESTRICT;
