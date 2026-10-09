-- =====================================================================
-- M417 / WIZZLEBURY  -  002 pipeline layers
--
-- Adds the job / step layer that the Make scenarios call through RPC.
-- Safe to run more than once. Runs in one transaction: on any error
-- nothing is changed.
-- =====================================================================
begin;

do $$
begin
    if to_regclass('public.episodes') is null
       or to_regclass('public.attempts') is null
       or to_regprocedure('public.acquire_generation_attempt_v2(uuid,text)') is null
       or to_regprocedure('public.request_human_approval(text,uuid,text,jsonb,integer)') is null
    then
        raise exception 'M417_BASE_SCHEMA_NOT_FOUND: apply 001 first';
    end if;
    -- The file checks read Supabase Storage's object list.
    if to_regclass('storage.objects') is null
       or not has_table_privilege(current_user, 'storage.objects', 'select')
    then
        raise exception 'M417_STORAGE_NOT_READABLE: role % cannot read storage.objects', current_user;
    end if;
end $$;

create schema if not exists m417_internal;
revoke all on schema m417_internal from public;

-- ---------------------------------------------------------------------
-- 1. Columns on existing tables
-- ---------------------------------------------------------------------
alter table public.episodes
    add column if not exists director_approval_id uuid;
alter table public.production_manifests
    add column if not exists director_approval_id uuid;

-- ---------------------------------------------------------------------
-- 2. New tables
-- ---------------------------------------------------------------------
create table if not exists public.system_text_settings (
    key text primary key,
    value text not null default '',
    description text,
    updated_at timestamptz not null default now()
);

create table if not exists public.production_jobs (
    id uuid primary key default gen_random_uuid(),
    idempotency_key text not null unique,
    series_id uuid not null references public.series(id) on delete restrict,
    episode_id uuid not null unique references public.episodes(id) on delete restrict,
    creative_profile_id uuid not null references public.production_creative_profiles(id) on delete restrict,
    request jsonb not null default '{}'::jsonb,
    current_step integer not null,
    state text not null default 'READY',
    blocked_reason text,
    blocked_detail text,
    revision_count integer not null default 0,
    topic_retry_count integer not null default 0,
    validation_retry_count integer not null default 0,
    revision_feedback jsonb,
    topic_feedback jsonb,
    director_decision_id uuid,
    video_advanced_at timestamptz,
    video_advance_acked_at timestamptz,
    last_activity_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    finished_at timestamptz,
    constraint production_jobs_step_check check (current_step between 1 and 42),
    constraint production_jobs_state_check check (state in (
        'READY', 'IN_PROGRESS', 'WAITING_HUMAN', 'BLOCKED', 'DONE', 'CANCELLED')),
    constraint production_jobs_counters_check check (revision_count >= 0 and topic_retry_count >= 0)
);
create index if not exists idx_production_jobs_state on public.production_jobs (state, current_step);
alter table public.production_jobs
    add column if not exists step_claimed_at timestamptz,
    add column if not exists step_claimed_step integer,
    add column if not exists watchdog_step integer,
    add column if not exists watchdog_resumes integer not null default 0,
    add column if not exists watchdog_last_at timestamptz,
    add column if not exists kick_requested boolean not null default false,
    add column if not exists notified_key text;

-- The owner's decision to use a video model without a paid benchmark:
-- the first shot of the first episode is its trial.
create table if not exists public.generation_model_pilot_approvals (
    id uuid primary key default gen_random_uuid(),
    model_id uuid not null references public.generation_models(id) on delete restrict,
    approved_by text not null,
    approved_at timestamptz not null default now(),
    note text,
    assumed_quality_score numeric not null default 75,
    assumed_pass_rate numeric not null default 80,
    assumed_generation_seconds numeric not null default 180,
    revoked_at timestamptz,
    revoked_by text,
    revoke_reason text,
    constraint generation_model_pilot_approvals_scores_check check (
        assumed_quality_score between 0 and 100 and assumed_pass_rate between 0 and 100
        and assumed_generation_seconds > 0)
);
create unique index if not exists uq_generation_model_pilot_approvals_active
    on public.generation_model_pilot_approvals (model_id) where (revoked_at is null);

-- Voice lines handed to a Make run and not yet registered.
create table if not exists public.voice_handouts (
    shot_specification_id uuid not null,
    audio_order integer not null,
    take_no integer not null,
    handed_out_at timestamptz not null default now(),
    primary key (shot_specification_id, audio_order)
);

-- Publicly readable copies of canonical reference images, one per
-- canonical asset. A video provider fetches them by URL; the canonical
-- originals stay in the private bucket.
create table if not exists public.video_reference_images (
    asset_id uuid primary key references public.asset_registry(id) on delete restrict,
    bucket text not null default 'public-refs',
    object_path text not null,
    is_active boolean not null default true,
    set_by text not null,
    note text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint video_reference_images_path_check check (
        btrim(object_path) <> '' and object_path !~ '^/' and object_path !~ '[[:space:]?#]'
        and btrim(bucket) <> '' and bucket !~ '[/[:space:]?#]')
);

create table if not exists public.job_step_log (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    step_no integer not null,
    event text not null,
    detail jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);
create index if not exists idx_job_step_log_job on public.job_step_log (job_id, created_at);

create table if not exists public.job_artifacts (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    artifact_type text not null,
    producer text not null,
    version integer not null,
    content jsonb not null,
    validation_issues jsonb not null default '[]'::jsonb,
    is_current boolean not null default true,
    created_at timestamptz not null default now(),
    constraint job_artifacts_type_check check (artifact_type in (
        'TREND_REPORT', 'TOPIC_SELECTION', 'SCRIPT', 'SHOT_PACKAGE', 'PREQC_REPORT',
        'MUSIC_SFX_PLAN', 'FINAL_QC_REPORT', 'METADATA_CANDIDATES', 'THUMBNAIL')),
    constraint job_artifacts_producer_check check (producer in (
        'GROK', 'CLAUDE', 'OPENAI', 'GEMINI', 'CANVA', 'SYSTEM')),
    constraint job_artifacts_version_check check (version > 0),
    constraint job_artifacts_job_type_version_key unique (job_id, artifact_type, version)
);
create unique index if not exists uq_job_artifacts_one_current
    on public.job_artifacts (job_id, artifact_type) where (is_current = true);

create table if not exists public.policy_checks (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    gate_no integer not null,
    checker text not null,
    verdict text not null,
    categories jsonb not null default '[]'::jsonb,
    result jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint policy_checks_gate_check check (gate_no in (1, 2)),
    constraint policy_checks_verdict_check check (verdict in ('PASS', 'FAIL'))
);
create index if not exists idx_policy_checks_job on public.policy_checks (job_id, gate_no, created_at);

create table if not exists public.director_decisions (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    episode_id uuid not null references public.episodes(id) on delete restrict,
    production_version integer not null,
    stage text not null,
    decision text not null,
    actor text not null,
    notes text,
    result jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint director_decisions_stage_check check (stage in ('PRODUCTION', 'RELEASE')),
    constraint director_decisions_decision_check check (decision in (
        'APPROVE', 'REVISE_SCRIPT', 'REVISE_SHOTS', 'REJECT')),
    constraint director_decisions_actor_check check (btrim(actor) <> '')
);
create index if not exists idx_director_decisions_job on public.director_decisions (job_id, stage, created_at);

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'episodes_director_approval_id_fkey') then
        alter table public.episodes
            add constraint episodes_director_approval_id_fkey
            foreign key (director_approval_id) references public.director_decisions(id) on delete restrict;
    end if;
    if not exists (select 1 from pg_constraint where conname = 'production_manifests_director_approval_id_fkey') then
        alter table public.production_manifests
            add constraint production_manifests_director_approval_id_fkey
            foreign key (director_approval_id) references public.director_decisions(id) on delete restrict;
    end if;
    if not exists (select 1 from pg_constraint where conname = 'production_jobs_director_decision_id_fkey') then
        alter table public.production_jobs
            add constraint production_jobs_director_decision_id_fkey
            foreign key (director_decision_id) references public.director_decisions(id) on delete restrict;
    end if;
end $$;

create table if not exists public.music_tracks (
    id uuid primary key default gen_random_uuid(),
    track_code text not null unique,
    title text not null,
    role text not null default 'MUSIC',
    mood text,
    storage_path text not null,
    duration_seconds numeric,
    license_type text,
    license_url text,
    license_status text not null default 'PENDING',
    license_checked_by text,
    license_checked_at timestamptz,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    constraint music_tracks_role_check check (role in ('MUSIC', 'SFX')),
    constraint music_tracks_license_status_check check (license_status in ('PENDING', 'VERIFIED', 'REJECTED')),
    constraint music_tracks_verified_check check (
        license_status <> 'VERIFIED'
        or (license_checked_by is not null and license_checked_at is not null and license_type is not null))
);

create table if not exists public.job_music_tracks (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    track_id uuid not null references public.music_tracks(id) on delete restrict,
    role text not null,
    start_seconds numeric not null default 0,
    end_seconds numeric,
    volume numeric not null default 0.25,
    created_at timestamptz not null default now(),
    constraint job_music_tracks_volume_check check (volume >= 0 and volume <= 1)
);
create index if not exists idx_job_music_tracks_job on public.job_music_tracks (job_id);

create table if not exists public.renders (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    episode_id uuid not null references public.episodes(id) on delete restrict,
    render_no integer not null,
    status text not null default 'CREATED',
    shotstack_render_id text,
    request jsonb,
    output_url text,
    storage_path text,
    qc_verdict text,
    qc_score numeric,
    qc_result jsonb,
    error text,
    created_at timestamptz not null default now(),
    submitted_at timestamptz,
    completed_at timestamptz,
    updated_at timestamptz not null default now(),
    constraint renders_status_check check (status in (
        'CREATED', 'SUBMITTED', 'RENDERING', 'DONE', 'STORED', 'QC_PASS', 'QC_FAIL', 'FAILED')),
    constraint renders_job_no_key unique (job_id, render_no)
);

create table if not exists public.publication_packages (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null unique references public.production_jobs(id) on delete restrict,
    title text not null,
    description text not null default '',
    tags jsonb not null default '[]'::jsonb,
    language text,
    made_for_kids boolean not null,
    contains_synthetic_media boolean not null,
    privacy_status text not null,
    selected_by text not null,
    result jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint publication_packages_privacy_check check (privacy_status in ('private', 'unlisted', 'public')),
    constraint publication_packages_title_check check (btrim(title) <> '' and char_length(title) <= 100)
);

create table if not exists public.publications (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null unique references public.production_jobs(id) on delete restrict,
    episode_id uuid not null references public.episodes(id) on delete restrict,
    package_id uuid not null references public.publication_packages(id) on delete restrict,
    approval_request_id uuid not null references public.approval_requests(id) on delete restrict,
    status text not null default 'CLAIMED',
    claimed_at timestamptz not null default now(),
    video_id text,
    url text,
    published_at timestamptz,
    constraint publications_status_check check (status in ('CLAIMED', 'PUBLISHED')),
    constraint publications_published_check check (
        status <> 'PUBLISHED' or (video_id is not null and btrim(video_id) <> '' and published_at is not null))
);

create table if not exists public.analytics_snapshots (
    publication_id uuid not null references public.publications(id) on delete restrict,
    snapshot_date date not null,
    views bigint,
    likes bigint,
    comments bigint,
    minutes_watched numeric,
    average_view_duration_seconds numeric,
    subscribers_gained bigint,
    metrics jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now(),
    primary key (publication_id, snapshot_date)
);

create table if not exists public.learning_reports (
    week_start date primary key,
    report jsonb not null,
    model text,
    summary text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.service_usage (
    id uuid primary key default gen_random_uuid(),
    job_id uuid references public.production_jobs(id) on delete restrict,
    service text not null,
    purpose text not null,
    units numeric not null default 1,
    unit text not null default 'call',
    created_at timestamptz not null default now()
);
create index if not exists idx_service_usage_job on public.service_usage (job_id);

create table if not exists public.service_rates (
    service text not null,
    unit text not null,
    usd_per_unit numeric not null,
    note text,
    updated_at timestamptz not null default now(),
    primary key (service, unit),
    constraint service_rates_price_check check (usd_per_unit >= 0)
);

create table if not exists public.video_action_state (
    attempt_id uuid primary key references public.attempts(id) on delete restrict,
    output_emits integer not null default 0,
    updated_at timestamptz not null default now()
);

create table if not exists public.video_driver_state (
    id boolean primary key default true,
    last_tick_at timestamptz,
    constraint video_driver_state_singleton check (id)
);
insert into public.video_driver_state (id) values (true) on conflict do nothing;

-- No API role reads or writes these tables directly; only the functions do.
do $$
declare
    t text;
begin
    foreach t in array array[
        'system_text_settings', 'production_jobs', 'job_step_log', 'job_artifacts',
        'policy_checks', 'director_decisions', 'music_tracks', 'job_music_tracks',
        'renders', 'publication_packages', 'publications', 'analytics_snapshots',
        'learning_reports', 'service_usage', 'service_rates', 'video_action_state',
        'video_driver_state', 'voice_handouts', 'generation_model_pilot_approvals',
        'video_reference_images']
    loop
        execute format('alter table public.%I enable row level security', t);
        execute format('revoke all on public.%I from public', t);
        if exists (select 1 from pg_roles where rolname = 'anon') then
            execute format('revoke all on public.%I from anon', t);
        end if;
        if exists (select 1 from pg_roles where rolname = 'authenticated') then
            execute format('revoke all on public.%I from authenticated', t);
        end if;
        if exists (select 1 from pg_roles where rolname = 'service_role') then
            execute format('revoke all on public.%I from service_role', t);
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. Settings
-- ---------------------------------------------------------------------
insert into public.system_flags (key, value, description) values
    ('pipeline_enabled', false, 'Master switch for the job pipeline. When false no new job starts and no step advances.'),
    ('storyboard_required', false, 'When false, paid generation does not require an approved storyboard per shot.'),
    ('lip_sync_enforced', false, 'Voices are laid over the clips; no lip-sync is generated. While false, a QC failure on lip-sync alone does not fail a shot or the final edit.'),
    ('made_for_kids', true, 'YouTube audience declaration used for every publication. Owner decision.'),
    ('contains_synthetic_media', true, 'YouTube altered/synthetic content declaration used for every publication.')
on conflict (key) do nothing;

insert into public.system_settings (key, value_numeric, description) values
    ('max_active_jobs', 1, 'Jobs that may be in progress at the same time.'),
    ('max_revisions', 2, 'Script / shot revisions allowed per job before it is blocked.'),
    ('max_topic_retries', 2, 'New topic selections allowed after a failed policy gate 1.'),
    ('max_validation_retries', 2, 'Times a script or shot package may be sent back for failing the automatic format checks.'),
    ('max_characters_per_shot', 3, 'Characters that may be shown in one shot; each needs a reference image.'),
    ('video_prompt_min_chars', 120, 'Shortest video prompt the shot writer may hand in.'),
    ('max_voice_takes', 3, 'Voice takes allowed per dialogue line.'),
    ('max_renders', 2, 'Renders allowed per job.'),
    ('publish_approval_ttl_hours', 72, 'Lifetime of a publish / escalation approval link.'),
    ('voice_duration_tolerance_seconds', 0.5, 'How far the dialogue of a shot may run past the shot duration.'),
    ('min_audio_bytes', 2000, 'A voice file smaller than this fails QC.'),
    ('speech_chars_per_second', 13, 'Speaking rate used to check, before any voice is paid for, that a dialogue line fits its shot.'),
    ('speech_padding_seconds', 0.4, 'Silence a voice file carries around the spoken words.'),
    ('speech_pause_seconds', 0.5, 'Pause the voice makes at a sentence break inside a line (. ! ? ...).'),
    ('max_voice_speed', 1.3, 'Fastest speaking speed a retake may use to make a line fit its shot.'),
    ('min_video_bytes', 20000, 'A video file smaller than this fails technical QC.'),
    ('visual_qc_min_score', 70, 'Minimum Gemini score (0-100) for a shot to pass.'),
    ('final_qc_min_score', 70, 'Minimum Gemini score (0-100) for the final edit to pass.'),
    ('video_claim_stale_minutes', 5, 'A claimed submission without a provider job id is reconciled after this.'),
    ('video_poll_min_interval_seconds', 45, 'Minimum time between two provider polls of one attempt.'),
    ('video_poll_timeout_minutes', 45, 'A submitted attempt without a result is failed after this.'),
    ('video_driver_min_interval_seconds', 90, 'A second driver loop started inside this window stops itself.'),
    ('health_probe_cooldown_minutes', 30, 'A model marked DEGRADED/UNAVAILABLE is not probed again before this.'),
    ('signed_url_ttl_seconds', 86400, 'Lifetime of the signed URLs handed to the renderer.'),
    ('analytics_window_days', 90, 'Publications younger than this get a daily analytics snapshot.'),
    ('job_idle_alert_minutes', 30, 'A READY job without activity for this long is reported by daily maintenance.'),
    ('step_lease_seconds', 180, 'While a paid step is being worked on, a second run asking for the same step is told IN_PROGRESS.'),
    ('voice_handout_seconds', 240, 'A voice line handed to a run is not handed out again inside this window.'),
    ('watchdog_idle_minutes', 12, 'A READY job without activity for this long is started again by the watchdog.'),
    ('watchdog_max_resumes', 3, 'Automatic restarts per step before the job is blocked as STALLED.')
on conflict (key) do nothing;

insert into public.system_text_settings (key, value, description) values
    ('notify_chat_id', '', 'Telegram chat id that receives approval links and reports.'),
    ('webhook_notify', '', 'Make webhook that forwards a text to Telegram (M417-Bildirim).'),
    ('storage_base_url', '', 'https://<project-ref>.supabase.co/storage/v1'),
    ('storage_bucket', 'production-assets', 'Bucket for generated audio, video and renders.'),
    ('privacy_status', 'private', 'YouTube privacy for new publications: private, unlisted or public.'),
    ('default_shot_resolution', '720p', 'Resolution written to shot specifications; must be supported by the video models.'),
    ('render_resolution', 'hd', 'Shotstack output resolution: sd, hd or 1080.'),
    ('voice_provider', 'fish_audio', 'Provider code written to voice takes.'),
    ('webhook_s2', 'https://hook.eu1.make.com/oxy1veavqxqc138e1owgd54rpnet8e9r', 'Make M417-S2 webhook (steps 6-15).'),
    ('webhook_s3', 'https://hook.eu1.make.com/ht10gb9ingzpxpwc7nkk05gpmhdmgfm3', 'Make M417-S3 webhook (steps 16-21).'),
    ('webhook_s4_driver', 'https://hook.eu1.make.com/udxszey777769vpqt34cvy75cjxpya4u', 'Make M417-S4 driver webhook (steps 22-29).'),
    ('webhook_s6', 'https://hook.eu1.make.com/dm40uajshcd4wscixx58st7ezt3w6srp', 'Make M417-S6 webhook (steps 30-34).'),
    ('webhook_s7', 'https://hook.eu1.make.com/tlxyim3nagrxlgdgaxxm50ay8xdsc9ya', 'Make M417-S7 webhook (steps 35-38).'),
    ('webhook_s8', 'https://hook.eu1.make.com/rml6t88snksmhtettm32rp6omr8mremy', 'Make M417-S8 webhook (step 39).')
on conflict (key) do nothing;
