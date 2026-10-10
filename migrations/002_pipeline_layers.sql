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

-- =====================================================================
-- 1b. Film grammar, two-yes rule, prompts kept in the database (010)
-- =====================================================================

-- What the edit uses of a generated clip, and how the shot is staged.
alter table public.shot_specifications
    add column if not exists beats jsonb not null default '[]'::jsonb,
    add column if not exists props jsonb not null default '[]'::jsonb,
    add column if not exists edit_seconds numeric,
    add column if not exists film_size text,
    add column if not exists shot_purpose text,
    add column if not exists voice_staging text,
    add column if not exists qc_brief jsonb;

alter table public.video_reference_images
    add column if not exists wardrobe_note text;

alter table public.production_jobs
    add column if not exists script_no_count integer not null default 0;

alter table public.job_artifacts drop constraint if exists job_artifacts_type_check;
alter table public.job_artifacts add constraint job_artifacts_type_check check (artifact_type in (
    'TREND_REPORT', 'TOPIC_SELECTION', 'SCRIPT', 'SCRIPT_REVIEW', 'SHOT_PACKAGE', 'PREQC_REPORT',
    'MUSIC_SFX_PLAN', 'FINAL_QC_REPORT', 'METADATA_CANDIDATES', 'THUMBNAIL'));

-- One row per vote on a script: the Assistant Director (OpenAI) votes on
-- the Head Director's script, the Head Director (Claude) on the finished
-- package. Nothing is produced without a YES from both.
create table if not exists public.script_votes (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    script_artifact_id uuid not null references public.job_artifacts(id) on delete restrict,
    voter text not null,
    voter_role text not null,
    decision text not null,
    stated_decision text,
    scores jsonb not null default '{}'::jsonb,
    result jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint script_votes_voter_check check (voter in ('CLAUDE', 'OPENAI')),
    constraint script_votes_role_check check (voter_role in ('HEAD_DIRECTOR', 'ASSISTANT_DIRECTOR')),
    constraint script_votes_decision_check check (decision in ('YES', 'NO'))
);
create index if not exists idx_script_votes_job on public.script_votes (job_id, created_at);
create index if not exists idx_script_votes_artifact on public.script_votes (script_artifact_id);
alter table public.script_votes enable row level security;

-- The instructions the writers and reviewers receive. Make sends the
-- text the database hands out, so a change of wording is a change here.
-- Placeholders: [[BIBLE]] [[REQUEST]] [[TOPIC]] [[SCRIPT]] [[SHOT_PACKAGE]]
-- [[FEEDBACK]] [[ASSISTANT_REVIEW]] [[PREQC_REPORT]] [[LIMITS]].
create table if not exists public.step_prompts (
    prompt_code text not null,
    version integer not null,
    is_active boolean not null default true,
    body text not null,
    note text,
    created_at timestamptz not null default now(),
    constraint step_prompts_pkey primary key (prompt_code, version),
    constraint step_prompts_version_check check (version > 0)
);
create unique index if not exists uq_step_prompts_active
    on public.step_prompts (prompt_code) where (is_active = true);
alter table public.step_prompts enable row level security;

do $$
declare
    v_role text;
begin
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on public.script_votes from %I', v_role);
            execute format('revoke all on public.step_prompts from %I', v_role);
        end if;
    end loop;
end $$;

insert into public.system_flags (key, value, description) values
    ('film_grammar_enforced', true, 'Scripts and shot packages must follow the film rules: hook, wardrobe, props, planned shot sizes, cut lengths, one speaker per shot.'),
    ('speaker_closeup_allowed', false, 'May a character speak in a close-up? Off until exact lip-sync is produced.'),
    ('assistant_vote_required', true, 'Two-yes rule: the Assistant Director (OpenAI) must vote YES on the script and the Head Director (Claude) YES on the package before anything is produced.')
on conflict (key) do nothing;

insert into public.system_settings (key, value_numeric, description) values
    ('episode_min_seconds', 10, 'Shortest finished episode (sum of the cut lengths).'),
    ('episode_max_seconds', 18, 'Longest finished episode (sum of the cut lengths).'),
    ('min_shots', 5, 'Fewest shots in an episode.'),
    ('max_shots', 7, 'Most shots in an episode; every shot is one paid generation.'),
    ('min_shot_edit_seconds', 0.8, 'Shortest cut.'),
    ('max_shot_edit_seconds', 4.5, 'Longest cut.'),
    ('hook_max_seconds', 2.5, 'The first cut may not be longer than this.'),
    ('max_dialogue_lines', 6, 'Most spoken lines in an episode.'),
    ('edit_voice_lead_seconds', 0.15, 'A voice starts this long after its cut begins.'),
    ('edit_voice_tail_seconds', 0.35, 'A cut lasts at least this long after its voice ends.'),
    ('edit_trim_lead_seconds', 0.2, 'The edit skips this much at the start of every generated clip.'),
    ('script_vote_min_score', 7, 'A YES from the Assistant Director counts only when every score is at least this (1-10).'),
    ('max_script_rejections', 2, 'Times the Assistant Director may send a script back before the topic is dropped.'),
    ('film_video_prompt_min_chars', 200, 'Shortest shot description under the film rules.'),
    ('min_beat_chars', 15, 'Shortest description of one timed beat inside a shot.')
on conflict (key) do nothing;

insert into public.system_text_settings (key, value, description) values
    ('cast_rule_text', 'All the children are the same age and the same height, with the same child body proportions; nobody is taller or looks older than the others.', 'Sentence added to every shot with characters.')
on conflict (key) do nothing;
-- ---------------------------------------------------------------------
-- 4. Existing rules, adjusted
--
-- Production is authorised by the Head Director decision (step 14), not
-- by a human approval. Storyboards are required only while the
-- storyboard_required flag is true. Everything else in these functions
-- is unchanged from 001.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.require_manifest_authorized_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_episode_id uuid;
    v_episode_authorized boolean;
    v_episode_state text;
    v_episode_production_version integer;

    v_manifest_count integer;
BEGIN

    -- -----------------------------------------------------
    -- Only paid/reserved attempts require production gate.
    -- -----------------------------------------------------

    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- Load canonical shot -> episode state.
    -- -----------------------------------------------------

    SELECT
        s.episode_id,
        e.production_authorized,
        e.state,
        e.production_version

    INTO
        v_episode_id,
        v_episode_authorized,
        v_episode_state,
        v_episode_production_version

    FROM public.shots s

    JOIN public.episodes e
        ON e.id = s.episode_id

    WHERE s.id = NEW.shot_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'MANIFEST_GATE_SHOT_OR_EPISODE_NOT_FOUND';
    END IF;


    -- -----------------------------------------------------
    -- Episode production authorization.
    -- Defense in depth with DATA-81.
    -- -----------------------------------------------------

    IF COALESCE(v_episode_authorized, false) IS NOT TRUE THEN
        RAISE EXCEPTION
            'MANIFEST_GATE_PRODUCTION_NOT_AUTHORIZED';
    END IF;


    IF v_episode_state <> 'PRODUCTION' THEN
        RAISE EXCEPTION
            'MANIFEST_GATE_EPISODE_NOT_IN_PRODUCTION: %',
            v_episode_state;
    END IF;


    -- -----------------------------------------------------
    -- Find EXACTLY ONE canonical production path:
    --
    -- Episode
    --   -> LOCKED Manifest
    --      -> Manifest Shot
    --         -> LOCKED ACTIVE Specification
    --
    -- Specification version must equal prompt_version
    -- being used by this attempt.
    -- -----------------------------------------------------

    SELECT COUNT(*)
    INTO v_manifest_count

    FROM public.production_manifests pm

    JOIN public.production_manifest_shots pms
        ON pms.manifest_id = pm.id

    JOIN public.shot_specifications ss
        ON ss.id = pms.shot_specification_id

    WHERE pm.episode_id = v_episode_id

      AND pm.production_version =
          v_episode_production_version

      AND pm.status = 'LOCKED'

      AND (pm.human_approved = true OR pm.director_approval_id IS NOT NULL)

      AND pm.locked_at IS NOT NULL

      AND pms.shot_id = NEW.shot_id

      AND ss.shot_id = NEW.shot_id

      AND ss.status = 'LOCKED'

      AND ss.locked_at IS NOT NULL

      AND ss.is_active = true

      AND ss.version = NEW.prompt_version;


    IF v_manifest_count = 0 THEN
        RAISE EXCEPTION
            'SHOT_NOT_AUTHORIZED_BY_LOCKED_MANIFEST';
    END IF;


    IF v_manifest_count > 1 THEN
        RAISE EXCEPTION
            'AMBIGUOUS_LOCKED_MANIFEST_FOR_SHOT';
    END IF;


    RETURN NEW;

END;
$function$;

CREATE OR REPLACE FUNCTION public.require_paid_generation_readiness()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE
    v_spec_id uuid;
    v_series_id uuid;

    v_shot_state text;

    v_audio_required boolean;
    v_voice_required boolean;

    v_required_asset_codes jsonb;

    v_storyboard_count integer;
    v_storyboard_approved_count integer;

    v_required_asset_count integer;
    v_resolved_required_asset_count integer;
    v_bound_required_asset_count integer;

    v_canonical_audio_count integer;
    v_unbound_asset_code text;
    v_multi_bound_asset_code text;
    v_uncovered_audio_order integer;

BEGIN

    -- -----------------------------------------------------
    -- Only paid/reserved attempts require readiness gate.
    -- -----------------------------------------------------

    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- Resolve the EXACT locked production specification
    -- already authorized by manifest architecture.
    -- -----------------------------------------------------

    SELECT
        ss.id,
        e.series_id,
        s.state,
        ss.audio_required,
        ss.voice_required,
        ss.required_asset_codes

    INTO
        v_spec_id,
        v_series_id,
        v_shot_state,
        v_audio_required,
        v_voice_required,
        v_required_asset_codes

    FROM public.shots s

    JOIN public.episodes e
        ON e.id = s.episode_id

    JOIN public.production_manifests pm
        ON pm.episode_id = e.id
       AND pm.production_version = e.production_version
       AND pm.status = 'LOCKED'
       AND (pm.human_approved = true OR pm.director_approval_id IS NOT NULL)
       AND pm.locked_at IS NOT NULL

    JOIN public.production_manifest_shots pms
        ON pms.manifest_id = pm.id
       AND pms.shot_id = s.id

    JOIN public.shot_specifications ss
        ON ss.id = pms.shot_specification_id
       AND ss.shot_id = s.id
       AND ss.status = 'LOCKED'
       AND ss.locked_at IS NOT NULL
       AND ss.is_active = true
       AND ss.version = NEW.prompt_version

    WHERE s.id = NEW.shot_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'READINESS_LOCKED_PRODUCTION_SPEC_NOT_FOUND';
    END IF;


    -- -----------------------------------------------------
    -- Shot lifecycle readiness.
    --
    -- Initial generation:
    -- STORYBOARD_APPROVED / AUDIO_READY
    --
    -- Retry:
    -- RETRY_REQUIRED is converted to QUEUED by the
    -- acquisition workflow after authorization.
    --
    -- QUEUED is also accepted because acquire_generation_attempt
    -- may be operating inside the same orchestration path.
    -- -----------------------------------------------------

    IF v_shot_state NOT IN (
        'STORYBOARD_APPROVED',
        'AUDIO_READY',
        'RETRY_REQUIRED',
        'QUEUED'
    )
    THEN
        RAISE EXCEPTION
            'SHOT_NOT_GENERATION_READY: %',
            v_shot_state;
    END IF;


    -- -----------------------------------------------------
    -- STORYBOARD
    --
    -- Storyboard review is optional at schema level.
    -- But if a review record exists, it cannot be pending
    -- or rejected when paid generation begins.
    -- -----------------------------------------------------

    SELECT
        COUNT(*),
        COUNT(*) FILTER (
            WHERE sr.status = 'APPROVED'
              AND sr.reviewed_at IS NOT NULL
        )

    INTO
        v_storyboard_count,
        v_storyboard_approved_count

    FROM public.storyboard_reviews sr

    WHERE sr.shot_specification_id = v_spec_id;


    IF v_storyboard_count > 0
       AND v_storyboard_approved_count <> v_storyboard_count
    THEN
        RAISE EXCEPTION
            'STORYBOARD_REVIEW_NOT_APPROVED';
    END IF;


    -- -----------------------------------------------------
    -- REQUIRED ASSET CODES
    --
    -- required_asset_codes must:
    --
    -- 1. contain strings only
    -- 2. contain no blank codes
    -- 3. resolve to LOCKED asset_registry rows
    -- 4. belong to the episode series
    -- 5. be explicitly bound to this shot specification
    --
    -- DISTINCT prevents duplicate JSON codes from creating
    -- false counts.
    -- -----------------------------------------------------

    IF jsonb_typeof(
        COALESCE(v_required_asset_codes, '[]'::jsonb)
    ) <> 'array'
    THEN
        RAISE EXCEPTION
            'REQUIRED_ASSET_CODES_MUST_BE_ARRAY';
    END IF;


    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
            COALESCE(v_required_asset_codes, '[]'::jsonb)
        ) AS elem(value)
        WHERE jsonb_typeof(elem.value) <> 'string'
    )
    THEN
        RAISE EXCEPTION
            'REQUIRED_ASSET_CODES_MUST_CONTAIN_STRINGS_ONLY';
    END IF;


    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(
            COALESCE(v_required_asset_codes, '[]'::jsonb)
        ) AS req(asset_code)
        WHERE btrim(req.asset_code) = ''
    )
    THEN
        RAISE EXCEPTION
            'REQUIRED_ASSET_CODE_CANNOT_BE_BLANK';
    END IF;


    SELECT COUNT(DISTINCT req.asset_code)
    INTO v_required_asset_count

    FROM jsonb_array_elements_text(
        COALESCE(v_required_asset_codes, '[]'::jsonb)
    ) AS req(asset_code);


    IF v_required_asset_count > 0 THEN

        -- ---------------------------------------------
        -- Each required code must resolve to EXACTLY ONE
        -- LOCKED asset of this series THROUGH THIS
        -- SPECIFICATION'S OWN BINDINGS.
        --
        -- Several versions of a code may be LOCKED at the
        -- same time; each specification stays pinned to
        -- the version it was approved with.
        -- ---------------------------------------------
        SELECT
            min(x.asset_code) FILTER (WHERE x.bound_count = 0),
            min(x.asset_code) FILTER (WHERE x.bound_count > 1)
        INTO
            v_unbound_asset_code,
            v_multi_bound_asset_code
        FROM (
            SELECT
                required.asset_code,
                COUNT(DISTINCT bound.asset_id) AS bound_count
            FROM (
                SELECT DISTINCT req.asset_code
                FROM jsonb_array_elements_text(
                    COALESCE(
                        v_required_asset_codes,
                        '[]'::jsonb
                    )
                ) AS req(asset_code)
            ) required
            LEFT JOIN (
                SELECT
                    ar.id AS asset_id,
                    ar.asset_code
                FROM public.shot_reference_assets sra
                JOIN public.asset_registry ar
                    ON ar.id = sra.asset_id
                WHERE sra.shot_specification_id = v_spec_id
                  AND sra.is_required = true
                  AND ar.series_id = v_series_id
                  AND ar.status = 'LOCKED'
                  AND ar.locked_at IS NOT NULL
            ) bound
                ON bound.asset_code = required.asset_code
            GROUP BY required.asset_code
        ) x;

        IF v_unbound_asset_code IS NOT NULL THEN
            RAISE EXCEPTION
                'REQUIRED_ASSET_NOT_BOUND_TO_SHOT: %',
                v_unbound_asset_code;
        END IF;

        IF v_multi_bound_asset_code IS NOT NULL THEN
            RAISE EXCEPTION
                'REQUIRED_ASSET_BOUND_TO_MULTIPLE_VERSIONS: %',
                v_multi_bound_asset_code;
        END IF;

    END IF;


    -- -----------------------------------------------------
    -- AUDIO / VOICE READINESS
    -- -----------------------------------------------------

    IF COALESCE(v_audio_required, false) = true
       OR COALESCE(v_voice_required, false) = true
    THEN

        SELECT COUNT(*)

        INTO v_canonical_audio_count

        FROM public.shot_audio_productions sap

        JOIN public.voice_identities vi
            ON vi.id = sap.voice_identity_id
           AND vi.character_id = sap.character_id
           AND vi.status = 'LOCKED'
           AND vi.locked_at IS NOT NULL

        WHERE sap.shot_specification_id = v_spec_id

          AND sap.is_canonical = true

          AND sap.status = 'APPROVED'

          AND sap.qc_status = 'PASS'

          AND sap.reviewed_at IS NOT NULL

          AND sap.duration_seconds IS NOT NULL

          AND sap.duration_seconds > 0

          AND sap.storage_path IS NOT NULL
          AND btrim(sap.storage_path) <> ''

          AND (
                COALESCE(v_voice_required, false) = false

                OR

                (
                    -- READY = timing prepared before the video
                    -- exists. PASS = verified against a video.
                    sap.lip_sync_required = true
                    AND sap.lip_sync_status IN (
                        'READY',
                        'PASS'
                    )
                )

                OR

                (
                    sap.lip_sync_required = false
                    AND sap.lip_sync_status IN (
                        'NOT_REQUIRED',
                        'PASS'
                    )
                )
          );


        IF v_canonical_audio_count = 0 THEN

            IF COALESCE(v_voice_required, false) = true THEN
                RAISE EXCEPTION
                    'VOICE_REQUIRED_BUT_CANONICAL_AUDIO_NOT_READY';
            ELSE
                RAISE EXCEPTION
                    'AUDIO_REQUIRED_BUT_CANONICAL_AUDIO_NOT_READY';
            END IF;

        END IF;


        -- Every dialogue line that still has a live take must have
        -- a canonical take. Archive the takes of a dropped line.
        SELECT min(l.audio_order)
        INTO v_uncovered_audio_order
        FROM (
            SELECT sap.audio_order
            FROM public.shot_audio_productions sap
            WHERE sap.shot_specification_id = v_spec_id
              AND sap.status <> 'ARCHIVED'
            GROUP BY sap.audio_order
            HAVING COUNT(*) FILTER (
                WHERE sap.is_canonical = true
            ) = 0
        ) l;

        IF v_uncovered_audio_order IS NOT NULL THEN
            RAISE EXCEPTION
                'AUDIO_LINE_WITHOUT_CANONICAL_TAKE: %',
                v_uncovered_audio_order;
        END IF;

    END IF;


    RETURN NEW;

END;

$function$;

CREATE OR REPLACE FUNCTION public.require_production_pilot_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_episode_id uuid;
    v_production_version integer;

    v_manifest_id uuid;
    v_pilot_shot_id uuid;

    v_pilot_state text;
    v_pilot_locked_at timestamptz;

    v_pilot_pass_count integer;
BEGIN

    -- -----------------------------------------------------
    -- Only paid generation acquisition.
    -- -----------------------------------------------------

    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- Resolve episode.
    -- -----------------------------------------------------

    SELECT
        s.episode_id,
        e.production_version

    INTO
        v_episode_id,
        v_production_version

    FROM public.shots s

    JOIN public.episodes e
      ON e.id = s.episode_id

    WHERE s.id = NEW.shot_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'PILOT_GATE_SHOT_OR_EPISODE_NOT_FOUND';
    END IF;


    -- -----------------------------------------------------
    -- Resolve EXACT canonical locked manifest.
    -- -----------------------------------------------------

    SELECT
        pm.id,
        pm.pilot_shot_id

    INTO
        v_manifest_id,
        v_pilot_shot_id

    FROM public.production_manifests pm

    WHERE pm.episode_id = v_episode_id

      AND pm.production_version =
          v_production_version

      AND pm.status = 'LOCKED'

      AND (pm.human_approved = true OR pm.director_approval_id IS NOT NULL)

      AND pm.locked_at IS NOT NULL

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'PILOT_GATE_LOCKED_MANIFEST_NOT_FOUND';
    END IF;


    IF v_pilot_shot_id IS NULL THEN
        RAISE EXCEPTION
            'PILOT_GATE_PILOT_SHOT_NOT_CONFIGURED';
    END IF;


    -- -----------------------------------------------------
    -- Defense in depth:
    -- requested shot must itself belong to this manifest.
    -- -----------------------------------------------------

    IF NOT EXISTS (

        SELECT 1

        FROM public.production_manifest_shots pms

        WHERE pms.manifest_id = v_manifest_id
          AND pms.shot_id = NEW.shot_id

    )
    THEN

        RAISE EXCEPTION
            'PILOT_GATE_SHOT_NOT_IN_MANIFEST';

    END IF;


    -- -----------------------------------------------------
    -- Pilot itself may generate/retry before it passes.
    -- Existing max-2-attempt rules remain authoritative.
    -- -----------------------------------------------------

    IF NEW.shot_id = v_pilot_shot_id THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- Non-pilot shots are blocked until pilot is LOCKED.
    -- -----------------------------------------------------

    SELECT
        s.state,
        s.locked_at

    INTO
        v_pilot_state,
        v_pilot_locked_at

    FROM public.shots s

    WHERE s.id = v_pilot_shot_id

      AND s.episode_id = v_episode_id

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'PILOT_GATE_PILOT_SHOT_NOT_FOUND';
    END IF;


    IF v_pilot_state <> 'LOCKED'
       OR v_pilot_locked_at IS NULL
    THEN

        RAISE EXCEPTION
            'PILOT_SHOT_NOT_YET_LOCKED';

    END IF;


    -- -----------------------------------------------------
    -- Real QC evidence required.
    --
    -- generation_outputs is the canonical QC source:
    -- PASS + canonical + reviewed output.
    -- -----------------------------------------------------

    SELECT COUNT(*)

    INTO v_pilot_pass_count

    FROM public.generation_outputs go

    JOIN public.attempts a
      ON a.id = go.attempt_id
     AND a.shot_id = v_pilot_shot_id
     AND a.status = 'SUCCEEDED'

    WHERE go.shot_id = v_pilot_shot_id

      AND go.qc_status = 'PASS'

      AND go.is_canonical = true

      AND go.reviewed_at IS NOT NULL

      AND (
            (
                go.storage_path IS NOT NULL
                AND btrim(go.storage_path) <> ''
            )
            OR
            (
                go.source_url IS NOT NULL
                AND btrim(go.source_url) <> ''
            )
      );


    IF v_pilot_pass_count <> 1 THEN

        RAISE EXCEPTION
            'PILOT_SHOT_QC_PASS_REQUIRED';

    END IF;


    RETURN NEW;

END;
$function$;

CREATE OR REPLACE FUNCTION public.require_mandatory_storyboard_for_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_spec_id uuid;

    v_review_count integer;
    v_approved_count integer;
BEGIN

    -- -----------------------------------------------------
    -- Only paid/reserved generation.
    -- -----------------------------------------------------

    IF NEW.status <> 'BUDGET_RESERVED' THEN
        RETURN NEW;
    END IF;

    -- Storyboards are a switchable requirement. A missing flag
    -- means the requirement is on.
    IF COALESCE(
        (
            SELECT sf.value
            FROM public.system_flags sf
            WHERE sf.key = 'storyboard_required'
        ),
        true
    ) IS NOT TRUE
    THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- Resolve exact canonical spec through routing decision.
    -- -----------------------------------------------------

    IF NEW.routing_decision_id IS NULL THEN
        RAISE EXCEPTION
            'ROUTING_DECISION_REQUIRED';
    END IF;


    SELECT grd.shot_specification_id
    INTO v_spec_id

    FROM public.generation_routing_decisions grd

    WHERE grd.id = NEW.routing_decision_id
      AND grd.shot_id = NEW.shot_id
      AND grd.attempt_no = NEW.attempt_no
      AND grd.decision_status = 'SELECTED'
      AND grd.is_current = true

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'CURRENT_SELECTED_ROUTING_DECISION_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Exact storyboard review.
    --
    -- UNIQUE(spec) already exists, but explicit counts make
    -- the execution gate fail closed.
    -- -----------------------------------------------------

    SELECT
        COUNT(*),

        COUNT(*) FILTER (
            WHERE sr.status = 'APPROVED'
              AND sr.storyboard_asset_id IS NOT NULL
              AND sr.reviewed_at IS NOT NULL
              AND sr.reviewer_type IS NOT NULL
              AND btrim(sr.reviewer_type) <> ''
        )

    INTO
        v_review_count,
        v_approved_count

    FROM public.storyboard_reviews sr

    WHERE sr.shot_specification_id = v_spec_id;


    IF v_review_count <> 1 THEN
        RAISE EXCEPTION
            'EXACTLY_ONE_STORYBOARD_REVIEW_REQUIRED';
    END IF;


    IF v_approved_count <> 1 THEN
        RAISE EXCEPTION
            'STORYBOARD_APPROVAL_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Storyboard asset must STILL be LOCKED at acquisition.
    -- -----------------------------------------------------

    IF NOT EXISTS (

        SELECT 1

        FROM public.storyboard_reviews sr

        JOIN public.asset_registry ar
          ON ar.id = sr.storyboard_asset_id
         AND ar.status = 'LOCKED'
         AND ar.locked_at IS NOT NULL

        WHERE sr.shot_specification_id = v_spec_id
          AND sr.status = 'APPROVED'
          AND sr.reviewed_at IS NOT NULL
          AND sr.reviewer_type IS NOT NULL
          AND btrim(sr.reviewer_type) <> ''
    )
    THEN

        RAISE EXCEPTION
            'CANONICAL_STORYBOARD_ASSET_NOT_LOCKED';

    END IF;


    RETURN NEW;

END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_episode_state_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_open_shots integer;
    v_locked_shots integer;
begin

    -- ----------------------------------------------------
    -- human_approved may only become true through a
    -- recorded approval for this production version.
    -- ----------------------------------------------------
    if new.human_approved is true
       and old.human_approved is not true
    then

        if not exists (
            select 1
            from public.approval_requests ar
            where ar.scope_type = 'EPISODE_PRODUCTION'
              and ar.scope_id = new.id
              and ar.scope_version = new.production_version
              and ar.status = 'APPROVED'
        ) then
            raise exception
                'EPISODE_HUMAN_APPROVAL_RECORD_REQUIRED';
        end if;

    end if;


    -- ----------------------------------------------------
    -- director_approval_id may only point at an APPROVE
    -- decision made for this episode and production version.
    -- ----------------------------------------------------
    if new.director_approval_id is distinct from old.director_approval_id then
        if new.director_approval_id is null
           or not exists (
               select 1
               from public.director_decisions dd
               where dd.id = new.director_approval_id
                 and dd.episode_id = new.id
                 and dd.production_version = new.production_version
                 and dd.stage = 'PRODUCTION'
                 and dd.decision = 'APPROVE'
           )
        then
            raise exception 'EPISODE_DIRECTOR_APPROVAL_INVALID';
        end if;
    end if;

    if new.state = old.state then
        return new;
    end if;


    if old.state in ('PUBLISHED', 'CANCELLED') then
        raise exception
            'EPISODE_STATE_IS_TERMINAL: %',
            old.state;
    end if;


    -- ----------------------------------------------------
    -- BLOCKED remembers where it came from and can only
    -- return there (or be cancelled).
    -- ----------------------------------------------------
    if new.state = 'BLOCKED' then
        new.blocked_from_state := old.state;
        return new;
    end if;

    if old.state = 'BLOCKED' then

        if new.state = 'CANCELLED' then
            new.blocked_from_state := null;
            return new;
        end if;

        -- Blocked before this migration: the origin is unknown, so
        -- the only way forward is back through approval.
        if old.blocked_from_state is null then

            if new.state <> 'PREPRODUCTION' then
                raise exception
                    'BLOCKED_EPISODE_MUST_RETURN_TO: PREPRODUCTION';
            end if;

            return new;

        end if;

        if new.state <> old.blocked_from_state then
            raise exception
                'BLOCKED_EPISODE_MUST_RETURN_TO: %',
                old.blocked_from_state;
        end if;

        new.blocked_from_state := null;
        return new;

    end if;


    if new.state = 'CANCELLED' then
        return new;
    end if;


    if not (

        (old.state = 'PLANNED'
            and new.state = 'PREPRODUCTION')

        or

        (old.state = 'PREPRODUCTION'
            and new.state in ('APPROVED', 'PLANNED'))

        or

        (old.state = 'APPROVED'
            and new.state in ('PRODUCTION', 'PREPRODUCTION'))

        or

        (old.state = 'PRODUCTION'
            and new.state = 'ASSEMBLY')

        or

        (old.state = 'ASSEMBLY'
            and new.state in ('FINAL_QC', 'PRODUCTION'))

        or

        (old.state = 'FINAL_QC'
            and new.state in ('READY_TO_PUBLISH', 'ASSEMBLY'))

        or

        (old.state = 'READY_TO_PUBLISH'
            and new.state in ('PUBLISHED', 'FINAL_QC'))

    ) then

        raise exception
            'INVALID_EPISODE_STATE_TRANSITION: % -> %',
            old.state,
            new.state;

    end if;


    if new.state = 'APPROVED'
       and new.human_approved is not true
       and new.director_approval_id is null
    then
        raise exception 'EPISODE_PRODUCTION_APPROVAL_REQUIRED';
    end if;


    if new.state = 'PRODUCTION'
       and old.state = 'APPROVED'
       and new.production_authorized is not true
    then
        raise exception 'EPISODE_PRODUCTION_AUTHORIZATION_REQUIRED';
    end if;


    -- ----------------------------------------------------
    -- Assembly needs every shot of the current locked
    -- manifest to be finished: LOCKED or CANCELLED.
    -- ----------------------------------------------------
    if new.state = 'ASSEMBLY'
       and old.state = 'PRODUCTION'
    then

        select
            count(*) filter (
                where s.state not in ('LOCKED', 'CANCELLED')
            ),
            count(*) filter (
                where s.state = 'LOCKED'
            )
        into
            v_open_shots,
            v_locked_shots
        from public.production_manifests pm
        join public.production_manifest_shots pms
          on pms.manifest_id = pm.id
        join public.shots s
          on s.id = pms.shot_id
        where pm.episode_id = new.id
          and pm.production_version = new.production_version
          and pm.status = 'LOCKED';

        if coalesce(v_locked_shots, 0) = 0 then
            raise exception 'ASSEMBLY_REQUIRES_LOCKED_SHOTS';
        end if;

        if v_open_shots > 0 then
            raise exception
                'ASSEMBLY_BLOCKED_BY_OPEN_SHOTS: %',
                v_open_shots;
        end if;

    end if;


    -- ----------------------------------------------------
    -- Publishing needs a recorded human approval for this
    -- production version.
    -- ----------------------------------------------------
    if new.state = 'PUBLISHED' then

        if not exists (
            select 1
            from public.approval_requests ar
            where ar.scope_type = 'EPISODE_PUBLISH'
              and ar.scope_id = new.id
              and ar.scope_version = new.production_version
              and ar.status = 'APPROVED'
        ) then
            raise exception 'PUBLISH_HUMAN_APPROVAL_REQUIRED';
        end if;

    end if;


    return new;

end;
$function$;

CREATE OR REPLACE FUNCTION public.request_human_approval(p_scope_type text, p_scope_id uuid, p_requested_by text, p_summary jsonb DEFAULT '{}'::jsonb, p_ttl_hours integer DEFAULT 72)
 RETURNS TABLE(request_id uuid, token text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_token text;
    v_request_id uuid;
    v_expires_at timestamptz;
    v_scope_version integer;
    v_state text;
begin

    if p_scope_type not in (
        'EPISODE_PRODUCTION',
        'EPISODE_PUBLISH',
        'SHOT_ESCALATION'
    ) then
        raise exception 'INVALID_APPROVAL_SCOPE';
    end if;

    -- Production is authorised by the Head Director decision.
    if p_scope_type = 'EPISODE_PRODUCTION' then
        raise exception 'EPISODE_PRODUCTION_APPROVAL_RETIRED';
    end if;
    if p_scope_id is null then
        raise exception 'APPROVAL_SCOPE_ID_REQUIRED';
    end if;

    if p_requested_by is null or btrim(p_requested_by) = '' then
        raise exception 'APPROVAL_REQUESTER_REQUIRED';
    end if;

    if p_ttl_hours is null
       or p_ttl_hours < 1
       or p_ttl_hours > 720
    then
        raise exception 'INVALID_APPROVAL_TTL';
    end if;


    if p_scope_type in ('EPISODE_PRODUCTION', 'EPISODE_PUBLISH') then

        select e.production_version, e.state
        into v_scope_version, v_state
        from public.episodes e
        where e.id = p_scope_id;

        if not found then
            raise exception 'EPISODE_NOT_FOUND';
        end if;

        if p_scope_type = 'EPISODE_PRODUCTION'
           and v_state <> 'PREPRODUCTION'
        then
            raise exception
                'EPISODE_NOT_AWAITING_PRODUCTION_APPROVAL: %',
                v_state;
        end if;

        if p_scope_type = 'EPISODE_PUBLISH'
           and v_state <> 'READY_TO_PUBLISH'
        then
            raise exception
                'EPISODE_NOT_AWAITING_PUBLISH_APPROVAL: %',
                v_state;
        end if;

    else

        select s.state
        into v_state
        from public.shots s
        where s.id = p_scope_id;

        if not found then
            raise exception 'SHOT_NOT_FOUND';
        end if;

        if v_state <> 'ESCALATED' then
            raise exception
                'SHOT_NOT_ESCALATED: %',
                v_state;
        end if;

    end if;


    -- A new request replaces a pending one for the same subject.
    update public.approval_requests ar
    set status = 'SUPERSEDED'
    where ar.scope_type = p_scope_type
      and ar.scope_id = p_scope_id
      and ar.status = 'PENDING';


    v_token :=
        replace(gen_random_uuid()::text, '-', '')
        || replace(gen_random_uuid()::text, '-', '');

    v_expires_at :=
        now() + make_interval(hours => p_ttl_hours);


    insert into public.approval_requests (
        scope_type,
        scope_id,
        scope_version,
        token_hash,
        requested_by,
        summary,
        expires_at
    )
    values (
        p_scope_type,
        p_scope_id,
        v_scope_version,
        encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
        p_requested_by,
        coalesce(p_summary, '{}'::jsonb),
        v_expires_at
    )
    returning id
    into v_request_id;


    return query
    select v_request_id, v_token, v_expires_at;

end;
$function$;

CREATE OR REPLACE FUNCTION public.create_generation_routing_decision(p_shot_specification_id uuid, p_policy_id uuid, p_attempt_no integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE

    v_shot_id uuid;

    v_policy_status text;
    v_policy_approved_at timestamptz;

    v_min_quality numeric;
    v_min_pass_rate numeric;

    v_quality_weight numeric;
    v_cost_weight numeric;
    v_reliability_weight numeric;
    v_latency_weight numeric;

    v_max_attempts integer;
    v_fallback_second boolean;

    v_require_verified_pricing boolean;
    v_require_available_health boolean;

    v_existing_decision_id uuid;
    v_existing_status text;
    v_existing_revision integer;

    v_next_revision integer := 1;

    v_candidate_count integer := 0;
    v_technical_candidate_count integer := 0;
    v_benchmark_candidate_count integer := 0;

    v_selected_model_id uuid;
    v_selected_pricing_id uuid;
    v_selected_role text;
    v_selected_cost numeric;

    v_lowest_cost numeric;
    v_fastest_latency numeric;

    v_decision_id uuid;

    v_failure_status text;
    v_failure_reason text;

    v_candidate_scores jsonb := '[]'::jsonb;

BEGIN


    -- =====================================================
    -- 1. INPUT
    -- =====================================================

    IF p_attempt_no NOT BETWEEN 1 AND 2 THEN
        RAISE EXCEPTION
            'INVALID_ROUTING_ATTEMPT_NO';
    END IF;


    -- =====================================================
    -- 2. SPECIFICATION
    -- =====================================================

    SELECT ss.shot_id
    INTO v_shot_id

    FROM public.shot_specifications ss

    WHERE ss.id = p_shot_specification_id
      AND ss.status = 'LOCKED'
      AND ss.locked_at IS NOT NULL
      AND ss.is_active = true

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_REQUIRES_LOCKED_ACTIVE_SPECIFICATION';
    END IF;


    -- =====================================================
    -- 3. CURRENT DECISION
    --
    -- Lock the current routing record so concurrent router
    -- calls cannot both supersede it.
    -- =====================================================

    SELECT
        grd.id,
        grd.decision_status,
        grd.decision_revision

    INTO
        v_existing_decision_id,
        v_existing_status,
        v_existing_revision

    FROM public.generation_routing_decisions grd

    WHERE grd.shot_id = v_shot_id
      AND grd.attempt_no = p_attempt_no
      AND grd.is_current = true

    FOR UPDATE;


    IF FOUND THEN

        -- -------------------------------------------------
        -- SELECTED decisions remain deterministic.
        -- Runtime health/pricing/provider checks are handled
        -- again by acquisition gates.
        -- -------------------------------------------------

        IF v_existing_status = 'SELECTED' THEN
            RETURN v_existing_decision_id;
        END IF;


        -- -------------------------------------------------
        -- Only transient blocked outcomes may be re-evaluated.
        -- -------------------------------------------------

        IF v_existing_status NOT IN (
            'NO_ELIGIBLE_MODEL',
            'BUDGET_BLOCKED',
            'HEALTH_BLOCKED',
            'PRICING_BLOCKED'
        )
        THEN
            RAISE EXCEPTION
                'ROUTING_DECISION_NOT_REEVALUATABLE: %',
                v_existing_status;
        END IF;


        -- No attempt may already consume the blocked decision.

        IF EXISTS (
            SELECT 1
            FROM public.attempts a
            WHERE a.routing_decision_id =
                  v_existing_decision_id
        )
        THEN
            RAISE EXCEPTION
                'ROUTING_DECISION_ALREADY_USED_BY_ATTEMPT';
        END IF;


        v_next_revision :=
            v_existing_revision + 1;


        -- Controlled CURRENT -> HISTORICAL transition.

        PERFORM set_config(
            'm417.routing_supersession',
            'on',
            true
        );


        UPDATE public.generation_routing_decisions
        SET is_current = false
        WHERE id = v_existing_decision_id
          AND is_current = true;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'ROUTING_DECISION_SUPERSESSION_FAILED';
        END IF;


        PERFORM set_config(
            'm417.routing_supersession',
            'off',
            true
        );

    END IF;


    -- A decision retired outside this function (specification
    -- supersession) leaves no current row. Continue its numbering
    -- instead of colliding with revision 1.
    IF v_existing_decision_id IS NULL THEN

        SELECT COALESCE(MAX(grd.decision_revision), 0) + 1
        INTO v_next_revision
        FROM public.generation_routing_decisions grd
        WHERE grd.shot_id = v_shot_id
          AND grd.attempt_no = p_attempt_no;

    END IF;


    -- =====================================================
    -- 4. POLICY
    -- =====================================================

    SELECT
        grp.status,
        grp.approved_at,

        grp.minimum_quality_score,
        grp.minimum_pass_rate,

        grp.quality_weight,
        grp.cost_weight,
        grp.reliability_weight,
        grp.latency_weight,

        grp.max_attempts,
        grp.fallback_on_second_attempt,

        grp.require_verified_pricing,
        grp.require_available_health

    INTO
        v_policy_status,
        v_policy_approved_at,

        v_min_quality,
        v_min_pass_rate,

        v_quality_weight,
        v_cost_weight,
        v_reliability_weight,
        v_latency_weight,

        v_max_attempts,
        v_fallback_second,

        v_require_verified_pricing,
        v_require_available_health

    FROM public.generation_routing_policies grp

    WHERE grp.id = p_policy_id

    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_NOT_FOUND';
    END IF;


    IF v_policy_status <> 'ACTIVE'
       OR v_policy_approved_at IS NULL
    THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_NOT_ACTIVE';
    END IF;


    IF p_attempt_no > v_max_attempts THEN
        RAISE EXCEPTION
            'ROUTING_POLICY_ATTEMPT_LIMIT_EXCEEDED';
    END IF;


    -- =====================================================
    -- 5. TEMP CANDIDATES
    -- =====================================================

    CREATE TEMP TABLE IF NOT EXISTS
    pg_temp.m417_routing_candidates
    (
        model_id uuid,
        pricing_id uuid,

        route_role text,
        route_priority integer,

        estimated_cost numeric,

        quality_score numeric,
        pass_rate numeric,
        latency_seconds numeric,

        routing_score numeric,

        technically_eligible boolean,
        pricing_compatible boolean,
        health_compatible boolean,
        benchmark_eligible boolean,
        policy_eligible boolean,

        rejection_reasons jsonb
    )
    ON COMMIT DROP;


    TRUNCATE TABLE
        pg_temp.m417_routing_candidates;


    -- =====================================================
    -- 6. LOAD CANDIDATES
    -- =====================================================

    INSERT INTO pg_temp.m417_routing_candidates (

        model_id,
        pricing_id,

        route_role,
        route_priority,

        estimated_cost,

        quality_score,
        pass_rate,
        latency_seconds,

        technically_eligible,
        pricing_compatible,
        health_compatible,
        benchmark_eligible,
        policy_eligible,

        rejection_reasons
    )

    SELECT

        gpm.model_id,
        ec.pricing_id,

        gpm.route_role,
        gpm.route_priority,

        ec.estimated_cost,

        public.calculate_benchmark_quality_score(
            b.continuity_score,
            b.motion_score,
            b.face_score,
            b.anatomy_score,
            b.prompt_adherence_score,
            b.camera_score,
            b.expression_score,
            b.lip_sync_score
        ),

        b.pass_rate,
        b.average_generation_seconds,

        ec.technically_eligible,
        ec.pricing_compatible,
        ec.health_compatible,

        (
            b.id IS NOT NULL
            AND b.benchmark_status = 'HUMAN_APPROVED'
            AND b.approved_at IS NOT NULL
        ),

        (
            ec.technically_eligible = true

            AND b.id IS NOT NULL

            AND b.benchmark_status =
                'HUMAN_APPROVED'

            AND b.approved_at IS NOT NULL

            AND public.calculate_benchmark_quality_score(
                b.continuity_score,
                b.motion_score,
                b.face_score,
                b.anatomy_score,
                b.prompt_adherence_score,
                b.camera_score,
                b.expression_score,
                b.lip_sync_score
            ) >= v_min_quality

            AND b.pass_rate >=
                v_min_pass_rate

            AND (
                gpm.minimum_quality_override IS NULL

                OR

                public.calculate_benchmark_quality_score(
                    b.continuity_score,
                    b.motion_score,
                    b.face_score,
                    b.anatomy_score,
                    b.prompt_adherence_score,
                    b.camera_score,
                    b.expression_score,
                    b.lip_sync_score
                ) >=
                    gpm.minimum_quality_override
            )

            AND (
                gpm.maximum_estimated_cost IS NULL
                OR ec.estimated_cost <=
                    gpm.maximum_estimated_cost
            )

            AND (
                v_require_verified_pricing = false
                OR ec.pricing_compatible = true
            )

            AND (
                v_require_available_health = false
                OR ec.health_compatible = true
            )
        ),

        (
            ec.rejection_reasons

            ||

            CASE
                WHEN b.id IS NULL
                THEN
                    '["APPROVED_BENCHMARK_MISSING"]'::jsonb
                ELSE
                    '[]'::jsonb
            END

            ||

            CASE
                WHEN b.id IS NOT NULL
                 AND b.pass_rate < v_min_pass_rate
                THEN
                    '["PASS_RATE_BELOW_POLICY_MINIMUM"]'::jsonb
                ELSE
                    '[]'::jsonb
            END

            ||

            CASE
                WHEN b.id IS NOT NULL
                 AND (
                        b.continuity_score IS NULL
                     OR b.motion_score IS NULL
                     OR b.face_score IS NULL
                     OR b.anatomy_score IS NULL
                     OR b.prompt_adherence_score IS NULL
                     OR b.camera_score IS NULL
                     OR b.expression_score IS NULL
                     OR b.lip_sync_score IS NULL
                     OR b.pass_rate IS NULL
                     OR b.average_generation_seconds IS NULL
                 )
                THEN
                    '["APPROVED_BENCHMARK_INCOMPLETE"]'::jsonb
                ELSE
                    '[]'::jsonb
            END
        )

    FROM public.generation_policy_models gpm


    JOIN LATERAL (

        SELECT *

        FROM public.evaluate_generation_candidates(
            p_shot_specification_id
        ) ecx

        WHERE ecx.model_id = gpm.model_id

        LIMIT 1

    ) ec ON true


    LEFT JOIN LATERAL (

        -- A paid, human-approved benchmark comes first. Without one,
        -- an owner pilot approval stands in for it: the first shot of
        -- the first episode is then the model's trial (pilot gate, QC
        -- and the two-attempt limit still apply).
        SELECT ev.*

        FROM (

            SELECT
                b1.id,
                b1.benchmark_status,
                b1.approved_at,
                b1.continuity_score,
                b1.motion_score,
                b1.face_score,
                b1.anatomy_score,
                b1.prompt_adherence_score,
                b1.camera_score,
                b1.expression_score,
                b1.lip_sync_score,
                b1.pass_rate,
                b1.average_generation_seconds,
                0 AS evidence_rank,
                b1.benchmark_version AS evidence_version

            FROM public.generation_model_benchmarks b1

            WHERE b1.model_id = gpm.model_id
              AND b1.benchmark_status = 'HUMAN_APPROVED'
              AND b1.approved_at IS NOT NULL

            UNION ALL

            SELECT
                pa.id,
                'HUMAN_APPROVED'::text,
                pa.approved_at,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_quality_score,
                pa.assumed_pass_rate,
                pa.assumed_generation_seconds,
                1 AS evidence_rank,
                0 AS evidence_version

            FROM public.generation_model_pilot_approvals pa

            WHERE pa.model_id = gpm.model_id
              AND pa.revoked_at IS NULL

        ) ev

        ORDER BY
            ev.evidence_rank,
            ev.evidence_version DESC

        LIMIT 1

    ) b ON true


    WHERE gpm.policy_id = p_policy_id
      AND gpm.enabled = true;


    -- =====================================================
    -- 7. ATTEMPT ROUTE
    -- =====================================================

    IF p_attempt_no = 1 THEN

        DELETE FROM pg_temp.m417_routing_candidates
        WHERE route_role <> 'PRIMARY';


    ELSIF p_attempt_no = 2
       AND v_fallback_second = true
    THEN

        DELETE FROM pg_temp.m417_routing_candidates
        WHERE route_role NOT IN (
            'FALLBACK',
            'EMERGENCY'
        );

    END IF;


    SELECT COUNT(*)
    INTO v_candidate_count

    FROM pg_temp.m417_routing_candidates;


    -- =====================================================
    -- 8. NO ROUTE
    -- =====================================================

    IF v_candidate_count = 0 THEN

        INSERT INTO public.generation_routing_decisions (

            shot_id,
            shot_specification_id,
            policy_id,
            attempt_no,

            decision_revision,
            is_current,

            decision_status,
            decision_reason,
            candidate_scores
        )

        VALUES (

            v_shot_id,
            p_shot_specification_id,
            p_policy_id,
            p_attempt_no,

            v_next_revision,
            true,

            'NO_ELIGIBLE_MODEL',

            CASE
                WHEN p_attempt_no = 2
                 AND v_fallback_second = true
                THEN
                    'NO_ENABLED_FALLBACK_OR_EMERGENCY_MODEL'
                ELSE
                    'NO_ENABLED_POLICY_MODEL'
            END,

            '[]'::jsonb
        )

        RETURNING id
        INTO v_decision_id;


        RETURN v_decision_id;

    END IF;


    -- =====================================================
    -- 9. COUNTS
    -- =====================================================

    SELECT COUNT(*)
    INTO v_technical_candidate_count

    FROM pg_temp.m417_routing_candidates

    WHERE technically_eligible = true;


    SELECT COUNT(*)
    INTO v_benchmark_candidate_count

    FROM pg_temp.m417_routing_candidates

    WHERE benchmark_eligible = true;


    -- =====================================================
    -- 10. NORMALIZATION BASELINES
    -- =====================================================

    SELECT
        MIN(estimated_cost),
        MIN(latency_seconds)

    INTO
        v_lowest_cost,
        v_fastest_latency

    FROM pg_temp.m417_routing_candidates

    WHERE policy_eligible = true;


    -- =====================================================
    -- 11. SCORE
    -- =====================================================

    UPDATE pg_temp.m417_routing_candidates c

    SET routing_score =

        public.calculate_generation_routing_score(

            c.quality_score,
            c.estimated_cost,
            v_lowest_cost,
            c.pass_rate,
            c.latency_seconds,
            v_fastest_latency,

            v_quality_weight,
            v_cost_weight,
            v_reliability_weight,
            v_latency_weight
        )

    WHERE c.policy_eligible = true;


    -- =====================================================
    -- 12. AUDIT SNAPSHOT
    -- =====================================================

    SELECT COALESCE(

        jsonb_agg(

            jsonb_build_object(

                'model_id', c.model_id,
                'pricing_id', c.pricing_id,
                'route_role', c.route_role,
                'route_priority', c.route_priority,
                'estimated_cost', c.estimated_cost,
                'quality_score', c.quality_score,
                'pass_rate', c.pass_rate,
                'latency_seconds', c.latency_seconds,
                'routing_score', c.routing_score,
                'technically_eligible',
                    c.technically_eligible,
                'pricing_compatible',
                    c.pricing_compatible,
                'health_compatible',
                    c.health_compatible,
                'benchmark_eligible',
                    c.benchmark_eligible,
                'policy_eligible',
                    c.policy_eligible,
                'rejection_reasons',
                    c.rejection_reasons
            )

            ORDER BY
                c.routing_score DESC NULLS LAST,
                c.route_priority ASC,
                c.estimated_cost ASC NULLS LAST,
                c.model_id
        ),

        '[]'::jsonb
    )

    INTO v_candidate_scores

    FROM pg_temp.m417_routing_candidates c;


    -- =====================================================
    -- 13. WINNER
    -- =====================================================

    SELECT
        c.model_id,
        c.pricing_id,
        c.route_role,
        c.estimated_cost

    INTO
        v_selected_model_id,
        v_selected_pricing_id,
        v_selected_role,
        v_selected_cost

    FROM pg_temp.m417_routing_candidates c

    WHERE c.policy_eligible = true
      AND c.routing_score IS NOT NULL

    ORDER BY
        c.routing_score DESC,
        c.route_priority ASC,
        c.estimated_cost ASC,
        c.model_id

    LIMIT 1;


    -- =====================================================
    -- 14. SELECTED
    -- =====================================================

    IF v_selected_model_id IS NOT NULL THEN

        INSERT INTO public.generation_routing_decisions (

            shot_id,
            shot_specification_id,
            policy_id,
            attempt_no,

            decision_revision,
            is_current,

            selected_model_id,
            selected_pricing_id,
            route_role,
            estimated_cost,

            decision_status,
            decision_reason,
            candidate_scores
        )

        VALUES (

            v_shot_id,
            p_shot_specification_id,
            p_policy_id,
            p_attempt_no,

            v_next_revision,
            true,

            v_selected_model_id,
            v_selected_pricing_id,
            v_selected_role,
            v_selected_cost,

            'SELECTED',
            'DETERMINISTIC_ROUTER_SELECTION',
            v_candidate_scores
        )

        RETURNING id
        INTO v_decision_id;


        RETURN v_decision_id;

    END IF;


    -- =====================================================
    -- 15. FAILURE CLASSIFICATION
    -- =====================================================

    IF v_technical_candidate_count = 0 THEN

        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'NO_TECHNICALLY_ELIGIBLE_MODEL';


    ELSIF v_benchmark_candidate_count = 0 THEN

        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'NO_HUMAN_APPROVED_BENCHMARK';


    ELSIF v_require_available_health = true
       AND NOT EXISTS (

            SELECT 1

            FROM pg_temp.m417_routing_candidates c

            WHERE c.technically_eligible = true
              AND c.benchmark_eligible = true
              AND c.health_compatible = true
       )
    THEN

        v_failure_status :=
            'HEALTH_BLOCKED';

        v_failure_reason :=
            'NO_AVAILABLE_HEALTHY_MODEL';


    ELSIF v_require_verified_pricing = true
       AND NOT EXISTS (

            SELECT 1

            FROM pg_temp.m417_routing_candidates c

            WHERE c.technically_eligible = true
              AND c.benchmark_eligible = true
              AND c.pricing_compatible = true
       )
    THEN

        v_failure_status :=
            'PRICING_BLOCKED';

        v_failure_reason :=
            'VERIFIED_PRICING_REQUIRED';


    ELSIF NOT EXISTS (
            SELECT 1
            FROM pg_temp.m417_routing_candidates c
            WHERE c.technically_eligible = true
              AND c.benchmark_eligible = true
              AND c.quality_score IS NOT NULL
              AND c.pass_rate IS NOT NULL
              AND c.latency_seconds IS NOT NULL
       )
    THEN

        -- Every approved benchmark is missing a score, a pass
        -- rate or a generation time. That is a data gap, not a
        -- quality verdict.
        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'APPROVED_BENCHMARK_INCOMPLETE';

    ELSE

        v_failure_status :=
            'NO_ELIGIBLE_MODEL';

        v_failure_reason :=
            'POLICY_THRESHOLDS_NOT_MET';

    END IF;


    -- =====================================================
    -- 16. BLOCKED DECISION
    -- =====================================================

    INSERT INTO public.generation_routing_decisions (

        shot_id,
        shot_specification_id,
        policy_id,
        attempt_no,

        decision_revision,
        is_current,

        decision_status,
        decision_reason,
        candidate_scores
    )

    VALUES (

        v_shot_id,
        p_shot_specification_id,
        p_policy_id,
        p_attempt_no,

        v_next_revision,
        true,

        v_failure_status,
        v_failure_reason,
        v_candidate_scores
    )

    RETURNING id
    INTO v_decision_id;


    RETURN v_decision_id;

END;
$function$;

CREATE OR REPLACE FUNCTION public.authorize_episode_production(p_episode_id uuid)
 RETURNS TABLE(episode_id uuid, production_authorized boolean, authorized_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_state text;
    v_human_approved boolean;
    v_director_approval_id uuid;
    v_authorized_at timestamptz;
begin
    select
        e.state,
        e.human_approved,
        e.director_approval_id
    into
        v_state,
        v_human_approved,
        v_director_approval_id
    from public.episodes e
    where e.id = p_episode_id
    for update;
    if not found then
        raise exception 'EPISODE_NOT_FOUND';
    end if;
    if v_human_approved is not true
       and v_director_approval_id is null
    then
        raise exception 'PRODUCTION_APPROVAL_REQUIRED';
    end if;
    if v_state <> 'APPROVED' then
        raise exception 'EPISODE_NOT_APPROVED';
    end if;
    v_authorized_at := now();
    update public.episodes
    set
        production_authorized = true,
        authorized_at = v_authorized_at,
        state = 'PRODUCTION'
    where id = p_episode_id;
    insert into public.events (
        event_type,
        episode_id,
        severity,
        source,
        message
    )
    values (
        'PRODUCTION_AUTHORIZED',
        p_episode_id,
        'INFO',
        'CONTROL_PLANE',
        'Episode production authorized'
    );
    return query
    select
        p_episode_id,
        true,
        v_authorized_at;
end;
$function$;

-- A specification may be locked from HUMAN_APPROVED (as before) or,
-- inside commit_production_package, straight from DRAFT on the
-- strength of the director decision (m417.director_lock marker).
CREATE OR REPLACE FUNCTION public.protect_shot_specification()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_supersession boolean;
    v_director_lock boolean;
begin
    v_supersession :=
        coalesce(
            current_setting('m417.spec_supersession', true),
            'off'
        ) = 'on';
    v_director_lock :=
        coalesce(
            current_setting('m417.director_lock', true),
            'off'
        ) = 'on';
    if old.status = 'LOCKED' then
        if v_supersession then
            -- Retire the old active specification.
            if new.status = 'SUPERSEDED'
               and old.is_active = true
               and new.is_active = false
               and (to_jsonb(new) - 'status' - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'status' - 'is_active' - 'updated_at')
            then
                return new;
            end if;
            -- Activate the new locked specification.
            if new.status = 'LOCKED'
               and old.is_active = false
               and new.is_active = true
               and (to_jsonb(new) - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'is_active' - 'updated_at')
            then
                return new;
            end if;
        end if;
        raise exception
            'LOCKED_SHOT_SPECIFICATION_IS_IMMUTABLE';
    end if;
    if new.status = 'LOCKED'
       and old.status <> 'HUMAN_APPROVED'
       and not (v_director_lock and old.status = 'DRAFT')
    then
        raise exception
            'SHOT_SPEC_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    end if;
    if new.status = 'LOCKED'
       and new.locked_at is null
    then
        new.locked_at := now();
    end if;
    return new;
end;
$function$;

-- A manifest may be locked by human approval (as before) or by the
-- director decision it is bound to.
CREATE OR REPLACE FUNCTION public.protect_production_manifest()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_director_lock boolean;
BEGIN
    IF OLD.status = 'LOCKED' THEN
        RAISE EXCEPTION
            'LOCKED_PRODUCTION_MANIFEST_IS_IMMUTABLE';
    END IF;
    v_director_lock :=
        COALESCE(
            current_setting('m417.director_lock', true),
            'off'
        ) = 'on'
        AND OLD.status = 'DRAFT'
        AND NEW.director_approval_id IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM public.director_decisions dd
            WHERE dd.id = NEW.director_approval_id
              AND dd.episode_id = NEW.episode_id
              AND dd.production_version = NEW.production_version
              AND dd.stage = 'PRODUCTION'
              AND dd.decision = 'APPROVE'
        );
    IF NEW.director_approval_id IS DISTINCT FROM OLD.director_approval_id
       AND v_director_lock IS NOT TRUE
       AND NEW.status <> 'DRAFT'
    THEN
        RAISE EXCEPTION
            'MANIFEST_DIRECTOR_APPROVAL_INVALID';
    END IF;
    IF NEW.status = 'LOCKED'
       AND OLD.status <> 'HUMAN_APPROVED'
       AND v_director_lock IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'MANIFEST_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    END IF;
    IF NEW.status = 'LOCKED'
       AND NEW.human_approved IS NOT TRUE
       AND v_director_lock IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'MANIFEST_HUMAN_APPROVAL_REQUIRED';
    END IF;
    IF NEW.status = 'LOCKED'
       AND NEW.locked_at IS NULL
    THEN
        NEW.locked_at := now();
    END IF;
    RETURN NEW;
END;
$function$;

-- Decisions are a record: never edited, never deleted.
create or replace function m417_internal.append_only()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
begin
    raise exception '%_IS_APPEND_ONLY', upper(tg_table_name);
end;
$function$;

drop trigger if exists trg_director_decisions_append_only on public.director_decisions;
create trigger trg_director_decisions_append_only
    before update or delete on public.director_decisions
    for each row execute function m417_internal.append_only();

drop trigger if exists trg_policy_checks_append_only on public.policy_checks;
create trigger trg_policy_checks_append_only
    before update or delete on public.policy_checks
    for each row execute function m417_internal.append_only();

drop trigger if exists trg_job_step_log_append_only on public.job_step_log;
create trigger trg_job_step_log_append_only
    before update or delete on public.job_step_log
    for each row execute function m417_internal.append_only();

-- ---------------------------------------------------------------------
-- 5. Internal helpers (schema m417_internal is not exposed by the API)
-- ---------------------------------------------------------------------
create or replace function m417_internal.flag(p_key text, p_default boolean)
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        (select sf.value from public.system_flags sf where sf.key = p_key),
        p_default);
$function$;

create or replace function m417_internal.num(p_key text, p_default numeric)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        (select st.value_numeric from public.system_settings st where st.key = p_key),
        p_default);
$function$;

create or replace function m417_internal.txt(p_key text, p_default text default '')
 returns text language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        nullif(btrim((select ts.value from public.system_text_settings ts where ts.key = p_key)), ''),
        p_default);
$function$;

-- Text that Make places between double quotes inside a JSON body.
create or replace function m417_internal.clean(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select btrim(regexp_replace(
        replace(replace(coalesce(p_text, ''), '"', ''''), chr(92), ''),
        '[[:space:]]+', ' ', 'g'));
$function$;

create or replace function m417_internal.rand_suffix()
 returns text language sql volatile set search_path to ''
as $function$
    select substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
$function$;

-- 0-1 scores from the models become 0-100; values already above 1 are kept.
create or replace function m417_internal.score100(p_score numeric)
 returns numeric language sql immutable set search_path to ''
as $function$
    select case
        when p_score is null then null
        when p_score < 0 then 0
        when p_score <= 1 then round(p_score * 100, 2)
        when p_score > 100 then 100
        else round(p_score, 2)
    end;
$function$;

-- True when a QC "details" object fails on lip_sync and on nothing else.
create or replace function m417_internal.only_lip_sync_failed(p_details jsonb)
 returns boolean language sql immutable set search_path to ''
as $function$
    select jsonb_typeof(p_details) = 'object'
       and upper(coalesce(p_details ->> 'lip_sync', '')) = 'FAIL'
       and not exists (
           select 1 from jsonb_each_text(p_details) d
           where d.key <> 'lip_sync' and upper(coalesce(d.value, '')) = 'FAIL');
$function$;

create or replace function m417_internal.safe_numeric(p_text text)
 returns numeric language plpgsql immutable set search_path to ''
as $function$
begin
    if p_text is null or btrim(p_text) = '' then
        return null;
    end if;
    return btrim(p_text)::numeric;
exception when others then
    return null;
end;
$function$;

create or replace function m417_internal.object_size(p_path text)
 returns bigint language sql stable security definer set search_path to ''
as $function$
    select (o.metadata ->> 'size')::bigint
    from storage.objects o
    where o.bucket_id = m417_internal.txt('storage_bucket', 'production-assets')
      and o.name = p_path
    limit 1;
$function$;

create or replace function m417_internal.event(
    p_type text, p_severity text, p_message text,
    p_meta jsonb default '{}'::jsonb,
    p_episode_id uuid default null, p_shot_id uuid default null, p_attempt_id uuid default null)
 returns void language sql security definer set search_path to ''
as $function$
    insert into public.events (event_type, episode_id, shot_id, attempt_id, severity, source, message, metadata)
    values (p_type, p_episode_id, p_shot_id, p_attempt_id, p_severity, 'PIPELINE', p_message, coalesce(p_meta, '{}'::jsonb));
$function$;

create or replace function m417_internal.usage(
    p_job_id uuid, p_service text, p_purpose text,
    p_units numeric default 1, p_unit text default 'call')
 returns void language sql security definer set search_path to ''
as $function$
    insert into public.service_usage (job_id, service, purpose, units, unit)
    values (p_job_id, p_service, p_purpose, coalesce(p_units, 1), p_unit);
$function$;

-- ----- job row -------------------------------------------------------
create or replace function m417_internal.lock_job(p_job_id uuid)
 returns public.production_jobs language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    if p_job_id is null then
        raise exception 'JOB_ID_REQUIRED';
    end if;
    select j.* into v_job
    from public.production_jobs j
    where j.id = p_job_id
    for update;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;
    return v_job;
end;
$function$;

create or replace function m417_internal.require_step(p_job public.production_jobs, p_step integer)
 returns void language plpgsql stable security definer set search_path to ''
as $function$
begin
    if m417_internal.flag('pipeline_enabled', false) is not true then
        raise exception 'PIPELINE_DISABLED';
    end if;
    if p_job.state <> 'READY' then
        raise exception 'JOB_NOT_READY: % (%)', p_job.state, coalesce(p_job.blocked_reason, '-');
    end if;
    if p_job.current_step <> p_step then
        raise exception 'STEP_MISMATCH: job is at step %, this call belongs to step %', p_job.current_step, p_step;
    end if;
end;
$function$;

create or replace function m417_internal.set_step(
    p_job_id uuid, p_step integer, p_event text,
    p_detail jsonb default '{}'::jsonb, p_state text default 'READY')
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
    update public.production_jobs
    set current_step = p_step,
        state = p_state,
        blocked_reason = null,
        blocked_detail = null,
        step_claimed_at = null,
        last_activity_at = now(),
        updated_at = now(),
        finished_at = case when p_state in ('DONE', 'CANCELLED') then now() else finished_at end
    where id = p_job_id;
    insert into public.job_step_log (job_id, step_no, event, detail)
    values (p_job_id, p_step, p_event, coalesce(p_detail, '{}'::jsonb));
end;
$function$;

create or replace function m417_internal.block_job(p_job_id uuid, p_reason text, p_detail text default null)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id for update;
    update public.production_jobs
    set state = 'BLOCKED',
        blocked_reason = p_reason,
        blocked_detail = left(p_detail, 2000),
        step_claimed_at = null,
        last_activity_at = now(),
        updated_at = now()
    where id = p_job_id;
    insert into public.job_step_log (job_id, step_no, event, detail)
    values (p_job_id, v_job.current_step, 'BLOCKED',
            jsonb_build_object('reason', p_reason, 'detail', left(p_detail, 2000)));
    perform m417_internal.event(
        'JOB_BLOCKED', 'WARNING',
        'Job blocked at step ' || v_job.current_step || ': ' || p_reason,
        jsonb_build_object('job_id', p_job_id, 'step_no', v_job.current_step, 'reason', p_reason, 'detail', left(p_detail, 2000)),
        v_job.episode_id);
end;
$function$;

create or replace function m417_internal.job_status(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'job_id', j.id,
        'episode_id', j.episode_id,
        'step_no', j.current_step,
        'state', j.state,
        'blocked_reason', coalesce(j.blocked_reason, ''),
        'blocked_detail', coalesce(j.blocked_detail, ''))
    from public.production_jobs j
    where j.id = p_job_id;
$function$;

-- One more revision round, or block when the limit is used up.
-- Creative revisions (Gemini pre-QC, Head Director) and automatic
-- format checks are counted separately.
-- Returns true when the job may continue at p_step.
create or replace function m417_internal.open_revision(
    p_job_id uuid, p_step integer, p_feedback jsonb, p_source text)
 returns boolean language plpgsql security definer set search_path to ''
as $function$
declare
    v_count integer;
    v_max integer;
begin
    if p_source = 'SYSTEM_VALIDATION' then
        v_max := m417_internal.num('max_validation_retries', 2)::integer;
        update public.production_jobs
        set validation_retry_count = validation_retry_count + 1,
            revision_feedback = p_feedback
        where id = p_job_id
        returning validation_retry_count into v_count;
    else
        v_max := m417_internal.num('max_revisions', 2)::integer;
        update public.production_jobs
        set revision_count = revision_count + 1,
            revision_feedback = p_feedback
        where id = p_job_id
        returning revision_count into v_count;
    end if;
    if v_count > v_max then
        perform m417_internal.block_job(
            p_job_id,
            case when p_source = 'SYSTEM_VALIDATION' then 'VALIDATION_RETRY_LIMIT_REACHED'
                 else 'REVISION_LIMIT_REACHED' end,
            'Source: ' || p_source || '. Feedback: ' || coalesce(p_feedback::text, ''));
        return false;
    end if;
    perform m417_internal.set_step(
        p_job_id, p_step, 'REVISION_OPENED',
        jsonb_build_object('source', p_source, 'round', v_count));
    return true;
end;
$function$;

-- ----- artifacts -----------------------------------------------------
create or replace function m417_internal.artifact(p_job_id uuid, p_type text)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select a.content
    from public.job_artifacts a
    where a.job_id = p_job_id
      and a.artifact_type = p_type
      and a.is_current = true;
$function$;

create or replace function m417_internal.artifact_text(p_job_id uuid, p_type text)
 returns text language sql stable security definer set search_path to ''
as $function$
    select coalesce(m417_internal.artifact(p_job_id, p_type)::text, '');
$function$;

create or replace function m417_internal.retire_artifacts(p_job_id uuid, p_types text[])
 returns void language sql security definer set search_path to ''
as $function$
    update public.job_artifacts
    set is_current = false
    where job_id = p_job_id
      and artifact_type = any (p_types)
      and is_current = true;
$function$;

-- ----- canon lookups -------------------------------------------------
-- Accepts a code (CHR_FATIH), a bare code (FATIH) or a name (Fatih).
create or replace function m417_internal.resolve_character(p_series_id uuid, p_ref text)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select c.id
    from public.characters c
    where c.series_id = p_series_id
      and c.status = 'LOCKED'
      and (
            upper(c.character_code) = upper(btrim(p_ref))
         or upper(c.character_code) = 'CHR_' || upper(btrim(p_ref))
         or lower(c.name) = lower(btrim(p_ref))
         or lower(translate(c.name, 'ÖöÜüİıŞşÇçĞğ', 'OoUuIiSsCcGg'))
            = lower(translate(btrim(p_ref), 'ÖöÜüİıŞşÇçĞğ', 'OoUuIiSsCcGg'))
      )
    order by c.version desc
    limit 1;
$function$;

create or replace function m417_internal.resolve_location(p_series_id uuid, p_ref text)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select l.id
    from public.locations l
    where l.series_id = p_series_id
      and l.status <> 'ARCHIVED'
      and (
            upper(l.location_code) = upper(btrim(p_ref))
         or upper(l.location_code) = 'LOC_' || upper(btrim(p_ref))
         or lower(l.name) = lower(btrim(p_ref))
      )
    order by l.version desc
    limit 1;
$function$;

create or replace function m417_internal.character_voice(p_character_id uuid)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select v.id
    from public.voice_identities v
    where v.character_id = p_character_id
      and v.status = 'LOCKED'
      and v.provider_voice_id is not null
      and btrim(v.provider_voice_id) <> ''
    order by v.version desc
    limit 1;
$function$;

-- Durations the PRIMARY video models of the active routing policy accept.
-- NULL means "no restriction known".
create or replace function m417_internal.allowed_shot_durations()
 returns integer[] language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_result integer[];
    v_model record;
    v_this integer[];
    v_have boolean := false;
begin
    for v_model in
        select gm.min_duration_seconds, gm.max_duration_seconds, gm.capability_metadata
        from public.generation_routing_policies grp
        join public.generation_policy_models gpm
          on gpm.policy_id = grp.id and gpm.enabled = true and gpm.route_role = 'PRIMARY'
        join public.generation_models gm on gm.id = gpm.model_id
        where grp.status = 'ACTIVE'
          and grp.id = (
              select p2.id from public.generation_routing_policies p2
              where p2.status = 'ACTIVE'
              order by p2.approved_at desc nulls last, p2.created_at desc
              limit 1)
    loop
        if jsonb_typeof(v_model.capability_metadata -> 'allowed_durations') = 'array' then
            select array_agg(x::integer order by x::integer) into v_this
            from jsonb_array_elements_text(v_model.capability_metadata -> 'allowed_durations') x;
        elsif v_model.min_duration_seconds is not null
          and v_model.max_duration_seconds is not null then
            select array_agg(g) into v_this
            from generate_series(ceil(v_model.min_duration_seconds)::integer,
                                 floor(v_model.max_duration_seconds)::integer) g;
        else
            continue;
        end if;
        if not v_have then
            v_result := v_this;
            v_have := true;
        else
            select array_agg(distinct u order by u) into v_result
            from unnest(v_result || v_this) u;
        end if;
    end loop;
    return v_result;
end;
$function$;

-- ----- series bible --------------------------------------------------
create or replace function m417_internal.series_bible(p_job_id uuid)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_series public.series;
    v_profile public.production_creative_profiles;
    v_style jsonb;
    v_characters jsonb;
    v_locations jsonb;
    v_durations integer[];
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;
    select s.* into v_series from public.series s where s.id = v_job.series_id;
    select p.* into v_profile from public.production_creative_profiles p where p.id = v_job.creative_profile_id;

    select to_jsonb(x) into v_style
    from (
        select sb.visual_style, sb.color_language, sb.lighting_language, sb.camera_language,
               sb.texture_language, sb.animation_language, sb.negative_rules
        from public.style_bibles sb
        where sb.series_id = v_series.id and sb.status <> 'ARCHIVED'
        order by sb.version desc
        limit 1
    ) x;

    select coalesce(jsonb_agg(jsonb_build_object(
               'code', c.character_code,
               'name', c.name,
               'age', c.age,
               'role', c.role_type,
               'description', c.canonical_description,
               'core_traits', c.personality -> 'core_traits',
               'weaknesses', c.personality -> 'weaknesses',
               'behavior_rules', c.behavior_rules,
               'relationships', c.relationship_rules,
               'has_voice', m417_internal.character_voice(c.id) is not null,
               'reference_asset', (
                   select ar.asset_code
                   from public.asset_registry ar
                   where ar.character_id = c.id
                     and ar.asset_type = 'CHARACTER_REFERENCE'
                     and ar.status = 'LOCKED'
                   order by ar.version desc
                   limit 1)
           ) order by c.character_code), '[]'::jsonb)
    into v_characters
    from public.characters c
    where c.series_id = v_series.id
      and c.status = 'LOCKED';

    select coalesce(jsonb_agg(jsonb_build_object(
               'code', l.location_code,
               'name', l.name,
               'type', l.location_type,
               'description', left(l.canonical_description, 220),
               'reference_assets', (
                   select coalesce(jsonb_agg(ar.asset_code order by ar.asset_code), '[]'::jsonb)
                   from public.asset_registry ar
                   where ar.location_id = l.id
                     and ar.asset_type = 'LOCATION_REFERENCE'
                     and ar.status = 'LOCKED')
           ) order by l.location_code), '[]'::jsonb)
    into v_locations
    from public.locations l
    where l.series_id = v_series.id
      and l.status <> 'ARCHIVED';

    v_durations := m417_internal.allowed_shot_durations();

    return jsonb_build_object(
        'series', jsonb_build_object(
            'code', v_series.series_code,
            'name', v_series.name,
            'language', v_series.primary_language,
            'target_audience', v_series.target_audience,
            'target_age_min', v_series.target_age_min,
            'target_age_max', v_series.target_age_max,
            'premise', v_series.premise,
            'world_rules', v_series.world_rules,
            'creative_rules', v_series.creative_rules,
            'forbidden_rules', v_series.forbidden_rules),
        'format', jsonb_build_object(
            'production_mode', v_profile.production_mode,
            'aspect_ratio', v_profile.aspect_ratio,
            'total_duration_seconds_min', greatest(v_profile.target_duration_min_seconds, 6),
            'total_duration_seconds_target_max', v_profile.target_duration_max_seconds,
            'total_duration_seconds_hard_max', least(v_profile.hard_duration_max_seconds, 15),
            'hook_deadline_seconds', v_profile.hook_deadline_seconds,
            'allowed_shot_durations_seconds', coalesce(to_jsonb(v_durations), '"any whole number from 1 to 15"'::jsonb),
            'shot_duration_rule', 'Every shot duration must be one of allowed_shot_durations_seconds. The sum of all shot durations must lie inside the total duration limits.',
            'max_characters_per_shot', m417_internal.num('max_characters_per_shot', 3)::integer,
            'shot_cast_rule', format(
                'A shot shows at most %s characters; one or two is better. Whoever speaks in a shot is visible in it. Write scenes so that every shot works with that few characters on screen and carries one clear action; the others can be off-screen.',
                m417_internal.num('max_characters_per_shot', 3)::integer),
            'shot_package_rule', 'A shot package always contains every shot of the episode, also when it is a revision; every scene has at least one shot.',
            'video_prompt_rule', 'video_prompt is plain descriptive English for the video model: characters by their plain names, no codes, no asset names, no brackets, no spoken words.',
            'code_rule', 'Use the exact character and location codes listed here. Do not invent characters, locations or assets.',
            'dialogue_rule', 'Only characters with has_voice = true may speak.',
            'dialogue_timing_rule', format(
                'Spoken lines are checked against real speech time: about 1 second per %s characters (spaces and punctuation included) plus %s s per line, plus %s s for every sentence break inside a line (. ! ? or ... followed by more words). All lines spoken in a shot must fit inside that shot, and all lines of a scene inside that scene. A single-sentence line that fits: 2 s holds %s characters, 3 s holds %s, 4 s holds %s, 5 s holds %s. Prefer one short sentence per line; when in doubt, cut words or give the shot one more second.',
                m417_internal.num('speech_chars_per_second', 13)::text,
                m417_internal.num('speech_padding_seconds', 0.4)::text,
                m417_internal.num('speech_pause_seconds', 0.5)::text,
                m417_internal.speech_max_chars(2), m417_internal.speech_max_chars(3),
                m417_internal.speech_max_chars(4), m417_internal.speech_max_chars(5)),
            'creative_rules', v_profile.creative_rules,
            'quality_rules', v_profile.quality_rules),
        'style', coalesce(v_style, '{}'::jsonb),
        'characters', v_characters,
        'locations', v_locations);
end;
$function$;

-- ----- script / shot package validation ------------------------------
-- Seconds a voice needs to say a text: characters at the configured
-- speaking rate, the silence around the words, and a pause for every
-- sentence break inside the line. Calibrated on the first real takes
-- (9 Oct 2026): 'Reflexes! Still got it.' ran 2.8-3.8 s.
create or replace function m417_internal.speech_seconds(p_text text)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select case when m417_internal.clean(p_text) = '' then 0
           else round(char_length(m417_internal.clean(p_text))
                      / greatest(m417_internal.num('speech_chars_per_second', 13), 1)
                      + m417_internal.num('speech_padding_seconds', 0.4)
                      + m417_internal.num('speech_pause_seconds', 0.5)
                        * (select count(*) from regexp_matches(m417_internal.clean(p_text), '[.!?…]+\s+\S', 'g')),
                      2) end;
$function$;

-- Characters of dialogue that fit comfortably into p_seconds.
create or replace function m417_internal.speech_max_chars(p_seconds numeric)
 returns integer language sql stable security definer set search_path to ''
as $function$
    select greatest(0, floor((coalesce(p_seconds, 0) - m417_internal.num('speech_padding_seconds', 0.4))
                             * greatest(m417_internal.num('speech_chars_per_second', 13), 1)))::integer;
$function$;

create or replace function m417_internal.issue(p_target text, p_ref text, p_detail text, p_fix text)
 returns jsonb language sql immutable set search_path to ''
as $function$
    select jsonb_build_object(
        'target', p_target, 'ref', p_ref, 'severity', 'HIGH',
        'detail', p_detail, 'fix', p_fix);
$function$;

create or replace function m417_internal.validate_script(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_issues jsonb := '[]'::jsonb;
    v_scene jsonb;
    v_line jsonb;
    v_scene_no text;
    v_total numeric := 0;
    v_dur numeric;
    v_char uuid;
    v_scene_idx integer := 0;
    v_speech numeric;
    v_tol numeric := m417_internal.num('voice_duration_tolerance_seconds', 0.5);
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if jsonb_typeof(p_content -> 'scenes') is distinct from 'array'
       or jsonb_array_length(p_content -> 'scenes') = 0
    then
        return jsonb_build_array(m417_internal.issue(
            'SCRIPT', 'scenes', 'The script has no scenes array.',
            'Return the script in the required JSON shape with at least one scene.'));
    end if;
    for v_scene in select * from jsonb_array_elements(p_content -> 'scenes')
    loop
        v_scene_idx := v_scene_idx + 1;
        v_scene_no := coalesce(v_scene ->> 'scene_no', v_scene_idx::text);
        v_dur := m417_internal.safe_numeric(v_scene ->> 'duration_seconds');
        if v_dur is null or v_dur <= 0 then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no, 'duration_seconds is missing or not positive.',
                'Give every scene a positive duration in seconds.');
        else
            v_total := v_total + v_dur;
        end if;
        if coalesce(btrim(v_scene ->> 'location'), '') <> ''
           and m417_internal.resolve_location(v_job.series_id, v_scene ->> 'location') is null
        then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no,
                'Unknown location: ' || (v_scene ->> 'location'),
                'Use one of the location codes from the series bible.');
        end if;
        v_speech := 0;
        if jsonb_typeof(v_scene -> 'dialogue') = 'array' then
            for v_line in select * from jsonb_array_elements(v_scene -> 'dialogue')
            loop
                v_speech := v_speech + m417_internal.speech_seconds(v_line ->> 'text');
                if coalesce(btrim(v_line ->> 'text'), '') = '' then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Dialogue line has no text.', 'Remove the line or give it text.');
                end if;
                v_char := m417_internal.resolve_character(v_job.series_id, v_line ->> 'character');
                if v_char is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Unknown speaking character: ' || coalesce(v_line ->> 'character', '(empty)'),
                        'Use a character code from the series bible.');
                elsif m417_internal.character_voice(v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Character has no locked voice: ' || (v_line ->> 'character'),
                        'Give the line to a character with has_voice = true.');
                end if;
            end loop;
        end if;
        -- Checked here, before any voice is paid for.
        if v_dur is not null and v_dur > 0 and v_speech > v_dur + v_tol then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no,
                format('The dialogue of this scene takes about %s s to say, but the scene lasts %s s.', v_speech, v_dur),
                format('Shorten the lines of this scene to at most %s characters in total (spaces included), or make the scene longer. See dialogue_timing_rule.',
                       m417_internal.speech_max_chars(v_dur)));
        end if;
    end loop;
    if v_total < 6 or v_total > 15 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'total duration',
            'Scene durations add up to ' || v_total || ' seconds; the episode must be 6 to 15 seconds.',
            'Adjust scene durations so the total is between 6 and 15 seconds.');
    end if;
    return v_issues;
end;
$function$;

-- Finds one dialogue line of the script: first inside the given scene,
-- then anywhere if the line number is unique.
create or replace function m417_internal.script_line(p_script jsonb, p_scene_no text, p_line_no text)
 returns jsonb language sql immutable set search_path to ''
as $function$
    with lines as (
        select coalesce(s.scene ->> 'scene_no', s.idx::text) as scene_no,
               coalesce(l.line ->> 'line_no', l.idx::text) as line_no,
               l.line
        from jsonb_array_elements(p_script -> 'scenes') with ordinality as s(scene, idx)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(s.scene -> 'dialogue') = 'array'
                 then s.scene -> 'dialogue' else '[]'::jsonb end
        ) with ordinality as l(line, idx)
    )
    select coalesce(
        (select x.line || jsonb_build_object('scene_no', x.scene_no, 'line_no', x.line_no)
         from lines x
         where x.scene_no = p_scene_no and x.line_no = p_line_no
         limit 1),
        (select x.line || jsonb_build_object('scene_no', x.scene_no, 'line_no', x.line_no)
         from lines x
         where x.line_no = p_line_no
           and (select count(*) from lines y where y.line_no = p_line_no) = 1
         limit 1));
$function$;

create or replace function m417_internal.validate_shot_package(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_script jsonb;
    v_issues jsonb := '[]'::jsonb;
    v_shot jsonb;
    v_idx integer := 0;
    v_ref text;
    v_dur numeric;
    v_total numeric := 0;
    v_allowed integer[] := m417_internal.allowed_shot_durations();
    v_char text;
    v_line_no text;
    v_line jsonb;
    v_assigned text[] := array[]::text[];
    v_missing record;
    v_speech numeric;
    v_tol numeric := m417_internal.num('voice_duration_tolerance_seconds', 0.5);
    v_max_cast integer := m417_internal.num('max_characters_per_shot', 3)::integer;
    v_min_prompt integer := m417_internal.num('video_prompt_min_chars', 120)::integer;
    v_prompt text;
    v_cast uuid[];
    v_speaker uuid;
    v_scene record;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    v_script := m417_internal.artifact(p_job_id, 'SCRIPT');
    if jsonb_typeof(p_content -> 'shots') is distinct from 'array'
       or jsonb_array_length(p_content -> 'shots') = 0
    then
        return jsonb_build_array(m417_internal.issue(
            'SHOTS', 'shots', 'The shot package has no shots array.',
            'Return the shot package in the required JSON shape with at least one shot.'));
    end if;
    if jsonb_array_length(p_content -> 'shots') > 6 then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'shots', 'More than 6 shots.', 'Use at most 6 shots.');
    end if;
    for v_shot in select * from jsonb_array_elements(p_content -> 'shots')
    loop
        v_idx := v_idx + 1;
        v_ref := 'shot ' || coalesce(v_shot ->> 'shot_no', v_idx::text);
        v_dur := m417_internal.safe_numeric(v_shot ->> 'duration_seconds');
        if v_dur is null or v_dur < 1 or v_dur > 15 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'duration_seconds is missing or outside 1 to 15.',
                'Give the shot a duration from allowed_shot_durations_seconds.');
        else
            v_total := v_total + v_dur;
            if v_allowed is not null
               and (v_dur <> trunc(v_dur) or not (v_dur::integer = any (v_allowed)))
            then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    'Duration ' || v_dur || ' is not supported by the video model. Allowed: ' || array_to_string(v_allowed, ', '),
                    'Use one of the allowed shot durations.');
            end if;
        end if;
        -- The video prompt is what the video model reads: it has to be
        -- real description, not a template or a list of codes.
        v_prompt := btrim(coalesce(v_shot ->> 'video_prompt', ''));
        if v_prompt = '' then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'video_prompt is empty.', 'Write the video prompt for this shot.');
        else
            if v_prompt ~ '[<>]' then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'video_prompt contains angle brackets or a placeholder such as <PROMPT: ...>.',
                    'Write video_prompt as plain descriptive English without brackets or placeholders.');
            end if;
            if v_prompt ~ '\m(CHR|LOC)_[A-Z0-9_]+' or v_prompt ~ '\m[A-Z][A-Z0-9]*(_[A-Z0-9]+)*_V[0-9]+\M' then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'video_prompt contains codes or asset names; the video model does not understand them.',
                    'Call characters by their plain names (for example Mia) and describe the place in words. Codes belong only in characters, location and reference_assets.');
            end if;
            if char_length(v_prompt) < v_min_prompt then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('video_prompt is only %s characters long; at least %s are needed.', char_length(v_prompt), v_min_prompt),
                    'Describe framing and camera, where each character is, what they do beat by beat, their expressions and body language, the place and the light.');
            end if;
        end if;
        v_cast := array[]::uuid[];
        if jsonb_typeof(v_shot -> 'characters') = 'array' then
            for v_char in select * from jsonb_array_elements_text(v_shot -> 'characters')
            loop
                if m417_internal.resolve_character(v_job.series_id, v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref, 'Unknown character: ' || v_char,
                        'Use character codes from the series bible.');
                elsif not (m417_internal.resolve_character(v_job.series_id, v_char) = any (v_cast)) then
                    v_cast := v_cast || m417_internal.resolve_character(v_job.series_id, v_char);
                end if;
            end loop;
        end if;
        if coalesce(btrim(v_shot ->> 'location'), '') <> ''
           and m417_internal.resolve_location(v_job.series_id, v_shot ->> 'location') is null
        then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'Unknown location: ' || (v_shot ->> 'location'),
                'Use a location code from the series bible.');
        end if;
        v_speech := 0;
        if jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array' then
            for v_line_no in select * from jsonb_array_elements_text(v_shot -> 'dialogue_line_nos')
            loop
                v_line := m417_internal.script_line(v_script, v_shot ->> 'scene_no', v_line_no);
                v_speech := v_speech + m417_internal.speech_seconds(v_line ->> 'text');
                if v_line is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref,
                        'dialogue_line_nos refers to line ' || v_line_no || ', which is not in scene ' || coalesce(v_shot ->> 'scene_no', '?') || ' of the script.',
                        'Reference only line numbers that exist in the script scene of this shot.');
                else
                    v_assigned := v_assigned || ((v_line ->> 'scene_no') || ':' || (v_line ->> 'line_no'));
                    -- Whoever speaks in a shot is seen in it.
                    v_speaker := m417_internal.resolve_character(v_job.series_id, v_line ->> 'character');
                    if v_speaker is not null and not (v_speaker = any (v_cast)) then
                        v_cast := v_cast || v_speaker;
                        v_issues := v_issues || m417_internal.issue(
                            'SHOTS', v_ref,
                            'Line ' || v_line_no || ' is spoken by ' || (v_line ->> 'character') || ', who is not listed in characters of this shot.',
                            'Add the speaker to characters of this shot, or move the line to a shot of the same scene in which the speaker is visible.');
                    end if;
                end if;
            end loop;
        end if;
        if cardinality(v_cast) > v_max_cast then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref,
                format('%s characters are in this shot; at most %s can be shown.', cardinality(v_cast), v_max_cast),
                format('Show at most %s characters in a shot: frame the ones that matter for this beat and keep the others off-screen, or split the scene into more shots.', v_max_cast));
        end if;
        if v_dur is not null and v_dur >= 1 and v_speech > v_dur + v_tol then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref,
                format('The lines spoken in this shot take about %s s to say, but the shot lasts %s s.', v_speech, v_dur),
                format('Give this shot at least %s s (an allowed duration), or move one of its lines to a neighbouring shot of the same scene. Do not change the script text.',
                       ceil(v_speech - v_tol)));
        end if;
    end loop;
    if v_total < 6 or v_total > 15 then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'total duration',
            'Shot durations add up to ' || v_total || ' seconds; the episode must be 6 to 15 seconds.',
            'Change the number of shots or their durations so the total is between 6 and 15 seconds.');
    end if;
    -- Every scene of the script needs at least one shot: a package is
    -- always the whole episode, also when it is a revision.
    for v_scene in
        select coalesce(sc.scene ->> 'scene_no', sc.idx::text) as scene_no
        from jsonb_array_elements(coalesce(v_script -> 'scenes', '[]'::jsonb)) with ordinality as sc(scene, idx)
        where not exists (
            select 1 from jsonb_array_elements(p_content -> 'shots') sh(value)
            where sh.value ->> 'scene_no' = coalesce(sc.scene ->> 'scene_no', sc.idx::text))
    loop
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'scene ' || v_scene.scene_no,
            'Scene ' || v_scene.scene_no || ' of the script has no shot.',
            'Return the complete shot package: every scene needs at least one shot, and shots that did not change must be included again.');
    end loop;
    -- Every scripted line must be spoken in exactly one shot.
    for v_missing in
        select coalesce(s.scene ->> 'scene_no', s.idx::text) as scene_no,
               coalesce(l.line ->> 'line_no', l.idx::text) as line_no
        from jsonb_array_elements(coalesce(v_script -> 'scenes', '[]'::jsonb)) with ordinality as s(scene, idx)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(s.scene -> 'dialogue') = 'array'
                 then s.scene -> 'dialogue' else '[]'::jsonb end
        ) with ordinality as l(line, idx)
    loop
        if not ((v_missing.scene_no || ':' || v_missing.line_no) = any (v_assigned)) then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'scene ' || v_missing.scene_no || ' line ' || v_missing.line_no,
                'This script line is not assigned to any shot.',
                'Add the line number to dialogue_line_nos of the shot in which it is spoken.');
        end if;
    end loop;
    if (select count(*) from unnest(v_assigned) a) <> (select count(distinct a) from unnest(v_assigned) a) then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'dialogue_line_nos', 'A script line is assigned to more than one shot.',
            'Assign every script line to exactly one shot.');
    end if;
    return v_issues;
end;
$function$;

-- =====================================================================
-- 6. RPC: S1 start, common, S2 creative planning
-- =====================================================================

-- ----- steps 1-4 ----------------------------------------------------
create or replace function public.start_production_job(
    p_idempotency_key text, p_series_code text, p_request jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_series public.series;
    v_profile public.production_creative_profiles;
    v_episode_budget numeric;
    v_shot_budget numeric;
    v_episode_id uuid;
    v_content_id text;
    v_job_id uuid;
    v_active integer;
begin
    if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
        raise exception 'IDEMPOTENCY_KEY_REQUIRED';
    end if;

    -- The same key always returns the same job.
    select j.* into v_job
    from public.production_jobs j
    where j.idempotency_key = btrim(p_idempotency_key);
    if found then
        return m417_internal.job_status(v_job.id)
            || jsonb_build_object('decision', 'EXISTING');
    end if;

    if m417_internal.flag('pipeline_enabled', false) is not true then
        raise exception 'PIPELINE_DISABLED';
    end if;

    select s.* into v_series
    from public.series s
    where upper(s.series_code) = upper(btrim(coalesce(p_series_code, '')))
      and s.status <> 'ARCHIVED'
    order by s.version desc
    limit 1;
    if not found then
        raise exception 'SERIES_NOT_FOUND: %', coalesce(p_series_code, '(empty)');
    end if;

    select p.* into v_profile
    from public.production_creative_profiles p
    where upper(p.profile_code) = upper(btrim(coalesce(p_request ->> 'creative_profile_code', '')))
      and p.status = 'LOCKED';
    if not found then
        raise exception 'LOCKED_CREATIVE_PROFILE_NOT_FOUND: %',
            coalesce(p_request ->> 'creative_profile_code', '(empty)');
    end if;

    v_episode_budget := m417_internal.safe_numeric(p_request ->> 'episode_budget_usd');
    v_shot_budget := m417_internal.safe_numeric(p_request ->> 'shot_budget_usd');
    if v_episode_budget is null or v_episode_budget <= 0 then
        raise exception 'EPISODE_BUDGET_REQUIRED';
    end if;
    if v_shot_budget is null or v_shot_budget <= 0 then
        raise exception 'SHOT_BUDGET_REQUIRED';
    end if;
    if v_shot_budget > v_episode_budget then
        raise exception 'SHOT_BUDGET_EXCEEDS_EPISODE_BUDGET';
    end if;

    -- Serialise job creation so the active-job limit holds.
    perform 1 from public.system_flags sf where sf.key = 'pipeline_enabled' for update;
    select count(*) into v_active
    from public.production_jobs j
    where j.state not in ('DONE', 'CANCELLED');
    if v_active >= m417_internal.num('max_active_jobs', 1) then
        raise exception 'ACTIVE_JOB_LIMIT_REACHED: % job(s) in progress', v_active;
    end if;

    v_job_id := gen_random_uuid();
    v_content_id := v_series.series_code || '-' || to_char(now() at time zone 'UTC', 'YYYYMMDD')
                    || '-' || upper(substr(replace(v_job_id::text, '-', ''), 1, 6));

    insert into public.episodes (
        content_id, series_id, state, maximum_budget, production_mode, creative_profile_id)
    values (
        v_content_id, v_series.id, 'PLANNED', v_episode_budget,
        v_profile.production_mode, v_profile.id)
    returning id into v_episode_id;

    update public.episodes set state = 'PREPRODUCTION' where id = v_episode_id;

    insert into public.budgets (budget_type, reference_id, currency, hard_limit, is_active)
    values ('EPISODE', v_episode_id, 'USD', v_episode_budget, true);

    insert into public.production_jobs (
        id, idempotency_key, series_id, episode_id, creative_profile_id, request, current_step, state)
    values (
        v_job_id, btrim(p_idempotency_key), v_series.id, v_episode_id, v_profile.id,
        coalesce(p_request, '{}'::jsonb), 5, 'READY');

    insert into public.job_step_log (job_id, step_no, event, detail)
    values (v_job_id, 5, 'JOB_STARTED',
            jsonb_build_object('content_id', v_content_id, 'series_code', v_series.series_code,
                               'creative_profile_code', v_profile.profile_code));
    perform m417_internal.event(
        'JOB_STARTED', 'INFO', 'Production job started for ' || v_content_id,
        jsonb_build_object('job_id', v_job_id, 'episode_budget_usd', v_episode_budget, 'shot_budget_usd', v_shot_budget),
        v_episode_id);

    return m417_internal.job_status(v_job_id)
        || jsonb_build_object('decision', 'CREATED', 'content_id', v_content_id);
end;
$function$;

-- ----- every scenario starts here -----------------------------------
create or replace function public.job_next_step(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_status jsonb;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id for update;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;
    v_status := m417_internal.job_status(p_job_id);
    if v_job.state <> 'READY' then
        return v_status;
    end if;
    -- With the pipeline switched off no scenario may act on a job.
    if m417_internal.flag('pipeline_enabled', false) is not true then
        return v_status || jsonb_build_object(
            'state', 'BLOCKED', 'blocked_reason', 'PIPELINE_DISABLED');
    end if;

    -- One run per step: a second run that asks while the first is still
    -- working is told IN_PROGRESS and does nothing.
    if m417_internal.step_has_lease(v_job.current_step) then
        if v_job.step_claimed_step is not distinct from v_job.current_step
           and v_job.step_claimed_at > now() - make_interval(secs => m417_internal.num('step_lease_seconds', 180))
        then
            return v_status || jsonb_build_object('state', 'IN_PROGRESS', 'busy', 'STEP_ALREADY_RUNNING');
        end if;
        update public.production_jobs
        set step_claimed_at = now(), step_claimed_step = current_step
        where id = p_job_id;
    elsif v_job.current_step between 16 and 18 and m417_internal.voice_batch_open(p_job_id) then
        return v_status || jsonb_build_object('state', 'IN_PROGRESS', 'busy', 'VOICE_BATCH_RUNNING');
    end if;
    return v_status;
end;
$function$;

create or replace function public.get_job_context(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_request jsonb;
    v_preqc text;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;

    v_request := v_job.request;
    if v_job.topic_feedback is not null then
        v_request := v_request || jsonb_build_object('rejected_topics', v_job.topic_feedback);
    end if;

    -- While a revision is open the writer sees the feedback that opened
    -- it; afterwards the reviewers see the real pre-QC report.
    if v_job.current_step in (10, 11) and v_job.revision_feedback is not null then
        v_preqc := v_job.revision_feedback::text;
    else
        v_preqc := m417_internal.artifact_text(p_job_id, 'PREQC_REPORT');
    end if;

    return jsonb_build_object(
        'job_id', v_job.id,
        'step_no', v_job.current_step,
        'series_bible_text', m417_internal.series_bible(p_job_id)::text,
        'request_text', v_request::text,
        'trend_report_text', m417_internal.artifact_text(p_job_id, 'TREND_REPORT'),
        'topic_selection_text', m417_internal.artifact_text(p_job_id, 'TOPIC_SELECTION'),
        'script_text', m417_internal.artifact_text(p_job_id, 'SCRIPT'),
        'shot_package_text', m417_internal.artifact_text(p_job_id, 'SHOT_PACKAGE'),
        'preqc_report_text', v_preqc,
        'assistant_review_text', '',
        'music_library_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'track_code', mt.track_code, 'title', mt.title, 'role', mt.role,
                       'mood', mt.mood, 'duration_seconds', mt.duration_seconds)
                       order by mt.track_code), '[]'::jsonb)::text
            from public.music_tracks mt
            where mt.is_active = true and mt.license_status = 'VERIFIED'),
        'final_qc_report_text', coalesce((
            select r.qc_result::text
            from public.renders r
            where r.job_id = p_job_id and r.qc_result is not null
            order by r.render_no desc
            limit 1), ''),
        'policy_checks_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'gate_no', pc.gate_no, 'verdict', pc.verdict, 'checker', pc.checker,
                       'findings', pc.result -> 'findings', 'notes', pc.result -> 'notes')
                       order by pc.created_at), '[]'::jsonb)::text
            from public.policy_checks pc
            where pc.job_id = p_job_id),
        'metadata_candidates_text', m417_internal.artifact_text(p_job_id, 'METADATA_CANDIDATES'));
end;
$function$;

-- ----- step 5 and step 21 -------------------------------------------
create or replace function public.evaluate_budget_gate(p_job_id uuid, p_gate_no integer)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_step integer;
    v_monthly_available numeric;
    v_episode_limit numeric;
    v_episode_available numeric;
    v_policy_id uuid;
    v_shot record;
    v_cost numeric;
    v_total numeric := 0;
    v_problems text[] := array[]::text[];
    v_reason text;
begin
    if p_gate_no not in (1, 2) then
        raise exception 'INVALID_BUDGET_GATE';
    end if;
    v_step := case p_gate_no when 1 then 5 else 21 end;
    v_job := m417_internal.lock_job(p_job_id);
    -- Repeating a gate that already passed changes nothing.
    if v_job.current_step > v_step then
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('gate_no', p_gate_no, 'passed', true, 'decision', 'ALREADY_PASSED');
    end if;
    perform m417_internal.require_step(v_job, v_step);

    select (b.hard_limit - b.reserved_amount - b.settled_amount)
    into v_monthly_available
    from public.budgets b
    where b.budget_type = 'MONTHLY'
      and b.reference_id is null
      and b.currency = 'USD'
      and b.is_active = true
      and (b.period_start is null or b.period_start <= now())
      and (b.period_end is null or b.period_end > now())
    order by b.created_at desc
    limit 1;

    select b.hard_limit, (b.hard_limit - b.reserved_amount - b.settled_amount)
    into v_episode_limit, v_episode_available
    from public.budgets b
    where b.budget_type = 'EPISODE'
      and b.reference_id = v_job.episode_id
      and b.is_active = true
    order by b.created_at desc
    limit 1;

    if v_monthly_available is null then
        v_problems := v_problems || 'ACTIVE_MONTHLY_BUDGET_MISSING'::text;
    elsif p_gate_no = 1 and v_monthly_available < v_episode_limit then
        v_problems := v_problems || format(
            'MONTHLY_BUDGET_TOO_LOW: %s available, episode budget %s', v_monthly_available, v_episode_limit);
    end if;
    if v_episode_limit is null then
        v_problems := v_problems || 'ACTIVE_EPISODE_BUDGET_MISSING'::text;
    end if;

    if p_gate_no = 2 and cardinality(v_problems) = 0 then
        select grp.id into v_policy_id
        from public.generation_routing_policies grp
        where grp.status = 'ACTIVE' and grp.approved_at is not null
        order by grp.approved_at desc
        limit 1;
        if v_policy_id is null then
            v_problems := v_problems || 'NO_ACTIVE_ROUTING_POLICY'::text;
        else
            for v_shot in
                select s.shot_code, s.maximum_budget, ss.id as spec_id
                from public.shots s
                join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
                where s.episode_id = v_job.episode_id
                order by s.shot_order
            loop
                -- Cheapest PRIMARY model that fits the shot and has an
                -- approved benchmark or an owner pilot approval. Live
                -- health is checked at acquisition.
                select min(ec.estimated_cost) into v_cost
                from public.generation_policy_models gpm
                join public.evaluate_generation_candidates(v_shot.spec_id) ec
                  on ec.model_id = gpm.model_id
                where gpm.policy_id = v_policy_id
                  and gpm.enabled = true
                  and gpm.route_role = 'PRIMARY'
                  and ec.duration_compatible and ec.aspect_ratio_compatible
                  and ec.resolution_compatible and ec.reference_compatible
                  and ec.pricing_compatible
                  and (exists (
                          select 1 from public.generation_model_benchmarks b
                          where b.model_id = gpm.model_id
                            and b.benchmark_status = 'HUMAN_APPROVED'
                            and b.approved_at is not null)
                       or exists (
                          select 1 from public.generation_model_pilot_approvals pa
                          where pa.model_id = gpm.model_id
                            and pa.revoked_at is null));
                if v_cost is null then
                    v_problems := v_problems || ('NO_ELIGIBLE_PRIMARY_MODEL: ' || v_shot.shot_code);
                else
                    v_total := v_total + v_cost;
                    if v_cost > v_shot.maximum_budget then
                        v_problems := v_problems || format(
                            'SHOT_BUDGET_TOO_LOW: %s needs %s, budget %s',
                            v_shot.shot_code, v_cost, v_shot.maximum_budget);
                    end if;
                end if;
            end loop;
            if v_total > v_episode_available then
                v_problems := v_problems || format(
                    'EPISODE_BUDGET_TOO_LOW: video needs %s, %s available', v_total, v_episode_available);
            end if;
            if v_total > v_monthly_available then
                v_problems := v_problems || format(
                    'MONTHLY_BUDGET_TOO_LOW: video needs %s, %s available', v_total, v_monthly_available);
            end if;
        end if;
    end if;

    if cardinality(v_problems) > 0 then
        v_reason := case
            when p_gate_no = 1 then 'BUDGET_GATE_1_FAILED'
            when exists (
                select 1 from unnest(v_problems) x
                where x like 'NO_ACTIVE_ROUTING_POLICY%' or x like 'NO_ELIGIBLE_PRIMARY_MODEL%')
            then 'VIDEO_PREREQUISITES_MISSING'
            else 'BUDGET_GATE_2_FAILED' end;
        perform m417_internal.block_job(p_job_id, v_reason, array_to_string(v_problems, '; '));
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('gate_no', p_gate_no, 'passed', false, 'problems', to_jsonb(v_problems));
    end if;

    perform m417_internal.set_step(
        p_job_id, v_step + 1, 'BUDGET_GATE_PASSED',
        jsonb_build_object('gate_no', p_gate_no, 'monthly_available', v_monthly_available,
                           'episode_limit', v_episode_limit, 'estimated_video_cost', v_total));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object(
            'gate_no', p_gate_no, 'passed', true,
            'monthly_available', v_monthly_available,
            'episode_limit', v_episode_limit,
            'estimated_video_cost', v_total,
            'generation_enabled', m417_internal.flag('generation_enabled', false));
end;
$function$;

-- ----- steps 6, 7, 10, 11, 12, 19, 36 -------------------------------
create or replace function public.save_artifact(
    p_job_id uuid, p_artifact_type text, p_producer text, p_content jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_type text := upper(btrim(coalesce(p_artifact_type, '')));
    v_producer text := upper(btrim(coalesce(p_producer, '')));
    v_step integer;
    v_owner text;
    v_issues jsonb := '[]'::jsonb;
    v_version integer;
    v_artifact_id uuid;
    v_verdict text;
    v_continue boolean;
begin
    select x.step, x.owner into v_step, v_owner
    from (values
        ('TREND_REPORT', 6, 'GROK'),
        ('TOPIC_SELECTION', 7, 'CLAUDE'),
        ('SCRIPT', 10, 'CLAUDE'),
        ('SHOT_PACKAGE', 11, 'OPENAI'),
        ('PREQC_REPORT', 12, 'GEMINI'),
        ('MUSIC_SFX_PLAN', 19, 'CLAUDE'),
        ('METADATA_CANDIDATES', 36, 'GROK')
    ) as x(atype, step, owner)
    where x.atype = v_type;
    if not found then
        raise exception 'ARTIFACT_TYPE_NOT_ACCEPTED: %', v_type;
    end if;
    if v_producer <> v_owner then
        raise exception 'PRODUCER_NOT_AUTHORIZED: % may not write %', v_producer, v_type;
    end if;
    if p_content is null or jsonb_typeof(p_content) <> 'object' then
        raise exception 'ARTIFACT_CONTENT_MUST_BE_JSON_OBJECT';
    end if;

    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, v_step);

    -- Shape checks that cannot be repaired by another round stop here.
    if v_type = 'TOPIC_SELECTION'
       and (coalesce(btrim(p_content ->> 'title'), '') = '' or coalesce(btrim(p_content ->> 'premise'), '') = '')
    then
        raise exception 'TOPIC_SELECTION_INCOMPLETE: title and premise are required';
    end if;
    if v_type = 'PREQC_REPORT' then
        v_verdict := upper(btrim(coalesce(p_content ->> 'verdict', '')));
        if v_verdict not in ('PASS', 'REVISE_SCRIPT', 'REVISE_SHOTS') then
            raise exception 'PREQC_VERDICT_INVALID: %', coalesce(p_content ->> 'verdict', '(empty)');
        end if;
    end if;
    if v_type = 'MUSIC_SFX_PLAN' and jsonb_typeof(p_content -> 'tracks') is distinct from 'array' then
        raise exception 'MUSIC_PLAN_TRACKS_MUST_BE_ARRAY';
    end if;
    if v_type = 'METADATA_CANDIDATES'
       and (jsonb_typeof(p_content -> 'candidates') is distinct from 'array'
            or jsonb_array_length(p_content -> 'candidates') = 0)
    then
        raise exception 'METADATA_CANDIDATES_REQUIRED';
    end if;

    -- Problems the writer can fix go back to the writer.
    if v_type = 'SCRIPT' then
        v_issues := m417_internal.validate_script(p_job_id, p_content);
    elsif v_type = 'SHOT_PACKAGE' then
        v_issues := m417_internal.validate_shot_package(p_job_id, p_content);
    end if;

    -- A new script makes the old shots and review stale; new shots make
    -- the old review stale.
    if v_type = 'SCRIPT' then
        perform m417_internal.retire_artifacts(p_job_id, array['SHOT_PACKAGE', 'PREQC_REPORT']);
    elsif v_type = 'SHOT_PACKAGE' then
        perform m417_internal.retire_artifacts(p_job_id, array['PREQC_REPORT']);
    end if;
    perform m417_internal.retire_artifacts(p_job_id, array[v_type]);

    select coalesce(max(a.version), 0) + 1 into v_version
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = v_type;

    insert into public.job_artifacts (job_id, artifact_type, producer, version, content, validation_issues)
    values (p_job_id, v_type, v_producer, v_version, p_content, v_issues)
    returning id into v_artifact_id;

    perform m417_internal.usage(p_job_id, v_producer, v_type);

    if jsonb_array_length(v_issues) > 0 then
        v_continue := m417_internal.open_revision(
            p_job_id, v_step,
            jsonb_build_object(
                'verdict', case v_type when 'SCRIPT' then 'REVISE_SCRIPT' else 'REVISE_SHOTS' end,
                'source', 'SYSTEM_VALIDATION',
                'issues', v_issues),
            'SYSTEM_VALIDATION');
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('artifact_id', v_artifact_id, 'version', v_version,
                                  'accepted', false, 'issues', v_issues);
    end if;

    -- A clean script or shot package closes the feedback that asked for
    -- it, and the count of failed format checks starts again.
    if v_type in ('SCRIPT', 'SHOT_PACKAGE') then
        update public.production_jobs
        set revision_feedback = null,
            validation_retry_count = 0
        where id = p_job_id;
    end if;
    if v_type = 'TOPIC_SELECTION' then
        update public.episodes
        set title = left(p_content ->> 'title', 200),
            concept = p_content ->> 'premise'
        where id = v_job.episode_id;
    end if;

    perform m417_internal.set_step(
        p_job_id, v_step + 1, 'ARTIFACT_SAVED',
        jsonb_build_object('artifact_type', v_type, 'version', v_version, 'artifact_id', v_artifact_id));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('artifact_id', v_artifact_id, 'version', v_version,
                              'accepted', true, 'issues', '[]'::jsonb);
end;
$function$;

-- ----- step 8 and step 33 -------------------------------------------
create or replace function public.record_policy_check(
    p_job_id uuid, p_gate_no integer, p_checker text, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_step integer;
    v_verdict text;
    v_retries integer;
begin
    if p_gate_no not in (1, 2) then
        raise exception 'INVALID_POLICY_GATE';
    end if;
    if upper(btrim(coalesce(p_checker, ''))) <> 'CLAUDE' then
        raise exception 'POLICY_CHECKER_NOT_AUTHORIZED: %', coalesce(p_checker, '(empty)');
    end if;
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'POLICY_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    v_verdict := upper(btrim(coalesce(p_result ->> 'verdict', '')));
    if v_verdict not in ('PASS', 'FAIL') then
        raise exception 'POLICY_VERDICT_INVALID: %', coalesce(p_result ->> 'verdict', '(empty)');
    end if;
    -- A finding of MEDIUM or HIGH severity fails the gate whatever the
    -- stated verdict.
    if jsonb_typeof(p_result -> 'findings') = 'array' and exists (
        select 1 from jsonb_array_elements(p_result -> 'findings') f
        where upper(coalesce(f ->> 'severity', '')) in ('MEDIUM', 'HIGH'))
    then
        v_verdict := 'FAIL';
    end if;

    v_step := case p_gate_no when 1 then 8 else 33 end;
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, v_step);

    insert into public.policy_checks (job_id, gate_no, checker, verdict, categories, result)
    values (p_job_id, p_gate_no, 'CLAUDE', v_verdict,
            case when jsonb_typeof(p_result -> 'categories') = 'array'
                 then p_result -> 'categories' else '[]'::jsonb end,
            p_result);
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'POLICY_GATE_' || p_gate_no);

    if v_verdict = 'PASS' then
        perform m417_internal.set_step(
            p_job_id, v_step + 1, 'POLICY_GATE_PASSED', jsonb_build_object('gate_no', p_gate_no));
    elsif p_gate_no = 1 then
        update public.production_jobs
        set topic_retry_count = topic_retry_count + 1,
            topic_feedback = coalesce(topic_feedback, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                'topic', m417_internal.artifact(p_job_id, 'TOPIC_SELECTION') -> 'title',
                'findings', p_result -> 'findings',
                'required_changes', p_result -> 'required_changes'))
        where id = p_job_id
        returning topic_retry_count into v_retries;
        if v_retries > m417_internal.num('max_topic_retries', 2) then
            -- Stopped at topic selection, so a resumed job picks a new topic
            -- instead of re-checking the rejected one.
            update public.production_jobs set current_step = 7 where id = p_job_id;
            perform m417_internal.block_job(p_job_id, 'POLICY_GATE_1_FAILED', p_result::text);
        else
            perform m417_internal.set_step(
                p_job_id, 7, 'TOPIC_REJECTED_BY_POLICY', jsonb_build_object('retry_no', v_retries));
        end if;
    else
        perform m417_internal.block_job(p_job_id, 'POLICY_GATE_2_FAILED', p_result::text);
    end if;

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('gate_no', p_gate_no, 'verdict', v_verdict);
end;
$function$;

-- ----- step 9 -------------------------------------------------------
create or replace function public.get_series_bible(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_bible jsonb;
begin
    v_job := m417_internal.lock_job(p_job_id);
    v_bible := m417_internal.series_bible(p_job_id);
    if jsonb_array_length(v_bible -> 'characters') = 0 then
        raise exception 'SERIES_HAS_NO_LOCKED_CHARACTERS';
    end if;
    if v_job.current_step = 9 then
        perform m417_internal.require_step(v_job, 9);
        perform m417_internal.set_step(p_job_id, 10, 'SERIES_BIBLE_LOADED');
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('series_bible_text', v_bible::text);
end;
$function$;

-- ----- step 13 ------------------------------------------------------
create or replace function public.route_revision(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_report jsonb;
    v_verdict text;
    v_ok boolean;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 13);
    v_report := m417_internal.artifact(p_job_id, 'PREQC_REPORT');
    if v_report is null then
        raise exception 'PREQC_REPORT_MISSING';
    end if;
    v_verdict := upper(btrim(v_report ->> 'verdict'));
    -- A PASS that still lists a MEDIUM or HIGH issue is not a pass.
    if v_verdict = 'PASS'
       and jsonb_typeof(v_report -> 'issues') = 'array'
       and exists (
           select 1 from jsonb_array_elements(v_report -> 'issues') i
           where upper(coalesce(i ->> 'severity', '')) in ('MEDIUM', 'HIGH'))
    then
        v_verdict := case when exists (
                select 1 from jsonb_array_elements(v_report -> 'issues') i
                where upper(coalesce(i ->> 'severity', '')) in ('MEDIUM', 'HIGH')
                  and upper(coalesce(i ->> 'target', '')) = 'SCRIPT')
            then 'REVISE_SCRIPT' else 'REVISE_SHOTS' end;
    end if;

    if v_verdict = 'PASS' then
        update public.production_jobs set revision_feedback = null where id = p_job_id;
        perform m417_internal.set_step(p_job_id, 14, 'PREQC_PASSED');
    elsif v_verdict = 'REVISE_SCRIPT' then
        v_ok := m417_internal.open_revision(p_job_id, 10, v_report, 'GEMINI_PREQC');
    else
        v_ok := m417_internal.open_revision(p_job_id, 11, v_report, 'GEMINI_PREQC');
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('verdict', v_verdict,
                              'next_step', (m417_internal.job_status(p_job_id) ->> 'step_no')::integer);
end;
$function$;

-- ----- step 14 ------------------------------------------------------
create or replace function public.record_final_director_decision(
    p_job_id uuid, p_actor text, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_decision text;
    v_version integer;
    v_decision_id uuid;
    v_feedback jsonb;
    v_ok boolean;
begin
    if upper(btrim(coalesce(p_actor, ''))) <> 'CLAUDE' then
        raise exception 'DIRECTOR_NOT_AUTHORIZED: %', coalesce(p_actor, '(empty)');
    end if;
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'DIRECTOR_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    v_decision := upper(btrim(coalesce(p_result ->> 'decision', '')));
    if v_decision not in ('APPROVE', 'REVISE_SCRIPT', 'REVISE_SHOTS', 'REJECT') then
        raise exception 'DIRECTOR_DECISION_INVALID: %', coalesce(p_result ->> 'decision', '(empty)');
    end if;

    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 14);

    -- An approval that contradicts the reviews is not accepted as one.
    if v_decision = 'APPROVE' then
        if upper(coalesce(m417_internal.artifact(p_job_id, 'PREQC_REPORT') ->> 'verdict', '')) <> 'PASS' then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_PREQC_PASS';
        end if;
        if not exists (
            select 1 from public.policy_checks pc
            where pc.job_id = p_job_id and pc.gate_no = 1 and pc.verdict = 'PASS')
        then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_POLICY_GATE_1';
        end if;
        if upper(coalesce(p_result ->> 'child_safety_status', 'PASS')) = 'FAIL'
           or coalesce(p_result ->> 'production_ready', 'true') = 'false'
        then
            raise exception 'DIRECTOR_APPROVAL_CONTRADICTS_ITS_OWN_FINDINGS';
        end if;
    end if;

    select e.production_version into v_version from public.episodes e where e.id = v_job.episode_id;

    insert into public.director_decisions (
        job_id, episode_id, production_version, stage, decision, actor, notes, result)
    values (
        p_job_id, v_job.episode_id, v_version, 'PRODUCTION', v_decision, 'CLAUDE',
        p_result ->> 'director_notes', p_result)
    returning id into v_decision_id;
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'DIRECTOR_DECISION');

    if v_decision = 'APPROVE' then
        update public.production_jobs
        set director_decision_id = v_decision_id, revision_feedback = null
        where id = p_job_id;
        perform m417_internal.set_step(
            p_job_id, 15, 'DIRECTOR_APPROVED', jsonb_build_object('decision_id', v_decision_id));
    elsif v_decision = 'REJECT' then
        update public.episodes set state = 'CANCELLED' where id = v_job.episode_id;
        update public.budgets set is_active = false
        where budget_type = 'EPISODE' and reference_id = v_job.episode_id;
        perform m417_internal.set_step(
            p_job_id, 14, 'DIRECTOR_REJECTED',
            jsonb_build_object('decision_id', v_decision_id, 'notes', p_result ->> 'director_notes'),
            'CANCELLED');
        perform m417_internal.event(
            'JOB_REJECTED_BY_DIRECTOR', 'WARNING', 'Head Director rejected the production package.',
            jsonb_build_object('job_id', p_job_id, 'decision_id', v_decision_id), v_job.episode_id);
    else
        v_feedback := jsonb_build_object(
            'verdict', v_decision,
            'source', 'HEAD_DIRECTOR',
            'director_notes', p_result -> 'director_notes',
            'issues', coalesce((
                select jsonb_agg(m417_internal.issue(
                    case v_decision when 'REVISE_SCRIPT' then 'SCRIPT' else 'SHOTS' end,
                    'director', c.value, c.value))
                from jsonb_array_elements_text(
                    case when jsonb_typeof(p_result -> 'required_changes') = 'array'
                         then p_result -> 'required_changes' else '[]'::jsonb end) c(value)), '[]'::jsonb));
        v_ok := m417_internal.open_revision(
            p_job_id, case v_decision when 'REVISE_SCRIPT' then 10 else 11 end,
            v_feedback, 'HEAD_DIRECTOR');
    end if;

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('decision', v_decision, 'decision_id', v_decision_id);
end;
$function$;

-- =====================================================================
-- 7. RPC: step 15 commit, S3 voice and music
-- =====================================================================

-- The prompt sent to the video model: the shot, then who is in it and
-- what the series looks like. Kept under the providers' length limits.
create or replace function m417_internal.compose_prompt(
    p_series_id uuid, p_shot jsonb, p_character_ids uuid[], p_location_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_parts text[] := array[]::text[];
    v_text text;
    v_n integer := coalesce(cardinality(p_character_ids), 0);
begin
    -- What happens comes first, the look of the series next, and the
    -- written character descriptions last: when the text has to be cut
    -- for a model that also receives reference images, those go first.
    v_parts := v_parts || left(btrim(coalesce(p_shot ->> 'video_prompt', '')), 900);
    if coalesce(btrim(p_shot ->> 'action'), '') <> '' then
        v_parts := v_parts || ('Action: ' || left(btrim(p_shot ->> 'action'), 250));
    end if;
    if coalesce(btrim(p_shot ->> 'acting'), '') <> '' then
        v_parts := v_parts || ('Acting: ' || left(btrim(p_shot ->> 'acting'), 200));
    end if;
    if coalesce(btrim(p_shot ->> 'camera'), '') <> '' then
        v_parts := v_parts || ('Camera: ' || left(btrim(p_shot ->> 'camera'), 150));
    end if;
    v_parts := v_parts || 'Vertical 9:16 framing. No on-screen text, subtitles, logos or watermarks.'::text;
    select left(coalesce(sb.visual_style, ''), 260) into v_text
    from public.style_bibles sb
    where sb.series_id = p_series_id and sb.status <> 'ARCHIVED'
    order by sb.version desc
    limit 1;
    if coalesce(v_text, '') <> '' then
        v_parts := v_parts || ('Style. ' || v_text);
    end if;
    select l.name || ': ' || left(coalesce(l.canonical_description, ''), 200) into v_text
    from public.locations l where l.id = p_location_id;
    if v_text is not null then
        v_parts := v_parts || ('Location. ' || v_text);
    end if;
    select string_agg(c.name || ': ' || left(coalesce(c.canonical_description, ''),
                                             case when v_n > 2 then 150 else 230 end),
                      ' ' order by c.character_code)
    into v_text
    from public.characters c
    where c.id = any (coalesce(p_character_ids, array[]::uuid[]));
    if v_text is not null then
        v_parts := v_parts || ('Characters. ' || v_text);
    end if;
    return left(regexp_replace(array_to_string(v_parts, ' '), '[[:space:]]+', ' ', 'g'), 2400);
end;
$function$;

create or replace function public.commit_production_package(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_episode public.episodes;
    v_decision public.director_decisions;
    v_script jsonb;
    v_pkg jsonb;
    v_shot_budget numeric;
    v_resolution text := m417_internal.txt('default_shot_resolution', '720p');
    v_voice_provider text := m417_internal.txt('voice_provider', 'fish_audio');
    v_profile public.production_creative_profiles;
    v_scene record;
    v_scene_ids jsonb := '{}'::jsonb;
    v_scene_locations jsonb := '{}'::jsonb;
    v_scene_id uuid;
    v_loc_id uuid;
    v_rec record;
    v_shot jsonb;
    v_idx integer := 0;
    v_shot_id uuid;
    v_spec_id uuid;
    v_first_shot_id uuid;
    v_char_ids uuid[];
    v_char_codes jsonb;
    v_asset_ids uuid[];
    v_asset_roles text[];
    v_asset_codes jsonb;
    v_asset record;
    v_lines jsonb;
    v_line record;
    v_char_id uuid;
    v_voice_id uuid;
    v_voice_language text;
    v_camera text;
    v_negative text;
    v_style_negative text;
    v_duration numeric;
    v_line_total integer := 0;
    v_manifest_id uuid;
    v_i integer;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 15);

    if m417_internal.flag('storyboard_required', true) then
        perform m417_internal.block_job(
            p_job_id, 'STORYBOARD_REQUIRED',
            'storyboard_required is on, but this pipeline has no storyboard step.');
        return m417_internal.job_status(p_job_id);
    end if;

    select d.* into v_decision
    from public.director_decisions d
    where d.id = v_job.director_decision_id
      and d.job_id = p_job_id
      and d.stage = 'PRODUCTION'
      and d.decision = 'APPROVE';
    if not found then
        raise exception 'DIRECTOR_APPROVAL_MISSING';
    end if;

    select e.* into v_episode from public.episodes e where e.id = v_job.episode_id for update;
    if v_episode.state <> 'PREPRODUCTION' then
        raise exception 'EPISODE_NOT_IN_PREPRODUCTION: %', v_episode.state;
    end if;
    if v_decision.production_version <> v_episode.production_version then
        raise exception 'DIRECTOR_APPROVAL_VERSION_STALE';
    end if;
    select p.* into v_profile
    from public.production_creative_profiles p where p.id = v_job.creative_profile_id;

    select a.content into v_script
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SCRIPT' and a.is_current
      and jsonb_array_length(a.validation_issues) = 0;
    select a.content into v_pkg
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SHOT_PACKAGE' and a.is_current
      and jsonb_array_length(a.validation_issues) = 0;
    if v_script is null or v_pkg is null then
        raise exception 'VALID_SCRIPT_AND_SHOT_PACKAGE_REQUIRED';
    end if;

    v_shot_budget := m417_internal.safe_numeric(v_job.request ->> 'shot_budget_usd');

    select array_to_string(array(
               select jsonb_array_elements_text(sb.negative_rules)), ', ')
    into v_style_negative
    from public.style_bibles sb
    where sb.series_id = v_job.series_id and sb.status <> 'ARCHIVED'
      and jsonb_typeof(sb.negative_rules) = 'array'
    order by sb.version desc
    limit 1;

    update public.episodes
    set title = left(coalesce(nullif(btrim(v_script ->> 'title'), ''), title), 200),
        concept = coalesce(nullif(btrim(v_script ->> 'logline'), ''), concept),
        director_approval_id = v_decision.id
    where id = v_episode.id;

    -- Scenes ---------------------------------------------------------
    for v_scene in
        select s.scene, s.idx
        from jsonb_array_elements(v_script -> 'scenes') with ordinality as s(scene, idx)
    loop
        v_loc_id := m417_internal.resolve_location(v_job.series_id, v_scene.scene ->> 'location');
        insert into public.scenes (
            episode_id, scene_code, scene_order, title, description, location_id,
            estimated_duration_seconds, state)
        values (
            v_episode.id, 'SC' || lpad(v_scene.idx::text, 2, '0'), v_scene.idx,
            left(v_scene.scene ->> 'action', 120), v_scene.scene ->> 'action', v_loc_id,
            m417_internal.safe_numeric(v_scene.scene ->> 'duration_seconds'), 'SCRIPTED')
        returning id into v_scene_id;
        v_scene_ids := v_scene_ids
            || jsonb_build_object(coalesce(v_scene.scene ->> 'scene_no', v_scene.idx::text), v_scene_id);
        if v_loc_id is not null then
            v_scene_locations := v_scene_locations
                || jsonb_build_object(coalesce(v_scene.scene ->> 'scene_no', v_scene.idx::text), v_loc_id);
        end if;
    end loop;

    -- Shots ----------------------------------------------------------
    for v_rec in
        select t.elem
        from jsonb_array_elements(v_pkg -> 'shots') with ordinality as t(elem, ord)
        order by coalesce(m417_internal.safe_numeric(t.elem ->> 'shot_no'), t.ord), t.ord
    loop
        v_shot := v_rec.elem;
        v_idx := v_idx + 1;
        v_scene_id := (v_scene_ids ->> coalesce(v_shot ->> 'scene_no', ''))::uuid;
        v_duration := m417_internal.safe_numeric(v_shot ->> 'duration_seconds');

        -- Who is in the shot: listed characters plus everyone who speaks.
        v_lines := coalesce((
            select jsonb_agg(m417_internal.script_line(v_script, v_shot ->> 'scene_no', n.line_no) order by n.ord)
            from jsonb_array_elements_text(
                case when jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array'
                     then v_shot -> 'dialogue_line_nos' else '[]'::jsonb end
            ) with ordinality as n(line_no, ord)), '[]'::jsonb);

        select coalesce(array_agg(distinct x.id), array[]::uuid[]) into v_char_ids
        from (
            select m417_internal.resolve_character(v_job.series_id, c.value) as id
            from jsonb_array_elements_text(
                case when jsonb_typeof(v_shot -> 'characters') = 'array'
                     then v_shot -> 'characters' else '[]'::jsonb end) c(value)
            union
            select m417_internal.resolve_character(v_job.series_id, l.value ->> 'character')
            from jsonb_array_elements(v_lines) l(value)
        ) x
        where x.id is not null;

        select coalesce(jsonb_agg(c.character_code order by c.character_code), '[]'::jsonb)
        into v_char_codes
        from public.characters c where c.id = any (v_char_ids);

        v_loc_id := coalesce(
            m417_internal.resolve_location(v_job.series_id, v_shot ->> 'location'),
            (v_scene_locations ->> coalesce(v_shot ->> 'scene_no', ''))::uuid);

        -- Canonical references: one per character, then the location
        -- master, at most three in total.
        v_asset_ids := array[]::uuid[];
        v_asset_roles := array[]::text[];
        for v_asset in
            select x.asset_id, x.role
            from (
                select (
                           select ar.id from public.asset_registry ar
                           where ar.character_id = c.id
                             and ar.asset_type = 'CHARACTER_REFERENCE'
                             and ar.status = 'LOCKED'
                           order by ar.version desc, ar.asset_code
                           limit 1) as asset_id,
                       'CHARACTER'::text as role, 1 as grp, c.character_code as ord
                from public.characters c
                where c.id = any (v_char_ids)
                union all
                select (
                           select ar.id from public.asset_registry ar
                           where ar.location_id = v_loc_id
                             and ar.asset_type = 'LOCATION_REFERENCE'
                             and ar.status = 'LOCKED'
                           order by (ar.metadata ->> 'asset_role' = 'MASTER') desc nulls last,
                                    ar.version desc, ar.asset_code
                           limit 1),
                       'LOCATION', 2, ''
            ) x
            where x.asset_id is not null
            order by x.grp, x.ord
            limit 3
        loop
            v_asset_ids := v_asset_ids || v_asset.asset_id;
            v_asset_roles := v_asset_roles || v_asset.role;
        end loop;
        select coalesce(jsonb_agg(ar.asset_code order by ar.asset_code), '[]'::jsonb)
        into v_asset_codes
        from public.asset_registry ar where ar.id = any (v_asset_ids);

        insert into public.shots (episode_id, shot_code, shot_order, state, maximum_budget, scene_id)
        values (v_episode.id, 'SH' || lpad(v_idx::text, 2, '0'), v_idx, 'PLANNED', v_shot_budget, v_scene_id)
        returning id into v_shot_id;
        if v_first_shot_id is null then
            v_first_shot_id := v_shot_id;
        end if;

        insert into public.budgets (budget_type, reference_id, currency, hard_limit, is_active)
        values ('SHOT', v_shot_id, 'USD', v_shot_budget, true);

        v_camera := lower(coalesce(v_shot ->> 'camera', ''));
        v_negative := left(btrim(concat_ws(', ',
            nullif(btrim(v_shot ->> 'negative_prompt'), ''),
            nullif(v_style_negative, ''),
            'text, subtitles, watermark, logo')), 900);

        insert into public.shot_specifications (
            shot_id, version, is_active, narrative_action, dialogue, emotion, shot_size,
            camera_movement, duration_seconds, generation_prompt, negative_prompt,
            aspect_ratio, fps, resolution, character_codes, required_asset_codes,
            continuity_notes, audio_required, voice_required, status)
        values (
            v_shot_id, 1, true,
            coalesce(nullif(btrim(v_shot ->> 'action'), ''), left(v_shot ->> 'video_prompt', 500)),
            nullif((select string_agg((l.value ->> 'character') || ': ' || (l.value ->> 'text'), ' / ')
                    from jsonb_array_elements(v_lines) l(value)), ''),
            nullif(btrim(v_shot ->> 'acting'), ''),
            case
                when v_camera ~ '(extreme close|close[- ]?up|closeup)' then 'CLOSE_UP'
                when v_camera ~ '(wide|establishing|long shot|full shot)' then 'WIDE'
                else 'MEDIUM'
            end,
            nullif(btrim(v_shot ->> 'camera'), ''),
            v_duration,
            m417_internal.compose_prompt(v_job.series_id, v_shot, v_char_ids, v_loc_id),
            v_negative,
            v_profile.aspect_ratio, 24, v_resolution, v_char_codes, v_asset_codes,
            nullif(btrim(v_shot ->> 'continuity_notes'), ''),
            false, jsonb_array_length(v_lines) > 0, 'DRAFT')
        returning id into v_spec_id;

        for v_i in 1 .. coalesce(array_length(v_asset_ids, 1), 0)
        loop
            insert into public.shot_reference_assets (
                shot_specification_id, asset_id, reference_role, reference_order, is_required)
            values (v_spec_id, v_asset_ids[v_i], v_asset_roles[v_i], v_i, true);
        end loop;

        -- Locked on the strength of the director decision.
        perform set_config('m417.director_lock', 'on', true);
        update public.shot_specifications set status = 'LOCKED' where id = v_spec_id;
        perform set_config('m417.director_lock', 'off', true);

        -- One planned voice take per dialogue line.
        for v_line in
            select l.value, l.ord
            from jsonb_array_elements(v_lines) with ordinality as l(value, ord)
        loop
            v_char_id := m417_internal.resolve_character(v_job.series_id, v_line.value ->> 'character');
            v_voice_id := m417_internal.character_voice(v_char_id);
            if v_char_id is null or v_voice_id is null then
                raise exception 'DIALOGUE_CHARACTER_HAS_NO_LOCKED_VOICE: %',
                    coalesce(v_line.value ->> 'character', '(empty)');
            end if;
            select vi.language into v_voice_language
            from public.voice_identities vi where vi.id = v_voice_id;
            insert into public.shot_audio_productions (
                shot_specification_id, character_id, voice_identity_id, audio_order,
                dialogue_text, language, provider, lip_sync_required, lip_sync_status,
                timing_metadata, status, take_no)
            values (
                v_spec_id, v_char_id, v_voice_id, v_line.ord,
                m417_internal.clean(v_line.value ->> 'text'), v_voice_language, v_voice_provider,
                false, 'NOT_REQUIRED',
                jsonb_build_object(
                    'scene_no', v_line.value ->> 'scene_no',
                    'line_no', v_line.value ->> 'line_no',
                    'emotion', v_line.value ->> 'emotion',
                    'estimated_seconds', v_line.value ->> 'estimated_seconds'),
                'PLANNED', 1);
            v_line_total := v_line_total + 1;
        end loop;

        -- No storyboard step: the storyboard stage is passed, not skipped
        -- silently, so the state machine and the event log both show it.
        update public.shots set state = 'STORYBOARD_PENDING' where id = v_shot_id;
        update public.shots set state = 'STORYBOARD_APPROVED' where id = v_shot_id;
    end loop;

    -- Manifest -------------------------------------------------------
    insert into public.production_manifests (
        episode_id, production_version, manifest_code, status, pilot_shot_id, director_approval_id)
    values (
        v_episode.id, v_episode.production_version,
        v_episode.content_id || '-M' || v_episode.production_version,
        'DRAFT', v_first_shot_id, v_decision.id)
    returning id into v_manifest_id;

    insert into public.production_manifest_shots (manifest_id, shot_id, shot_specification_id, manifest_order)
    select v_manifest_id, s.id, ss.id, s.shot_order
    from public.shots s
    join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
    where s.episode_id = v_episode.id
    order by s.shot_order;

    perform set_config('m417.director_lock', 'on', true);
    update public.production_manifests set status = 'LOCKED' where id = v_manifest_id;
    perform set_config('m417.director_lock', 'off', true);

    -- Episode: approved by the director decision, then authorised.
    update public.episodes set state = 'APPROVED' where id = v_episode.id;
    perform public.authorize_episode_production(v_episode.id);

    perform m417_internal.event(
        'PRODUCTION_PACKAGE_COMMITTED', 'INFO',
        'Production package committed on Head Director decision; storyboard stage waived.',
        jsonb_build_object('job_id', p_job_id, 'director_decision_id', v_decision.id,
                           'manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total,
                           'storyboard_required', false),
        v_episode.id);

    perform m417_internal.set_step(
        p_job_id, case when v_line_total > 0 then 16 else 19 end, 'PRODUCTION_PACKAGE_COMMITTED',
        jsonb_build_object('manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total));

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total);
end;
$function$;

-- ----- steps 16-18: voice -------------------------------------------
-- Closes the voice stage when every line has a canonical take.
create or replace function m417_internal.finish_voice_if_done(p_job_id uuid)
 returns boolean language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_open integer;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id for update;
    if v_job.state <> 'READY' or v_job.current_step not between 16 and 18 then
        return false;
    end if;
    -- A line is open while its newest take is not the canonical one.
    select count(*) into v_open
    from (
        select distinct on (sap.shot_specification_id, sap.audio_order) sap.is_canonical
        from public.shot_audio_productions sap
        join public.shot_specifications ss on ss.id = sap.shot_specification_id and ss.is_active = true
        join public.shots s on s.id = ss.shot_id
        where s.episode_id = v_job.episode_id
          and sap.status <> 'ARCHIVED'
        order by sap.shot_specification_id, sap.audio_order, sap.take_no desc
    ) x
    where x.is_canonical is not true;
    if v_open > 0 then
        return false;
    end if;
    update public.shots s
    set state = 'AUDIO_READY'
    where s.episode_id = v_job.episode_id
      and s.state = 'STORYBOARD_APPROVED'
      and exists (
          select 1
          from public.shot_specifications ss
          join public.shot_audio_productions sap on sap.shot_specification_id = ss.id
          where ss.shot_id = s.id and ss.is_active = true and sap.is_canonical = true);
    perform m417_internal.set_step(p_job_id, 19, 'VOICE_COMPLETE');
    return true;
end;
$function$;

-- Duration and size checks for one take; marks it canonical on PASS.
create or replace function m417_internal.judge_voice_take(p_take_id uuid, p_score numeric, p_forced_fail text)
 returns text language plpgsql security definer set search_path to ''
as $function$
declare
    v_take public.shot_audio_productions;
    v_spec_duration numeric;
    v_other numeric;
    v_reason text := p_forced_fail;
    v_size bigint;
begin
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id for update;
    if not found then
        raise exception 'VOICE_TAKE_NOT_FOUND';
    end if;
    if v_take.status = 'APPROVED' then
        return 'PASS';
    elsif v_take.status = 'REJECTED' then
        return 'FAIL';
    elsif v_take.status not in ('GENERATED', 'QC_PENDING') then
        raise exception 'VOICE_TAKE_NOT_READY_FOR_QC: %', v_take.status;
    end if;

    select ss.duration_seconds into v_spec_duration
    from public.shot_specifications ss where ss.id = v_take.shot_specification_id;
    select coalesce(sum(o.duration_seconds), 0) into v_other
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order <> v_take.audio_order
      and o.is_canonical = true;
    v_size := coalesce((v_take.timing_metadata ->> 'file_size_bytes')::bigint, 0);

    if v_reason is null and v_size < m417_internal.num('min_audio_bytes', 2000) then
        v_reason := 'AUDIO_FILE_TOO_SMALL';
    end if;
    if v_reason is null
       and v_other + v_take.duration_seconds
           > v_spec_duration + m417_internal.num('voice_duration_tolerance_seconds', 0.5)
    then
        v_reason := format('DIALOGUE_LONGER_THAN_SHOT: %s s of dialogue in a %s s shot',
                           round(v_other + v_take.duration_seconds, 2), v_spec_duration);
    end if;

    if v_reason is null then
        update public.shot_audio_productions
        set status = 'APPROVED', qc_status = 'PASS',
            qc_score = m417_internal.score100(p_score),
            reviewed_at = now(), is_canonical = true
        where id = p_take_id;
        return 'PASS';
    end if;
    update public.shot_audio_productions
    set status = 'REJECTED', qc_status = 'FAIL',
        qc_score = m417_internal.score100(p_score),
        qc_notes = v_reason, reviewed_at = now()
    where id = p_take_id;
    return 'FAIL';
end;
$function$;

-- What to do with a rejected take. A line that ran too long is not
-- simply repeated: the retake is asked to speak faster, and when even the
-- fastest allowed speed cannot fit it, no further take is paid for.
create or replace function m417_internal.voice_retake_plan(
    p_take_id uuid, out speed numeric, out fits boolean, out detail text)
 language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_take public.shot_audio_productions;
    v_spec_duration numeric;
    v_other numeric;
    v_available numeric;
    v_natural numeric;
    v_prev_speed numeric;
    v_max numeric := m417_internal.num('max_voice_speed', 1.3);
begin
    speed := 1; fits := true; detail := null;
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id;
    if not found or coalesce(v_take.qc_notes, '') not like 'DIALOGUE_LONGER_THAN_SHOT%' then
        return;
    end if;
    select ss.duration_seconds into v_spec_duration
    from public.shot_specifications ss where ss.id = v_take.shot_specification_id;
    select coalesce(sum(o.duration_seconds), 0) into v_other
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order <> v_take.audio_order
      and o.is_canonical = true;
    v_available := v_spec_duration + m417_internal.num('voice_duration_tolerance_seconds', 0.5) - v_other;
    v_prev_speed := round(greatest(coalesce(m417_internal.safe_numeric(v_take.timing_metadata ->> 'requested_speed'), 1), 1), 2);
    -- Length at normal speed: the newest take of this line recorded at speed 1.
    select o.duration_seconds into v_natural
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order = v_take.audio_order
      and o.duration_seconds is not null
      and coalesce(m417_internal.safe_numeric(o.timing_metadata ->> 'requested_speed'), 1) <= 1.001
    order by o.take_no desc
    limit 1;
    v_natural := round(coalesce(v_natural, v_take.duration_seconds * v_prev_speed), 2);
    v_available := round(v_available, 2);
    if v_available <= 0 then
        fits := false;
        detail := format('needs %s s at normal speed; the other lines already fill the %s s shot', v_natural, v_spec_duration);
        return;
    end if;
    speed := ceil(v_natural / v_available * 1.04 * 100) / 100;
    if speed > v_max then
        fits := false;
        detail := format('needs %s s at normal speed, %s s are available in the %s s shot; faster than %sx is not allowed',
                         v_natural, v_available, v_spec_duration, v_max);
    elsif v_prev_speed >= speed - 0.005 then
        -- Already asked for this speed and it still did not fit.
        fits := false;
        detail := format('still %s s after a retake at %sx; %s s are available in the %s s shot',
                         round(v_take.duration_seconds, 2), v_prev_speed, v_available, v_spec_duration);
    end if;
end;
$function$;

create or replace function public.list_voice_work(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_items jsonb := '[]'::jsonb;
    v_line record;
    v_max integer := m417_internal.num('max_voice_takes', 3)::integer;
    v_series_code text;
    v_content_id text;
    v_verdict text;
    v_plan record;
    v_speed numeric;
    v_next_take integer;
    v_waiting integer := 0;
    v_lease interval := make_interval(secs => m417_internal.num('voice_handout_seconds', 240));
begin
    v_job := m417_internal.lock_job(p_job_id);
    if m417_internal.flag('pipeline_enabled', false) is not true
       or v_job.state <> 'READY'
       or v_job.current_step not between 16 and 18
    then
        return m417_internal.job_status(p_job_id) || jsonb_build_object('items', '[]'::jsonb);
    end if;
    select s.series_code into v_series_code from public.series s where s.id = v_job.series_id;
    select e.content_id into v_content_id from public.episodes e where e.id = v_job.episode_id;

    for v_line in
        select distinct on (sap.shot_specification_id, sap.audio_order)
               sap.id, sap.status, sap.take_no, sap.dialogue_text, sap.audio_order,
               sap.shot_specification_id, s.shot_code, vi.provider_voice_id
        from public.shot_audio_productions sap
        join public.shot_specifications ss on ss.id = sap.shot_specification_id and ss.is_active = true
        join public.shots s on s.id = ss.shot_id
        join public.voice_identities vi on vi.id = sap.voice_identity_id
        where s.episode_id = v_job.episode_id
          and sap.status <> 'ARCHIVED'
        order by sap.shot_specification_id, sap.audio_order, sap.take_no desc
    loop
        -- A registered take whose QC never arrived is judged now.
        if v_line.status in ('GENERATED', 'QC_PENDING') then
            v_verdict := m417_internal.judge_voice_take(v_line.id, null, null);
            v_line.status := case v_verdict when 'PASS' then 'APPROVED' else 'REJECTED' end;
        end if;
        if v_line.status = 'PLANNED' or (v_line.status = 'REJECTED' and v_line.take_no < v_max) then
            v_next_take := case v_line.status when 'PLANNED' then v_line.take_no else v_line.take_no + 1 end;
            -- Already with another run: do not pay for the same take twice.
            if exists (
                select 1 from public.voice_handouts h
                where h.shot_specification_id = v_line.shot_specification_id
                  and h.audio_order = v_line.audio_order
                  and h.take_no = v_next_take
                  and h.handed_out_at > now() - v_lease)
            then
                v_waiting := v_waiting + 1;
                continue;
            end if;
            v_speed := 1;
            if v_line.status = 'REJECTED' then
                select * into v_plan from m417_internal.voice_retake_plan(v_line.id);
                if v_plan.fits is not true then
                    perform m417_internal.block_job(
                        p_job_id, 'DIALOGUE_DOES_NOT_FIT_SHOT',
                        format('%s line %s: %s', v_line.shot_code, v_line.audio_order, v_plan.detail));
                    return m417_internal.job_status(p_job_id) || jsonb_build_object('items', '[]'::jsonb);
                end if;
                v_speed := v_plan.speed;
            end if;
            v_items := v_items || jsonb_build_object(
                'line_id', v_line.id,
                'action', case v_line.status when 'PLANNED' then 'GENERATE' else 'RETAKE' end,
                'text', m417_internal.clean(v_line.dialogue_text),
                'voice_reference_id', v_line.provider_voice_id,
                'speed', v_speed,
                'storage_path', format('%s/%s/audio/%s_L%s_T%s_S%s_%s.mp3',
                    v_series_code, v_content_id, v_line.shot_code, v_line.audio_order,
                    v_next_take,
                    round(v_speed * 100)::integer,
                    m417_internal.rand_suffix()));
            insert into public.voice_handouts (shot_specification_id, audio_order, take_no, handed_out_at)
            values (v_line.shot_specification_id, v_line.audio_order, v_next_take, now())
            on conflict (shot_specification_id, audio_order)
            do update set take_no = excluded.take_no, handed_out_at = excluded.handed_out_at;
        elsif v_line.status = 'REJECTED' then
            perform m417_internal.block_job(
                p_job_id, 'VOICE_TAKE_LIMIT_REACHED',
                format('%s line %s failed %s takes.', v_line.shot_code, v_line.audio_order, v_line.take_no));
            return m417_internal.job_status(p_job_id) || jsonb_build_object('items', '[]'::jsonb);
        end if;
    end loop;

    if jsonb_array_length(v_items) = 0 then
        perform m417_internal.finish_voice_if_done(p_job_id);
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('items', v_items, 'count', jsonb_array_length(v_items), 'waiting', v_waiting);
end;
$function$;

create or replace function public.register_voice_take(
    p_line_id uuid, p_action text, p_storage_path text, p_mp3_bitrate_kbps integer default 128)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_line public.shot_audio_productions;
    v_action text := upper(btrim(coalesce(p_action, '')));
    v_job_id uuid;
    v_take_id uuid;
    v_take_no integer;
    v_size bigint;
    v_duration numeric;
    v_kbps integer := coalesce(nullif(p_mp3_bitrate_kbps, 0), 128);
    -- The speed the take was asked for travels in the file name (_S125_ = 1.25x).
    v_speed numeric := round(coalesce(
        m417_internal.safe_numeric(substring(p_storage_path from '_S([0-9]{2,3})_')) / 100, 1), 2);
begin
    if v_action not in ('GENERATE', 'RETAKE') then
        raise exception 'INVALID_VOICE_ACTION: %', coalesce(p_action, '(empty)');
    end if;
    if p_storage_path is null or btrim(p_storage_path) = '' then
        raise exception 'STORAGE_PATH_REQUIRED';
    end if;
    select t.* into v_line from public.shot_audio_productions t where t.id = p_line_id for update;
    if not found then
        raise exception 'VOICE_LINE_NOT_FOUND';
    end if;

    select j.id into v_job_id
    from public.shot_specifications ss
    join public.shots s on s.id = ss.shot_id
    join public.production_jobs j on j.episode_id = s.episode_id
    where ss.id = v_line.shot_specification_id;
    if v_job_id is null then
        raise exception 'VOICE_LINE_HAS_NO_JOB';
    end if;

    v_size := m417_internal.object_size(p_storage_path);
    if v_size is null or v_size <= 0 then
        raise exception 'VOICE_FILE_NOT_FOUND_IN_STORAGE: %', p_storage_path;
    end if;
    v_duration := round((v_size * 8)::numeric / (v_kbps * 1000), 3);

    if v_action = 'GENERATE' then
        if v_line.status <> 'PLANNED' then
            -- The same registration repeated.
            if v_line.storage_path = p_storage_path then
                return jsonb_build_object('take_id', v_line.id, 'take_no', v_line.take_no,
                                          'duration_seconds', v_line.duration_seconds, 'decision', 'ALREADY_REGISTERED');
            end if;
            raise exception 'VOICE_LINE_NOT_PLANNED: %', v_line.status;
        end if;
        v_take_id := v_line.id;
        v_take_no := v_line.take_no;
        update public.shot_audio_productions
        set storage_provider = 'SUPABASE_STORAGE',
            storage_path = p_storage_path,
            mime_type = 'audio/mpeg',
            duration_seconds = v_duration,
            status = 'QC_PENDING',
            timing_metadata = timing_metadata
                || jsonb_build_object('file_size_bytes', v_size, 'bitrate_kbps', v_kbps, 'requested_speed', v_speed)
        where id = v_take_id;
    else
        if v_line.status <> 'REJECTED' then
            raise exception 'RETAKE_REQUIRES_REJECTED_TAKE: %', v_line.status;
        end if;
        select max(t.take_no) + 1 into v_take_no
        from public.shot_audio_productions t
        where t.shot_specification_id = v_line.shot_specification_id
          and t.audio_order = v_line.audio_order;
        if v_take_no > m417_internal.num('max_voice_takes', 3) then
            raise exception 'VOICE_TAKE_LIMIT_REACHED';
        end if;
        insert into public.shot_audio_productions (
            shot_specification_id, character_id, voice_identity_id, audio_order, dialogue_text,
            language, provider, storage_provider, storage_path, mime_type, duration_seconds,
            lip_sync_required, lip_sync_status, timing_metadata, status, take_no)
        values (
            v_line.shot_specification_id, v_line.character_id, v_line.voice_identity_id,
            v_line.audio_order, v_line.dialogue_text, v_line.language, v_line.provider,
            'SUPABASE_STORAGE', p_storage_path, 'audio/mpeg', v_duration,
            v_line.lip_sync_required, v_line.lip_sync_status,
            (v_line.timing_metadata - 'file_size_bytes' - 'bitrate_kbps' - 'requested_speed')
                || jsonb_build_object('file_size_bytes', v_size, 'bitrate_kbps', v_kbps, 'requested_speed', v_speed),
            'QC_PENDING', v_take_no)
        returning id into v_take_id;
    end if;

    -- The line is back from the run it was handed to.
    delete from public.voice_handouts h
    where h.shot_specification_id = v_line.shot_specification_id
      and h.audio_order = v_line.audio_order;

    perform m417_internal.usage(v_job_id, 'FISH_AUDIO', 'VOICE_TAKE',
                                char_length(v_line.dialogue_text), 'character');
    update public.production_jobs set last_activity_at = now() where id = v_job_id;

    return jsonb_build_object('take_id', v_take_id, 'take_no', v_take_no,
                              'duration_seconds', v_duration, 'decision', 'REGISTERED');
end;
$function$;

create or replace function public.apply_voice_qc(
    p_take_id uuid, p_verdict text, p_score numeric default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job_id uuid;
    v_verdict text := upper(btrim(coalesce(p_verdict, '')));
    v_final text;
    v_take public.shot_audio_productions;
    v_shot_code text;
    v_plan record;
begin
    if v_verdict not in ('PASS', 'FAIL') then
        raise exception 'INVALID_VOICE_QC_VERDICT: %', coalesce(p_verdict, '(empty)');
    end if;
    select j.id, s.shot_code into v_job_id, v_shot_code
    from public.shot_audio_productions t
    join public.shot_specifications ss on ss.id = t.shot_specification_id
    join public.shots s on s.id = ss.shot_id
    join public.production_jobs j on j.episode_id = s.episode_id
    where t.id = p_take_id;
    if v_job_id is null then
        raise exception 'VOICE_TAKE_NOT_FOUND';
    end if;
    perform m417_internal.lock_job(v_job_id);

    v_final := m417_internal.judge_voice_take(
        p_take_id, p_score,
        case when v_verdict = 'FAIL' then 'REJECTED_BY_REVIEWER' else null end);
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id;

    if v_final = 'PASS' then
        perform m417_internal.finish_voice_if_done(v_job_id);
    elsif v_take.take_no >= m417_internal.num('max_voice_takes', 3) then
        perform m417_internal.block_job(
            v_job_id, 'VOICE_TAKE_LIMIT_REACHED',
            format('%s line %s: %s', v_shot_code, v_take.audio_order, coalesce(v_take.qc_notes, '')));
    else
        select * into v_plan from m417_internal.voice_retake_plan(p_take_id);
        if v_plan.fits is not true then
            perform m417_internal.block_job(
                v_job_id, 'DIALOGUE_DOES_NOT_FIT_SHOT',
                format('%s line %s: %s', v_shot_code, v_take.audio_order, v_plan.detail));
        end if;
    end if;

    return m417_internal.job_status(v_job_id)
        || jsonb_build_object('take_id', p_take_id, 'verdict', v_final,
                              'reason', coalesce(v_take.qc_notes, ''),
                              'duration_seconds', v_take.duration_seconds);
end;
$function$;

-- ----- step 20: music licences --------------------------------------
create or replace function public.check_music_licenses(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_plan jsonb;
    v_track jsonb;
    v_row public.music_tracks;
    v_accepted jsonb := '[]'::jsonb;
    v_rejected jsonb := '[]'::jsonb;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 20);
    v_plan := coalesce(m417_internal.artifact(p_job_id, 'MUSIC_SFX_PLAN'), '{"tracks": []}'::jsonb);
    delete from public.job_music_tracks where job_id = p_job_id;

    for v_track in
        select * from jsonb_array_elements(
            case when jsonb_typeof(v_plan -> 'tracks') = 'array' then v_plan -> 'tracks' else '[]'::jsonb end)
    loop
        select mt.* into v_row
        from public.music_tracks mt
        where upper(mt.track_code) = upper(btrim(coalesce(v_track ->> 'track_code', '')))
          and mt.is_active = true
          and mt.license_status = 'VERIFIED';
        if not found then
            -- Only licensed library tracks may be used; anything else is dropped.
            v_rejected := v_rejected || jsonb_build_object(
                'track_code', v_track ->> 'track_code', 'reason', 'NOT_IN_VERIFIED_LIBRARY');
            continue;
        end if;
        insert into public.job_music_tracks (job_id, track_id, role, start_seconds, end_seconds, volume)
        values (
            p_job_id, v_row.id, v_row.role,
            greatest(coalesce(m417_internal.safe_numeric(v_track ->> 'start_seconds'), 0), 0),
            m417_internal.safe_numeric(v_track ->> 'end_seconds'),
            least(greatest(coalesce(m417_internal.safe_numeric(v_track ->> 'volume'), 0.25), 0), 1));
        v_accepted := v_accepted || to_jsonb(v_row.track_code);
    end loop;

    perform m417_internal.set_step(
        p_job_id, 21, 'MUSIC_LICENSES_CHECKED',
        jsonb_build_object('accepted', v_accepted, 'rejected', v_rejected));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('accepted', v_accepted, 'rejected', v_rejected);
end;
$function$;

-- =====================================================================
-- 8. RPC: S4 video (steps 22-29)
-- =====================================================================

-- Which Make branch serves a provider: KLING or VEO. A provider can
-- name its branch in metadata.make_route.
create or replace function m417_internal.provider_route(p_provider_code text)
 returns text language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        (select upper(nullif(btrim(gp.metadata ->> 'make_route'), ''))
         from public.generation_providers gp
         where gp.provider_code = p_provider_code),
        case
            when upper(p_provider_code) like '%KLING%' or upper(p_provider_code) like '%PIAPI%' then 'KLING'
            when upper(p_provider_code) like '%VEO%' or upper(p_provider_code) like '%GOOGLE%'
              or upper(p_provider_code) like '%GEMINI%' then 'VEO'
            else upper(p_provider_code)
        end);
$function$;

create or replace function m417_internal.submit_url(p_provider_code text, p_model_code text)
 returns text language sql stable security definer set search_path to ''
as $function$
    select coalesce(
        (select nullif(btrim(gp.metadata ->> 'submit_url'), '')
         from public.generation_providers gp
         where gp.provider_code = p_provider_code),
        case m417_internal.provider_route(p_provider_code)
            when 'KLING' then 'https://api.piapi.ai/api/v1/task'
            when 'VEO' then 'https://generativelanguage.googleapis.com/v1beta/models/' || p_model_code || ':predictLongRunning'
        end);
$function$;

create or replace function m417_internal.poll_url(p_provider_code text, p_provider_job_id text)
 returns text language sql stable security definer set search_path to ''
as $function$
    select case m417_internal.provider_route(p_provider_code)
        when 'KLING' then 'https://api.piapi.ai/api/v1/task/' || p_provider_job_id
        when 'VEO' then 'https://generativelanguage.googleapis.com/v1beta/' || p_provider_job_id
    end;
$function$;

-- Reference images of a shot that a provider can fetch: the shot's
-- canonical references that have a public copy, in reference order.
-- Each element: {"n": 1, "role": "CHARACTER", "name": "Mia", "url": "https://..."}.
create or replace function m417_internal.shot_reference_images(p_spec_id uuid, p_limit integer)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select coalesce(jsonb_agg(jsonb_build_object(
               'n', x.n, 'role', x.reference_role, 'name', x.name, 'url', x.url) order by x.n), '[]'::jsonb)
    from (
        select row_number() over (order by sra.reference_order, ar.asset_code) as n,
               sra.reference_role,
               coalesce(c.name, l.name, ar.asset_code) as name,
               rtrim(m417_internal.txt('storage_base_url', ''), '/')
                   || '/object/public/' || v.bucket || '/' || v.object_path as url
        from public.shot_reference_assets sra
        join public.asset_registry ar on ar.id = sra.asset_id
        join public.video_reference_images v on v.asset_id = ar.id and v.is_active = true
        left join public.characters c on c.id = ar.character_id
        left join public.locations l on l.id = ar.location_id
        where sra.shot_specification_id = p_spec_id
          and sra.reference_role in ('CHARACTER', 'LOCATION')
          and m417_internal.txt('storage_base_url', '') <> ''
        order by sra.reference_order, ar.asset_code
        limit greatest(coalesce(p_limit, 4), 0)
    ) x;
$function$;

-- The complete request body for the provider. Make forwards it as is.
create or replace function m417_internal.build_provider_request(p_attempt_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_row record;
    v_route text;
    v_defaults jsonb;
    v_params jsonb;
    v_task text;
    v_refs jsonb;
    v_lead text;
    v_tail text;
    v_input jsonb;
    v_max integer;
begin
    select a.provider, a.model, gm.model_version, gm.capability_metadata,
           ss.id as spec_id, ss.generation_prompt, ss.negative_prompt, ss.aspect_ratio,
           ss.duration_seconds, ss.resolution
    into v_row
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    join public.generation_models gm on gm.id = grd.selected_model_id
    join public.shot_specifications ss on ss.id = grd.shot_specification_id
    where a.id = p_attempt_id;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    v_route := m417_internal.provider_route(v_row.provider);
    v_defaults := case when jsonb_typeof(v_row.capability_metadata -> 'request_defaults') = 'object'
                       then v_row.capability_metadata -> 'request_defaults' else '{}'::jsonb end;
    v_task := coalesce(v_row.capability_metadata ->> 'task_type', 'video_generation');

    if v_route = 'KLING' and v_task = 'omni_video_generation' then
        -- Kling Omni: reference images go in input.images and are named
        -- in the prompt as @image_1, @image_2 ... in list order. It has
        -- no negative_prompt field, so the short "Avoid" list is part of
        -- the prompt. The whole prompt stays inside 2500 characters.
        v_max := coalesce(nullif(v_row.capability_metadata ->> 'max_reference_images', '')::integer, 4);
        v_refs := m417_internal.shot_reference_images(v_row.spec_id, v_max);
        v_lead := '';
        if jsonb_array_length(v_refs) > 0 then
            select 'Reference images: '
                   || string_agg(
                          '@image_' || (r.value ->> 'n') || ' is '
                          || case when r.value ->> 'role' = 'LOCATION'
                                  then 'the location ' || (r.value ->> 'name')
                                  else r.value ->> 'name' end,
                          ', ' order by (r.value ->> 'n')::integer)
                   || '. A character reference image shows one single character, sometimes in more than one view.'
                   || ' Keep every character''s face, hair, skin tone, age and body proportions exactly as in their reference image,'
                   || ' and their outfit as in the reference unless the scene says otherwise.'
                   || ' Exactly one of each named character. One continuous shot, never a collage or a split screen. '
            into v_lead
            from jsonb_array_elements(v_refs) r(value);
        end if;
        v_tail := case when coalesce(btrim(v_row.negative_prompt), '') <> ''
                       then ' Avoid: ' || left(btrim(v_row.negative_prompt), 300) else '' end;
        v_input := jsonb_build_object(
            'prompt', v_lead
                      || left(v_row.generation_prompt, greatest(2500 - length(v_lead) - length(v_tail), 200))
                      || v_tail,
            'version', coalesce(v_row.model_version, '3.0'),
            'resolution', coalesce(v_row.capability_metadata ->> 'resolution', '720p'),
            'duration', v_row.duration_seconds::integer,
            'aspect_ratio', v_row.aspect_ratio,
            'enable_audio', false);
        if jsonb_array_length(v_refs) > 0 then
            v_input := v_input || jsonb_build_object(
                'images', (select jsonb_agg(r.value ->> 'url' order by (r.value ->> 'n')::integer)
                           from jsonb_array_elements(v_refs) r(value)));
        end if;
        return jsonb_build_object(
            'model', coalesce(v_row.capability_metadata ->> 'api_model', 'kling'),
            'task_type', v_task,
            'input', v_input || v_defaults)::text;
    elsif v_route = 'KLING' then
        return jsonb_build_object(
            'model', coalesce(v_row.capability_metadata ->> 'api_model', 'kling'),
            'task_type', v_task,
            'input', jsonb_build_object(
                'prompt', v_row.generation_prompt,
                'negative_prompt', coalesce(v_row.negative_prompt, ''),
                'aspect_ratio', v_row.aspect_ratio,
                'duration', v_row.duration_seconds::integer,
                'version', coalesce(v_row.model_version, '2.6'),
                'mode', coalesce(v_row.capability_metadata ->> 'mode', 'std'),
                'enable_audio', false) || v_defaults)::text;
    elsif v_route = 'VEO' then
        v_params := jsonb_build_object(
            'aspectRatio', v_row.aspect_ratio,
            'durationSeconds', v_row.duration_seconds::integer);
        if coalesce(btrim(v_row.negative_prompt), '') <> '' then
            v_params := v_params || jsonb_build_object('negativePrompt', v_row.negative_prompt);
        end if;
        if v_row.resolution in ('720p', '1080p') then
            v_params := v_params || jsonb_build_object('resolution', v_row.resolution);
        end if;
        return jsonb_build_object(
            'instances', jsonb_build_array(jsonb_build_object('prompt', v_row.generation_prompt)),
            'parameters', v_params || v_defaults)::text;
    end if;
    raise exception 'PROVIDER_ROUTE_NOT_SUPPORTED: % (%)', v_row.provider, v_route;
end;
$function$;

-- Health of the model behind an attempt, recorded from real traffic.
create or replace function m417_internal.note_model_health(
    p_attempt_id uuid, p_status text, p_reason text)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare
    v_model_id uuid;
begin
    select grd.selected_model_id into v_model_id
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    where a.id = p_attempt_id;
    if v_model_id is not null then
        perform public.record_generation_model_health(
            v_model_id, p_status, 'PROVIDER_RESPONSE', p_reason,
            null, null, null, null, jsonb_build_object('attempt_id', p_attempt_id));
    end if;
end;
$function$;

-- The single place that decides what the video stage needs next.
-- p_mutate = false only looks; p_mutate = true also performs the
-- database-only moves (time-outs, blocks, the advance to assembly).
create or replace function m417_internal.video_scan(p_mutate boolean)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_items jsonb := '[]'::jsonb;
    v_waiting integer := 0;
    v_gen boolean := m417_internal.flag('generation_enabled', false);
    v_stale interval := make_interval(mins => m417_internal.num('video_claim_stale_minutes', 5)::integer);
    v_poll_gap interval := make_interval(secs => m417_internal.num('video_poll_min_interval_seconds', 45));
    v_timeout interval := make_interval(mins => m417_internal.num('video_poll_timeout_minutes', 45)::integer);
    v_blank jsonb := jsonb_build_object(
        'action', '', 'job_id', '', 'shot_id', '', 'attempt_id', '', 'provider', '',
        'submit_url', '', 'provider_request_text', '', 'poll_url', '', 'download_url', '',
        'storage_path', '', 'qc_context_text', '', 'notify_chat_id', '', 'review_text', '',
        'storage_base_url', '');
    v_job record;
    v_shot record;
    v_att public.attempts;
    v_has_att boolean;
    v_out record;
    v_manifest_id uuid;
    v_pilot_id uuid;
    v_pilot_state text;
    v_blocked boolean;
    v_resets integer;
    v_open integer;
    v_locked integer;
    v_emits integer;
begin
    if m417_internal.flag('pipeline_enabled', false) is not true then
        return jsonb_build_object('items', v_items, 'waiting', 0);
    end if;

    -- An advance to assembly that Make has not confirmed is handed out again.
    for v_job in
        select j.id
        from public.production_jobs j
        where j.current_step = 30 and j.state = 'READY'
          and j.video_advanced_at is not null
          and j.video_advance_acked_at is null
    loop
        v_items := v_items || (v_blank || jsonb_build_object('action', 'ADVANCE', 'job_id', v_job.id));
    end loop;

    for v_job in
        select j.id, j.episode_id, e.content_id, e.production_version, s.series_code
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        join public.series s on s.id = j.series_id
        where j.current_step = 22 and j.state = 'READY'
        order by j.created_at
    loop
        select pm.id, pm.pilot_shot_id into v_manifest_id, v_pilot_id
        from public.production_manifests pm
        where pm.episode_id = v_job.episode_id
          and pm.production_version = v_job.production_version
          and pm.status = 'LOCKED';
        if not found then
            if p_mutate then
                perform m417_internal.block_job(v_job.id, 'LOCKED_MANIFEST_MISSING', null);
            end if;
            continue;
        end if;
        select s.state into v_pilot_state from public.shots s where s.id = v_pilot_id;
        v_blocked := false;

        for v_shot in
            select s.id, s.shot_code, s.state, ss.id as spec_id, ss.duration_seconds,
                   ss.narrative_action, ss.camera_movement, ss.dialogue, ss.continuity_notes,
                   ss.character_codes
            from public.production_manifest_shots pms
            join public.shots s on s.id = pms.shot_id
            join public.shot_specifications ss on ss.id = pms.shot_specification_id
            where pms.manifest_id = v_manifest_id
            order by pms.manifest_order
        loop
            exit when v_blocked;
            continue when v_shot.state in ('LOCKED', 'CANCELLED');

            select a.* into v_att
            from public.attempts a
            where a.shot_id = v_shot.id
            order by a.attempt_no desc
            limit 1;
            v_has_att := found;

            if v_shot.state = 'ESCALATED' then
                select go.id, go.storage_path, go.qc_notes, go.qc_score into v_out
                from public.generation_outputs go
                where go.shot_id = v_shot.id
                  and go.storage_path is not null and btrim(go.storage_path) <> ''
                order by go.created_at desc
                limit 1;
                if not found then
                    if p_mutate then
                        perform m417_internal.block_job(
                            v_job.id, 'SHOT_FAILED_WITHOUT_OUTPUT',
                            v_shot.shot_code || ': both attempts failed and there is no clip to review.');
                    end if;
                    v_blocked := true;
                elsif exists (
                    select 1 from public.approval_requests ar
                    where ar.scope_type = 'SHOT_ESCALATION'
                      and ar.scope_id = v_shot.id
                      and ar.status = 'PENDING'
                      and ar.expires_at > now())
                then
                    null;  -- waiting for the owner
                else
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'HUMAN_REVIEW',
                        'job_id', v_job.id,
                        'shot_id', v_shot.id,
                        'storage_path', v_out.storage_path,
                        'notify_chat_id', m417_internal.txt('notify_chat_id', ''),
                        'storage_base_url', m417_internal.txt('storage_base_url', ''),
                        'review_text', format('%s / %s. QC: %s (score %s)',
                            v_job.content_id, v_shot.shot_code,
                            coalesce(nullif(v_out.qc_notes, ''), '-'),
                            coalesce(v_out.qc_score::text, '-'))));
                end if;

            elsif v_has_att and v_att.status = 'BUDGET_RESERVED' then
                if v_att.submission_claimed_at is null then
                    if v_gen then
                        v_items := v_items || (v_blank || jsonb_build_object(
                            'action', 'SUBMIT',
                            'job_id', v_job.id,
                            'shot_id', v_shot.id,
                            'attempt_id', v_att.id,
                            'provider', m417_internal.provider_route(v_att.provider),
                            'submit_url', m417_internal.submit_url(v_att.provider, v_att.model),
                            'provider_request_text', m417_internal.build_provider_request(v_att.id)));
                    end if;
                elsif v_att.submission_claimed_at < now() - v_stale then
                    select count(*) into v_resets
                    from public.events ev
                    where ev.attempt_id = v_att.id
                      and ev.event_type = 'ATTEMPT_SUBMISSION_CLAIM_RESET';
                    if v_resets >= 2 then
                        -- Three submissions that never produced a job id:
                        -- stop paying attention to this attempt.
                        if p_mutate then
                            perform public.release_generation_attempt_v2(
                                v_att.id, 'FAILED', 'SUBMISSION_FAILED_REPEATEDLY',
                                'The provider never returned a job id after 3 submissions.');
                            perform m417_internal.note_model_health(
                                v_att.id, 'DEGRADED', 'Submission failed repeatedly without a job id.');
                        end if;
                        v_waiting := v_waiting + 1;
                    else
                        v_items := v_items || (v_blank || jsonb_build_object(
                            'action', 'RECONCILE',
                            'job_id', v_job.id,
                            'shot_id', v_shot.id,
                            'attempt_id', v_att.id,
                            'provider', m417_internal.provider_route(v_att.provider)));
                    end if;
                else
                    v_waiting := v_waiting + 1;
                end if;

            elsif v_has_att and v_att.status in ('SUBMITTED', 'GENERATING') then
                if coalesce(v_att.started_at, v_att.created_at) < now() - v_timeout then
                    if p_mutate then
                        perform public.release_generation_attempt_v2(
                            v_att.id, 'FAILED', 'PROVIDER_TIMEOUT',
                            'No result from the provider within the time limit. Reservation released; check the provider bill for this job id.');
                        perform m417_internal.event(
                            'VIDEO_PROVIDER_TIMEOUT', 'CRITICAL',
                            'A submitted video attempt timed out. The provider may still have charged for it.',
                            jsonb_build_object('provider', v_att.provider, 'provider_job_id', v_att.provider_job_id,
                                               'estimated_cost', v_att.estimated_cost),
                            v_job.episode_id, v_shot.id, v_att.id);
                        perform m417_internal.note_model_health(v_att.id, 'DEGRADED', 'Generation timed out.');
                    end if;
                    v_waiting := v_waiting + 1;
                elsif v_att.last_provider_check_at is null
                   or v_att.last_provider_check_at < now() - v_poll_gap then
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'POLL',
                        'job_id', v_job.id,
                        'shot_id', v_shot.id,
                        'attempt_id', v_att.id,
                        'provider', m417_internal.provider_route(v_att.provider),
                        'poll_url', m417_internal.poll_url(v_att.provider, v_att.provider_job_id)));
                else
                    v_waiting := v_waiting + 1;
                end if;

            elsif v_has_att and v_att.status = 'SUCCEEDED'
              and v_shot.state in ('GENERATED', 'QC_PENDING') then
                v_emits := 1;
                if p_mutate then
                    insert into public.video_action_state (attempt_id, output_emits)
                    values (v_att.id, 1)
                    on conflict (attempt_id) do update
                        set output_emits = public.video_action_state.output_emits + 1, updated_at = now()
                    returning output_emits into v_emits;
                end if;
                v_items := v_items || (v_blank || jsonb_build_object(
                    'action', 'PROCESS_OUTPUT',
                    'job_id', v_job.id,
                    'shot_id', v_shot.id,
                    'attempt_id', v_att.id,
                    'provider', m417_internal.provider_route(v_att.provider),
                    'download_url', coalesce(v_att.provider_result_url, ''),
                    'storage_path', format('%s/%s/video/%s_A%s_%s.mp4',
                        v_job.series_code, v_job.content_id, v_shot.shot_code, v_att.attempt_no,
                        m417_internal.rand_suffix()),
                    'qc_context_text', jsonb_build_object(
                        'shot', v_shot.shot_code,
                        'duration_seconds', v_shot.duration_seconds,
                        'action', v_shot.narrative_action,
                        'camera', v_shot.camera_movement,
                        'dialogue', case when m417_internal.flag('lip_sync_enforced', false)
                                         then v_shot.dialogue else null end,
                        'continuity_notes', v_shot.continuity_notes,
                        'characters', (
                            select coalesce(jsonb_agg(jsonb_build_object(
                                       'name', c.name, 'description', c.canonical_description)), '[]'::jsonb)
                            from public.characters c
                            where c.status = 'LOCKED'
                              and v_shot.character_codes ? c.character_code))::text));

            elsif v_shot.state in ('STORYBOARD_APPROVED', 'AUDIO_READY', 'RETRY_REQUIRED') then
                if not v_gen then
                    null;  -- paid generation is switched off
                elsif v_shot.id = v_pilot_id or v_pilot_state = 'LOCKED' then
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'ACQUIRE', 'job_id', v_job.id, 'shot_id', v_shot.id));
                elsif v_pilot_state = 'CANCELLED' then
                    if p_mutate then
                        perform m417_internal.block_job(
                            v_job.id, 'PILOT_SHOT_CANCELLED',
                            'The pilot shot was cancelled; the remaining shots cannot pass the pilot gate.');
                    end if;
                    v_blocked := true;
                elsif v_pilot_state <> 'ESCALATED' then
                    v_waiting := v_waiting + 1;  -- pilot still in progress
                end if;
            end if;
        end loop;

        continue when v_blocked;

        select count(*) filter (where s.state not in ('LOCKED', 'CANCELLED')),
               count(*) filter (where s.state = 'LOCKED')
        into v_open, v_locked
        from public.production_manifest_shots pms
        join public.shots s on s.id = pms.shot_id
        where pms.manifest_id = v_manifest_id;

        if v_open = 0 then
            if v_locked = 0 then
                if p_mutate then
                    perform m417_internal.block_job(v_job.id, 'ALL_SHOTS_CANCELLED', null);
                end if;
            else
                -- The step moves before Make is told, so the assembly
                -- scenario finds the job at step 30 when it is called.
                if p_mutate then
                    update public.episodes set state = 'ASSEMBLY' where id = v_job.episode_id;
                    perform m417_internal.set_step(
                        v_job.id, 30, 'VIDEO_COMPLETE', jsonb_build_object('locked_shots', v_locked));
                    update public.production_jobs set video_advanced_at = now() where id = v_job.id;
                end if;
                v_items := v_items || (v_blank || jsonb_build_object('action', 'ADVANCE', 'job_id', v_job.id));
            end if;
        end if;
    end loop;

    return jsonb_build_object('items', v_items, 'waiting', v_waiting);
end;
$function$;

create or replace function public.video_work_pending()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_last timestamptz;
    v_scan jsonb;
    v_pending boolean;
begin
    select d.last_tick_at into v_last from public.video_driver_state d where d.id = true for update;
    -- A second driver loop started while one is running stops here.
    if v_last is not null
       and v_last > now() - make_interval(secs => m417_internal.num('video_driver_min_interval_seconds', 90))
    then
        return jsonb_build_object('pending', false, 'reason', 'ANOTHER_DRIVER_ACTIVE');
    end if;
    v_scan := m417_internal.video_scan(false);
    v_pending := jsonb_array_length(v_scan -> 'items') > 0 or (v_scan ->> 'waiting')::integer > 0;
    if v_pending then
        update public.video_driver_state set last_tick_at = now() where id = true;
    end if;
    return jsonb_build_object(
        'pending', v_pending,
        'actions', jsonb_array_length(v_scan -> 'items'),
        'waiting', (v_scan ->> 'waiting')::integer,
        'generation_enabled', m417_internal.flag('generation_enabled', false));
end;
$function$;

create or replace function public.next_video_actions()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_scan jsonb;
begin
    v_scan := m417_internal.video_scan(true);
    return jsonb_build_object(
        'items', v_scan -> 'items',
        'count', jsonb_array_length(v_scan -> 'items'),
        'waiting', (v_scan ->> 'waiting')::integer);
end;
$function$;

-- ----- ACQUIRE ------------------------------------------------------
create or replace function public.prepare_shot_attempt(p_shot_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_shot public.shots;
    v_job public.production_jobs;
    v_last public.attempts;
    v_attempt_no integer;
    v_spec_id uuid;
    v_policy_id uuid;
    v_model record;
    v_max_age numeric := m417_internal.num('model_health_max_age_minutes', 60);
    v_cooldown numeric := m417_internal.num('health_probe_cooldown_minutes', 30);
    v_decision_id uuid;
    v_status text;
    v_reason text;
    v_acq record;
    v_error text;
    v_resting integer := 0;
    v_usable integer := 0;
begin
    select s.* into v_shot from public.shots s where s.id = p_shot_id;
    if not found then
        raise exception 'SHOT_NOT_FOUND';
    end if;
    select j.* into v_job
    from public.production_jobs j where j.episode_id = v_shot.episode_id for update;
    if not found then
        raise exception 'SHOT_HAS_NO_JOB';
    end if;
    if v_job.state <> 'READY' or v_job.current_step <> 22 then
        return jsonb_build_object('decision', 'JOB_NOT_IN_VIDEO_STAGE', 'step_no', v_job.current_step, 'state', v_job.state);
    end if;
    if not (m417_internal.flag('pipeline_enabled', false) and m417_internal.flag('generation_enabled', false)) then
        return jsonb_build_object('decision', 'GENERATION_DISABLED');
    end if;

    select a.* into v_last
    from public.attempts a where a.shot_id = p_shot_id
    order by a.attempt_no desc limit 1;
    if not found then
        if v_shot.state not in ('STORYBOARD_APPROVED', 'AUDIO_READY') then
            return jsonb_build_object('decision', 'SHOT_NOT_READY', 'shot_state', v_shot.state);
        end if;
        v_attempt_no := 1;
    elsif v_last.attempt_no = 1
      and v_last.status in ('FAILED', 'CANCELLED', 'SUCCEEDED')
      and v_shot.state = 'RETRY_REQUIRED' then
        v_attempt_no := 2;
    else
        return jsonb_build_object('decision', 'SHOT_NOT_READY', 'shot_state', v_shot.state,
                                  'attempt_no', v_last.attempt_no, 'attempt_status', v_last.status);
    end if;

    select ss.id into v_spec_id
    from public.shot_specifications ss
    where ss.shot_id = p_shot_id and ss.is_active = true and ss.status = 'LOCKED';
    if not found then
        raise exception 'ACTIVE_LOCKED_SPECIFICATION_NOT_FOUND';
    end if;

    select grp.id into v_policy_id
    from public.generation_routing_policies grp
    where grp.status = 'ACTIVE' and grp.approved_at is not null
    order by grp.approved_at desc
    limit 1;
    if not found then
        perform m417_internal.block_job(v_job.id, 'NO_ACTIVE_ROUTING_POLICY', null);
        return jsonb_build_object('decision', 'BLOCKED', 'reason', 'NO_ACTIVE_ROUTING_POLICY');
    end if;

    -- No scheduled health check runs. A model without a recent failure
    -- is tried: the submission itself is the probe, and a refused
    -- submission costs nothing. A model that just failed is left alone
    -- until the cooldown has passed.
    for v_model in
        select gpm.model_id, gmh.availability_status, gmh.last_checked_at
        from public.generation_policy_models gpm
        left join public.generation_model_health gmh on gmh.model_id = gpm.model_id
        where gpm.policy_id = v_policy_id and gpm.enabled = true
    loop
        if v_model.availability_status is null
           or v_model.availability_status = 'UNKNOWN'
           or v_model.last_checked_at is null
           or (v_model.availability_status = 'AVAILABLE'
               and v_model.last_checked_at < now() - make_interval(mins => (v_max_age * 0.8)::integer))
           or (v_model.availability_status in ('DEGRADED', 'UNAVAILABLE')
               and v_model.last_checked_at < now() - make_interval(mins => v_cooldown::integer))
        then
            perform public.record_generation_model_health(
                v_model.model_id, 'AVAILABLE', 'SYSTEM_RECOVERY',
                'ON_DEMAND_PROBE: no failure on record inside the cooldown; the next submission is the health probe.',
                null, null, null, null,
                jsonb_build_object('previous_status', v_model.availability_status,
                                   'previous_check', v_model.last_checked_at));
        end if;
    end loop;

    -- Models that failed inside the cooldown are resting. If none is
    -- left the shot simply waits: nothing is consumed, it is offered
    -- again, and it goes ahead once a cooldown has passed.
    select count(*) filter (where gmh.availability_status in ('DEGRADED', 'UNAVAILABLE')),
           count(*) filter (where gmh.availability_status = 'AVAILABLE')
    into v_resting, v_usable
    from public.generation_policy_models gpm
    join public.generation_model_health gmh on gmh.model_id = gpm.model_id
    where gpm.policy_id = v_policy_id and gpm.enabled = true;
    if v_resting > 0 and v_usable = 0 then
        return jsonb_build_object('decision', 'WAITING_FOR_MODEL_HEALTH', 'reason', 'ALL_MODELS_RESTING');
    end if;

    v_decision_id := public.create_generation_routing_decision(v_spec_id, v_policy_id, v_attempt_no);
    select grd.decision_status, grd.decision_reason into v_status, v_reason
    from public.generation_routing_decisions grd where grd.id = v_decision_id;

    if v_status in ('HEALTH_BLOCKED', 'NO_ELIGIBLE_MODEL') and v_resting > 0 then
        -- The usable models do not fit this shot and another one is
        -- resting: wait for it instead of stopping the episode.
        return jsonb_build_object('decision', 'WAITING_FOR_MODEL_HEALTH', 'reason', coalesce(v_reason, v_status));
    end if;
    if v_status <> 'SELECTED' then
        if v_attempt_no = 2 then
            -- No model left for the retry: a person decides.
            update public.shots set state = 'ESCALATED' where id = p_shot_id;
            perform m417_internal.event(
                'SHOT_ESCALATED_NO_RETRY_MODEL', 'ERROR',
                'No eligible model for attempt 2: ' || coalesce(v_reason, v_status),
                jsonb_build_object('routing_decision_id', v_decision_id, 'status', v_status, 'reason', v_reason),
                v_shot.episode_id, p_shot_id);
            return jsonb_build_object('decision', 'ESCALATED', 'reason', coalesce(v_reason, v_status));
        end if;
        perform m417_internal.block_job(
            v_job.id, 'NO_ELIGIBLE_VIDEO_MODEL',
            v_shot.shot_code || ': ' || v_status || ' / ' || coalesce(v_reason, ''));
        return jsonb_build_object('decision', 'BLOCKED', 'reason', coalesce(v_reason, v_status));
    end if;

    begin
        select * into v_acq
        from public.acquire_generation_attempt_v2(
            v_decision_id,
            'job:' || v_job.id || ':shot:' || p_shot_id || ':attempt:' || v_attempt_no);
    exception when others then
        v_error := sqlerrm;
    end;
    if v_error is not null then
        -- Budget, readiness or pilot gate said no. Nothing was reserved.
        perform m417_internal.block_job(
            v_job.id, 'VIDEO_ATTEMPT_REFUSED', v_shot.shot_code || ': ' || v_error);
        return jsonb_build_object('decision', 'BLOCKED', 'reason', v_error);
    end if;

    update public.production_jobs set last_activity_at = now() where id = v_job.id;
    return jsonb_build_object(
        'decision', v_acq.decision,
        'attempt_id', v_acq.attempt_id,
        'attempt_no', v_acq.attempt_no,
        'reserved_cost', v_acq.reserved_cost);
end;
$function$;

-- ----- SUBMIT -------------------------------------------------------
create or replace function public.record_attempt_submission(p_attempt_id uuid, p_provider_response jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_att public.attempts;
    v_route text;
    v_job_id text;
    v_p jsonb := coalesce(p_provider_response, '{}'::jsonb);
begin
    select a.* into v_att from public.attempts a where a.id = p_attempt_id for update;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    if v_att.status in ('SUBMITTED', 'GENERATING') then
        return jsonb_build_object('status', v_att.status, 'provider_job_id', v_att.provider_job_id, 'decision', 'ALREADY_RECORDED');
    elsif v_att.status <> 'BUDGET_RESERVED' then
        return jsonb_build_object('status', v_att.status, 'decision', 'ALREADY_FINALIZED');
    end if;

    v_route := m417_internal.provider_route(v_att.provider);
    if jsonb_typeof(v_p) = 'object' then
        if v_route = 'KLING' then
            if coalesce(v_p ->> 'code', '200') = '200'
               and lower(coalesce(v_p -> 'data' ->> 'status', '')) <> 'failed' then
                v_job_id := v_p -> 'data' ->> 'task_id';
            end if;
        elsif v_route = 'VEO' then
            if not (v_p ? 'error') then
                v_job_id := v_p ->> 'name';
            end if;
        else
            v_job_id := coalesce(v_p ->> 'id', v_p ->> 'task_id', v_p -> 'data' ->> 'task_id');
        end if;
    end if;

    if v_job_id is null or btrim(v_job_id) = '' then
        -- The provider answered but did not accept the job: nothing was
        -- generated, so the reservation is returned.
        perform public.release_generation_attempt_v2(
            p_attempt_id, 'FAILED', 'SUBMISSION_REJECTED', left(v_p::text, 1500));
        perform m417_internal.note_model_health(
            p_attempt_id, 'DEGRADED', 'Submission rejected: ' || left(v_p::text, 300));
        return jsonb_build_object('status', 'FAILED', 'decision', 'SUBMISSION_REJECTED',
                                  'provider_response', left(v_p::text, 500));
    end if;

    perform public.mark_attempt_submitted(p_attempt_id, v_job_id);
    perform m417_internal.note_model_health(p_attempt_id, 'AVAILABLE', 'Submission accepted by the provider.');
    return jsonb_build_object('status', 'SUBMITTED', 'provider_job_id', v_job_id, 'decision', 'RECORDED');
end;
$function$;

-- ----- POLL ---------------------------------------------------------
create or replace function public.record_provider_poll(p_attempt_id uuid, p_provider_response jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_att public.attempts;
    v_route text;
    v_p jsonb := coalesce(p_provider_response, '{}'::jsonb);
    v_state text := 'RUNNING';
    v_url text;
    v_error text;
    v_raw text;
begin
    select a.* into v_att from public.attempts a where a.id = p_attempt_id for update;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    if v_att.status not in ('SUBMITTED', 'GENERATING') then
        return jsonb_build_object('status', v_att.status, 'decision', 'NOT_POLLABLE');
    end if;
    update public.attempts
    set last_provider_check_at = now(), heartbeat_at = now()
    where id = p_attempt_id;

    v_route := m417_internal.provider_route(v_att.provider);
    if v_route = 'KLING' then
        v_raw := lower(coalesce(v_p -> 'data' ->> 'status', ''));
        if v_raw = 'completed' then
            v_state := 'DONE';
            v_url := coalesce(
                nullif(v_p -> 'data' -> 'output' ->> 'video_url', ''),
                nullif(v_p -> 'data' -> 'output' -> 'works' -> 0 -> 'video' ->> 'resource_without_watermark', ''),
                nullif(v_p -> 'data' -> 'output' -> 'works' -> 0 -> 'video' ->> 'resource', ''),
                nullif(v_p -> 'data' -> 'output' ->> 'video', ''));
        elsif v_raw = 'failed' then
            v_state := 'FAILED';
            v_error := left(coalesce(v_p -> 'data' -> 'error' ->> 'message', v_p -> 'data' ->> 'error', v_p ->> 'message', 'provider reported failure'), 1000);
        elsif v_raw = 'processing' then
            v_state := 'GENERATING';
        end if;
    elsif v_route = 'VEO' then
        if coalesce(v_p ->> 'done', 'false') = 'true' then
            if v_p ? 'error' then
                v_state := 'FAILED';
                v_error := left(coalesce(v_p -> 'error' ->> 'message', (v_p -> 'error')::text), 1000);
            else
                v_state := 'DONE';
                v_url := coalesce(
                    nullif(v_p -> 'response' -> 'generateVideoResponse' -> 'generatedSamples' -> 0 -> 'video' ->> 'uri', ''),
                    nullif(v_p -> 'response' -> 'generatedVideos' -> 0 -> 'video' ->> 'uri', ''),
                    nullif(v_p -> 'response' -> 'videos' -> 0 ->> 'uri', ''));
                if v_url is null then
                    v_error := 'No video in the result (content filter): '
                        || left(coalesce((v_p -> 'response')::text, ''), 600);
                end if;
            end if;
        else
            v_state := 'GENERATING';
        end if;
    else
        raise exception 'PROVIDER_ROUTE_NOT_SUPPORTED: %', v_att.provider;
    end if;

    if v_state = 'DONE' and v_url is null then
        v_state := 'FAILED';
        v_error := coalesce(v_error, 'Provider reported completion without a video URL.');
    end if;

    if v_state = 'GENERATING' then
        if v_att.status = 'SUBMITTED' then
            perform public.mark_attempt_generating(p_attempt_id);
        end if;
        return jsonb_build_object('status', 'RUNNING');
    elsif v_state = 'RUNNING' then
        return jsonb_build_object('status', 'RUNNING');
    elsif v_state = 'DONE' then
        update public.attempts set provider_result_url = v_url where id = p_attempt_id;
        -- Priced per second from verified pricing: the charge equals the reservation.
        perform public.settle_generation_attempt_v2(p_attempt_id, v_att.estimated_cost);
        perform m417_internal.note_model_health(p_attempt_id, 'AVAILABLE', 'Generation completed.');
        return jsonb_build_object('status', 'SUCCEEDED', 'download_url', v_url);
    end if;

    -- A generation the provider itself reports as failed is not billed.
    perform public.release_generation_attempt_v2(p_attempt_id, 'FAILED', 'PROVIDER_FAILED', v_error);
    return jsonb_build_object('status', 'FAILED', 'error', v_error);
end;
$function$;

-- ----- PROCESS_OUTPUT -----------------------------------------------
create or replace function public.register_generation_output(p_attempt_id uuid, p_storage_path text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_att public.attempts;
    v_out public.generation_outputs;
    v_size bigint;
    v_mime text;
    v_duration numeric;
    v_output_id uuid;
    v_reason text;
    v_job_id uuid;
begin
    if p_storage_path is null or btrim(p_storage_path) = '' then
        raise exception 'STORAGE_PATH_REQUIRED';
    end if;
    select a.* into v_att from public.attempts a where a.id = p_attempt_id for update;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    if v_att.status <> 'SUCCEEDED' then
        raise exception 'ATTEMPT_NOT_SUCCEEDED: %', v_att.status;
    end if;

    select go.* into v_out
    from public.generation_outputs go
    where go.attempt_id = p_attempt_id and go.output_no = 1
    for update;
    if found and v_out.qc_status in ('PASS', 'FAIL') then
        return jsonb_build_object('output_id', v_out.id, 'shot_id', v_out.shot_id,
                                  'technical_qc', 'ALREADY_REVIEWED', 'qc_status', v_out.qc_status);
    end if;

    select (o.metadata ->> 'size')::bigint, o.metadata ->> 'mimetype' into v_size, v_mime
    from storage.objects o
    where o.bucket_id = m417_internal.txt('storage_bucket', 'production-assets')
      and o.name = p_storage_path
    limit 1;
    if v_size is null then
        raise exception 'OUTPUT_FILE_NOT_FOUND_IN_STORAGE: %', p_storage_path;
    end if;

    select ss.duration_seconds into v_duration
    from public.generation_routing_decisions grd
    join public.shot_specifications ss on ss.id = grd.shot_specification_id
    where grd.id = v_att.routing_decision_id;

    if v_out.id is null then
        insert into public.generation_outputs (
            attempt_id, shot_id, output_no, storage_provider, storage_path, source_url,
            mime_type, duration_seconds, file_size_bytes, status)
        values (
            p_attempt_id, v_att.shot_id, 1, 'SUPABASE_STORAGE', p_storage_path, v_att.provider_result_url,
            coalesce(v_mime, 'video/mp4'), v_duration, v_size, 'AVAILABLE')
        returning id into v_output_id;
    else
        v_output_id := v_out.id;
        update public.generation_outputs
        set storage_path = p_storage_path,
            file_size_bytes = v_size,
            mime_type = coalesce(v_mime, mime_type)
        where id = v_output_id;
    end if;

    -- Technical QC: what can be known from the stored file itself.
    if v_size < m417_internal.num('min_video_bytes', 20000) then
        v_reason := 'FILE_TOO_SMALL: ' || v_size || ' bytes';
    elsif v_mime is not null and v_mime not like 'video/%' and v_mime <> 'application/octet-stream' then
        v_reason := 'NOT_A_VIDEO: ' || v_mime;
    end if;

    select j.id into v_job_id
    from public.shots s join public.production_jobs j on j.episode_id = s.episode_id
    where s.id = v_att.shot_id;
    update public.production_jobs set last_activity_at = now() where id = v_job_id;

    if v_reason is not null then
        perform public.apply_shot_qc_decision(
            v_output_id, 'FAIL', 0, 'TECHNICAL_QC: ' || v_reason,
            jsonb_build_object('technical_qc', 'FAIL', 'reason', v_reason));
        return jsonb_build_object('output_id', v_output_id, 'shot_id', v_att.shot_id,
                                  'technical_qc', 'FAIL', 'reason', v_reason);
    end if;
    return jsonb_build_object('output_id', v_output_id, 'shot_id', v_att.shot_id, 'technical_qc', 'PASS');
end;
$function$;

create or replace function public.apply_visual_qc(p_output_id uuid, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_out public.generation_outputs;
    v_verdict text;
    v_score numeric;
    v_notes text;
    v_forced text;
    v_res record;
    v_job_id uuid;
begin
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'QC_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    select go.* into v_out from public.generation_outputs go where go.id = p_output_id;
    if not found then
        raise exception 'GENERATION_OUTPUT_NOT_FOUND';
    end if;
    if v_out.qc_status in ('PASS', 'FAIL') then
        return jsonb_build_object('output_id', p_output_id, 'shot_id', v_out.shot_id,
                                  'qc_status', v_out.qc_status, 'decision', 'ALREADY_REVIEWED');
    end if;
    v_verdict := upper(btrim(coalesce(p_result ->> 'verdict', '')));
    if v_verdict not in ('PASS', 'FAIL') then
        raise exception 'QC_VERDICT_INVALID: %', coalesce(p_result ->> 'verdict', '(empty)');
    end if;
    v_score := m417_internal.score100(m417_internal.safe_numeric(p_result ->> 'score'));
    v_notes := left(coalesce(p_result ->> 'notes', ''), 2000);

    -- No lip-sync is generated in this version: a clip that fails on
    -- lip-sync alone is judged on everything else.
    if v_verdict = 'FAIL'
       and m417_internal.flag('lip_sync_enforced', false) is not true
       and m417_internal.only_lip_sync_failed(p_result -> 'details')
       and v_score >= m417_internal.num('visual_qc_min_score', 70)
    then
        v_verdict := 'PASS';
        v_notes := left('FAIL on lip-sync only; lip-sync is not enforced. ' || v_notes, 2000);
    end if;

    -- A PASS is only accepted when the details agree with it.
    if v_verdict = 'PASS' then
        if upper(coalesce(p_result -> 'details' ->> 'child_safety', 'PASS')) = 'FAIL' then
            v_forced := 'child_safety FAIL';
        elsif upper(coalesce(p_result -> 'details' ->> 'character_identity', 'PASS')) = 'FAIL' then
            v_forced := 'character_identity FAIL';
        elsif upper(coalesce(p_result -> 'details' ->> 'anatomy', 'PASS')) = 'FAIL' then
            v_forced := 'anatomy FAIL';
        elsif v_score is null or v_score < m417_internal.num('visual_qc_min_score', 70) then
            v_forced := 'score ' || coalesce(v_score::text, 'missing') || ' below minimum';
        end if;
        if v_forced is not null then
            v_verdict := 'FAIL';
            v_notes := left('PASS overruled: ' || v_forced || '. ' || v_notes, 2000);
        end if;
    end if;

    select * into v_res
    from public.apply_shot_qc_decision(p_output_id, v_verdict, v_score, v_notes, p_result);

    select j.id into v_job_id
    from public.shots s join public.production_jobs j on j.episode_id = s.episode_id
    where s.id = v_out.shot_id;
    perform m417_internal.usage(v_job_id, 'GEMINI', 'VISUAL_QC');
    update public.production_jobs set last_activity_at = now() where id = v_job_id;

    return jsonb_build_object(
        'output_id', p_output_id, 'shot_id', v_res.shot_id, 'qc_status', v_res.qc_status,
        'shot_state', v_res.shot_state, 'decision', v_res.decision, 'score', v_score);
end;
$function$;

-- ----- ADVANCE ------------------------------------------------------
create or replace function public.ack_video_advance(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.video_advanced_at is null then
        return m417_internal.job_status(p_job_id) || jsonb_build_object('acknowledged', false);
    end if;
    update public.production_jobs
    set video_advance_acked_at = coalesce(video_advance_acked_at, now())
    where id = p_job_id;
    return m417_internal.job_status(p_job_id) || jsonb_build_object('acknowledged', true);
end;
$function$;

-- =====================================================================
-- 9. RPC: S6 assembly (30-34), S7 packaging (35-38), approval, S8 publish (39)
-- =====================================================================

-- ----- step 30 ------------------------------------------------------
create or replace function public.select_final_audio_track(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_tracks jsonb;
    v_voice integer;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 30);

    -- A licence withdrawn since step 20 takes the track out of the edit.
    delete from public.job_music_tracks jmt
    using public.music_tracks mt
    where jmt.job_id = p_job_id
      and mt.id = jmt.track_id
      and (mt.license_status <> 'VERIFIED' or mt.is_active is not true);

    select coalesce(jsonb_agg(jsonb_build_object(
               'track_code', mt.track_code, 'role', jmt.role, 'start_seconds', jmt.start_seconds,
               'end_seconds', jmt.end_seconds, 'volume', jmt.volume) order by jmt.start_seconds), '[]'::jsonb)
    into v_tracks
    from public.job_music_tracks jmt
    join public.music_tracks mt on mt.id = jmt.track_id
    where jmt.job_id = p_job_id;

    select count(*) into v_voice
    from public.shot_audio_productions sap
    join public.shot_specifications ss on ss.id = sap.shot_specification_id and ss.is_active = true
    join public.shots s on s.id = ss.shot_id
    where s.episode_id = v_job.episode_id and s.state = 'LOCKED' and sap.is_canonical = true;

    perform m417_internal.set_step(
        p_job_id, 31, 'AUDIO_SELECTED', jsonb_build_object('tracks', v_tracks, 'voice_lines', v_voice));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('tracks', v_tracks, 'voice_lines', v_voice);
end;
$function$;

-- ----- steps 31-32: render ------------------------------------------
-- Everything the edit is made of, in order, with its storage path.
create or replace function m417_internal.edit_list(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    with job as (
        select j.episode_id from public.production_jobs j where j.id = p_job_id
    ),
    shots as (
        select s.id, s.shot_order, s.shot_code, ss.id as spec_id, ss.duration_seconds,
               go.storage_path,
               coalesce(sum(ss.duration_seconds) over (order by s.shot_order
                   rows between unbounded preceding and 1 preceding), 0) as start_at
        from job
        join public.shots s on s.episode_id = job.episode_id and s.state = 'LOCKED'
        join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
        join public.generation_outputs go on go.shot_id = s.id and go.is_canonical = true
    ),
    voices as (
        select sh.shot_order, sap.audio_order, sap.storage_path, sap.duration_seconds,
               sh.start_at + 0.15
                 + coalesce(sum(sap.duration_seconds + 0.1) over (
                       partition by sh.id order by sap.audio_order
                       rows between unbounded preceding and 1 preceding), 0) as start_at
        from shots sh
        join public.shot_audio_productions sap
          on sap.shot_specification_id = sh.spec_id and sap.is_canonical = true
    ),
    music as (
        select mt.track_code, jmt.role, mt.storage_path, jmt.start_seconds, jmt.end_seconds, jmt.volume
        from public.job_music_tracks jmt
        join public.music_tracks mt on mt.id = jmt.track_id
        where jmt.job_id = p_job_id
    )
    select jsonb_build_object(
        'shots', coalesce((select jsonb_agg(jsonb_build_object(
                     'shot_code', shot_code, 'path', storage_path, 'start', start_at,
                     'length', duration_seconds) order by shot_order) from shots), '[]'::jsonb),
        'voices', coalesce((select jsonb_agg(jsonb_build_object(
                     'path', storage_path, 'start', round(start_at, 3), 'length', duration_seconds)
                     order by shot_order, audio_order) from voices), '[]'::jsonb),
        'music', coalesce((select jsonb_agg(jsonb_build_object(
                     'track_code', track_code, 'role', role, 'path', storage_path,
                     'start', start_seconds, 'end', end_seconds, 'volume', volume)
                     order by start_seconds) from music), '[]'::jsonb),
        'total_seconds', coalesce((select sum(duration_seconds) from shots), 0));
$function$;

create or replace function public.begin_assembly(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_render public.renders;
    v_count integer;
    v_edit jsonb;
    v_paths jsonb;
    v_blank jsonb := jsonb_build_object(
        'phase', '', 'render_id', '', 'sign_request_text', '', 'shotstack_render_id', '');
begin
    v_job := m417_internal.lock_job(p_job_id);
    if m417_internal.flag('pipeline_enabled', false) is not true then
        raise exception 'PIPELINE_DISABLED';
    end if;
    if v_job.state <> 'READY' or v_job.current_step not between 31 and 32 then
        raise exception 'STEP_MISMATCH: job is at step % (%), this call belongs to steps 31-32',
            v_job.current_step, v_job.state;
    end if;

    select r.* into v_render
    from public.renders r where r.job_id = p_job_id
    order by r.render_no desc limit 1;

    -- A render already with Shotstack (or finished there) is followed up.
    if found and v_render.status in ('SUBMITTED', 'RENDERING', 'DONE', 'STORED') then
        return v_blank || jsonb_build_object(
            'phase', 'POLL', 'render_id', v_render.id,
            'shotstack_render_id', coalesce(v_render.shotstack_render_id, ''));
    end if;

    if not found or v_render.status in ('FAILED', 'QC_FAIL', 'QC_PASS') then
        select count(*) into v_count from public.renders r where r.job_id = p_job_id;
        if v_count >= m417_internal.num('max_renders', 2) then
            perform m417_internal.block_job(
                p_job_id, 'RENDER_LIMIT_REACHED',
                'Last render: ' || coalesce(v_render.status, '-') || ' ' || coalesce(v_render.error, ''));
            return v_blank || jsonb_build_object('phase', 'BLOCKED');
        end if;
        insert into public.renders (job_id, episode_id, render_no, status)
        values (p_job_id, v_job.episode_id, v_count + 1, 'CREATED')
        returning * into v_render;
    end if;

    v_edit := m417_internal.edit_list(p_job_id);
    if jsonb_array_length(v_edit -> 'shots') = 0 then
        raise exception 'NO_LOCKED_SHOTS_TO_ASSEMBLE';
    end if;
    select jsonb_agg(distinct x.path) into v_paths
    from (
        select e ->> 'path' as path from jsonb_array_elements(v_edit -> 'shots') e
        union all
        select e ->> 'path' from jsonb_array_elements(v_edit -> 'voices') e
        union all
        select e ->> 'path' from jsonb_array_elements(v_edit -> 'music') e
    ) x
    where x.path is not null and btrim(x.path) <> '';

    return v_blank || jsonb_build_object(
        'phase', 'START',
        'render_id', v_render.id,
        'sign_request_text', jsonb_build_object(
            'expiresIn', m417_internal.num('signed_url_ttl_seconds', 86400)::integer,
            'paths', v_paths)::text);
end;
$function$;

create or replace function public.create_render(p_job_id uuid, p_signed_urls jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_render public.renders;
    v_base text := rtrim(m417_internal.txt('storage_base_url', ''), '/');
    v_urls jsonb := '{}'::jsonb;
    v_item jsonb;
    v_edit jsonb;
    v_clip jsonb;
    v_video jsonb := '[]'::jsonb;
    v_voice jsonb := '[]'::jsonb;
    v_sfx jsonb := '[]'::jsonb;
    v_soundtrack jsonb;
    v_tracks jsonb := '[]'::jsonb;
    v_timeline jsonb;
    v_request jsonb;
    v_url text;
    v_total numeric;
begin
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.state <> 'READY' or v_job.current_step not between 31 and 32 then
        raise exception 'STEP_MISMATCH: job is at step % (%)', v_job.current_step, v_job.state;
    end if;
    if v_base = '' then
        raise exception 'STORAGE_BASE_URL_NOT_SET: set system_text_settings.storage_base_url';
    end if;
    select r.* into v_render
    from public.renders r where r.job_id = p_job_id and r.status = 'CREATED'
    order by r.render_no desc limit 1
    for update;
    if not found then
        raise exception 'NO_RENDER_WAITING_FOR_A_TIMELINE';
    end if;
    if p_signed_urls is null or jsonb_typeof(p_signed_urls) <> 'array' then
        raise exception 'SIGNED_URLS_MUST_BE_ARRAY';
    end if;

    for v_item in select * from jsonb_array_elements(p_signed_urls)
    loop
        v_url := coalesce(v_item ->> 'signedURL', v_item ->> 'signedUrl');
        if v_url is not null and coalesce(v_item ->> 'error', '') = '' then
            v_urls := v_urls || jsonb_build_object(
                v_item ->> 'path',
                case when v_url like 'http%' then v_url
                     else v_base || case when v_url like '/%' then v_url else '/' || v_url end end);
        end if;
    end loop;

    v_edit := m417_internal.edit_list(p_job_id);
    v_total := (v_edit ->> 'total_seconds')::numeric;

    for v_clip in select * from jsonb_array_elements(v_edit -> 'shots')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        v_video := v_video || jsonb_build_object(
            'asset', jsonb_build_object('type', 'video', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 0),
            'start', (v_clip ->> 'start')::numeric,
            'length', (v_clip ->> 'length')::numeric,
            'fit', 'cover');
    end loop;
    for v_clip in select * from jsonb_array_elements(v_edit -> 'voices')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        v_voice := v_voice || jsonb_build_object(
            'asset', jsonb_build_object('type', 'audio', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 1),
            'start', (v_clip ->> 'start')::numeric,
            'length', (v_clip ->> 'length')::numeric);
    end loop;
    for v_clip in select * from jsonb_array_elements(v_edit -> 'music')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        if v_clip ->> 'role' = 'MUSIC' and v_soundtrack is null then
            v_soundtrack := jsonb_build_object(
                'src', v_urls ->> (v_clip ->> 'path'),
                'effect', 'fadeOut',
                'volume', (v_clip ->> 'volume')::numeric);
        else
            v_sfx := v_sfx || jsonb_build_object(
                'asset', jsonb_build_object('type', 'audio', 'src', v_urls ->> (v_clip ->> 'path'),
                                            'volume', (v_clip ->> 'volume')::numeric),
                'start', least((v_clip ->> 'start')::numeric, greatest(v_total - 0.5, 0)),
                'length', greatest(least(coalesce((v_clip ->> 'end')::numeric, v_total), v_total)
                                   - least((v_clip ->> 'start')::numeric, greatest(v_total - 0.5, 0)), 0.5));
        end if;
    end loop;

    -- Shotstack draws the first track on top; audio order does not matter.
    if jsonb_array_length(v_voice) > 0 then
        v_tracks := v_tracks || jsonb_build_object('clips', v_voice);
    end if;
    if jsonb_array_length(v_sfx) > 0 then
        v_tracks := v_tracks || jsonb_build_object('clips', v_sfx);
    end if;
    v_tracks := v_tracks || jsonb_build_object('clips', v_video);

    v_timeline := jsonb_build_object('background', '#000000', 'tracks', v_tracks);
    if v_soundtrack is not null then
        v_timeline := v_timeline || jsonb_build_object('soundtrack', v_soundtrack);
    end if;
    v_request := jsonb_build_object(
        'timeline', v_timeline,
        'output', jsonb_build_object(
            'format', 'mp4',
            'aspectRatio', '9:16',
            'resolution', m417_internal.txt('render_resolution', 'hd')));

    update public.renders
    set request = v_request, updated_at = now()
    where id = v_render.id;
    update public.production_jobs set last_activity_at = now() where id = p_job_id;

    return jsonb_build_object(
        'render_id', v_render.id,
        'shotstack_request_text', v_request::text,
        'total_seconds', v_total);
end;
$function$;

create or replace function public.mark_render_submitted(p_render_id uuid, p_shotstack_render_id text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_render public.renders;
begin
    if p_shotstack_render_id is null or btrim(p_shotstack_render_id) = '' then
        raise exception 'SHOTSTACK_RENDER_ID_REQUIRED';
    end if;
    select r.* into v_render from public.renders r where r.id = p_render_id for update;
    if not found then
        raise exception 'RENDER_NOT_FOUND';
    end if;
    if v_render.status = 'CREATED' then
        update public.renders
        set status = 'SUBMITTED', shotstack_render_id = btrim(p_shotstack_render_id),
            submitted_at = now(), updated_at = now()
        where id = p_render_id;
        perform m417_internal.usage(v_render.job_id, 'SHOTSTACK', 'RENDER');
    elsif v_render.shotstack_render_id is distinct from btrim(p_shotstack_render_id) then
        raise exception 'RENDER_ALREADY_SUBMITTED_WITH_ANOTHER_ID';
    end if;
    return jsonb_build_object('render_id', p_render_id, 'status', 'SUBMITTED');
end;
$function$;

create or replace function public.record_render_poll(p_render_id uuid, p_status text, p_output_url text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_render public.renders;
    v_status text := lower(btrim(coalesce(p_status, '')));
    v_series_code text;
    v_content_id text;
begin
    select r.* into v_render from public.renders r where r.id = p_render_id for update;
    if not found then
        raise exception 'RENDER_NOT_FOUND';
    end if;
    if v_render.status not in ('SUBMITTED', 'RENDERING', 'DONE', 'STORED') then
        raise exception 'RENDER_NOT_POLLABLE: %', v_render.status;
    end if;
    update public.production_jobs set last_activity_at = now() where id = v_render.job_id;

    if v_status = 'done' and coalesce(btrim(p_output_url), '') <> '' then
        if v_render.status in ('SUBMITTED', 'RENDERING') then
            update public.renders
            set status = 'DONE', output_url = btrim(p_output_url), completed_at = now(), updated_at = now()
            where id = p_render_id;
        end if;
        select s.series_code, e.content_id into v_series_code, v_content_id
        from public.production_jobs j
        join public.series s on s.id = j.series_id
        join public.episodes e on e.id = j.episode_id
        where j.id = v_render.job_id;
        return jsonb_build_object(
            'status', 'DONE',
            'storage_path', format('%s/%s/render/R%s_%s.mp4',
                v_series_code, v_content_id, v_render.render_no, m417_internal.rand_suffix()));
    elsif v_status = 'failed' then
        update public.renders
        set status = 'FAILED', error = 'Shotstack reported failure', completed_at = now(), updated_at = now()
        where id = p_render_id;
        perform m417_internal.event(
            'RENDER_FAILED', 'ERROR', 'Shotstack render failed.',
            jsonb_build_object('render_id', p_render_id, 'shotstack_render_id', v_render.shotstack_render_id),
            v_render.episode_id);
        return jsonb_build_object('status', 'FAILED', 'storage_path', '');
    end if;

    if v_render.status = 'SUBMITTED' then
        update public.renders set status = 'RENDERING', updated_at = now() where id = p_render_id;
    end if;
    return jsonb_build_object('status', 'RENDERING', 'storage_path', '');
end;
$function$;

create or replace function public.complete_render(p_render_id uuid, p_storage_path text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_render public.renders;
    v_job public.production_jobs;
    v_size bigint;
begin
    select r.* into v_render from public.renders r where r.id = p_render_id for update;
    if not found then
        raise exception 'RENDER_NOT_FOUND';
    end if;
    if v_render.status not in ('DONE', 'STORED') then
        raise exception 'RENDER_NOT_DONE: %', v_render.status;
    end if;
    v_size := m417_internal.object_size(p_storage_path);
    if v_size is null then
        raise exception 'RENDER_FILE_NOT_FOUND_IN_STORAGE: %', coalesce(p_storage_path, '(empty)');
    end if;
    if v_size < m417_internal.num('min_video_bytes', 20000) then
        raise exception 'RENDER_FILE_TOO_SMALL: % bytes', v_size;
    end if;
    v_job := m417_internal.lock_job(v_render.job_id);

    update public.renders
    set status = 'STORED', storage_path = p_storage_path, updated_at = now()
    where id = p_render_id;

    if v_job.current_step = 31 and v_job.state = 'READY' then
        update public.episodes set state = 'FINAL_QC'
        where id = v_job.episode_id and state = 'ASSEMBLY';
        perform m417_internal.set_step(
            v_job.id, 32, 'RENDER_STORED', jsonb_build_object('render_id', p_render_id, 'storage_path', p_storage_path));
    end if;
    return m417_internal.job_status(v_job.id)
        || jsonb_build_object('render_id', p_render_id, 'status', 'STORED');
end;
$function$;

create or replace function public.apply_final_qc(p_render_id uuid, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_render public.renders;
    v_job public.production_jobs;
    v_verdict text;
    v_score numeric;
    v_forced text;
    v_count integer;
    v_version integer;
    v_lip_note text;
begin
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'QC_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    select r.* into v_render from public.renders r where r.id = p_render_id for update;
    if not found then
        raise exception 'RENDER_NOT_FOUND';
    end if;
    v_job := m417_internal.lock_job(v_render.job_id);
    if v_render.status in ('QC_PASS', 'QC_FAIL') then
        return m417_internal.job_status(v_job.id)
            || jsonb_build_object('render_id', p_render_id, 'verdict', v_render.qc_verdict, 'decision', 'ALREADY_REVIEWED');
    end if;
    if v_render.status <> 'STORED' then
        raise exception 'RENDER_NOT_STORED: %', v_render.status;
    end if;
    perform m417_internal.require_step(v_job, 32);

    v_verdict := upper(btrim(coalesce(p_result ->> 'verdict', '')));
    if v_verdict not in ('PASS', 'FAIL') then
        raise exception 'QC_VERDICT_INVALID: %', coalesce(p_result ->> 'verdict', '(empty)');
    end if;
    v_score := m417_internal.score100(m417_internal.safe_numeric(p_result ->> 'score'));
    -- No lip-sync is generated in this version: an edit that fails on
    -- lip-sync alone goes on to the owner, who watches it before publishing.
    if v_verdict = 'FAIL'
       and m417_internal.flag('lip_sync_enforced', false) is not true
       and m417_internal.only_lip_sync_failed(p_result -> 'details')
    then
        v_verdict := 'PASS';
        v_lip_note := 'FAIL on lip-sync only; lip-sync is not enforced. The score is kept as given and not held against the edit.';
    end if;
    if v_verdict = 'PASS' then
        if upper(coalesce(p_result -> 'details' ->> 'child_safety', 'PASS')) = 'FAIL' then
            v_forced := 'child_safety FAIL';
        elsif v_lip_note is null
          and (v_score is null or v_score < m417_internal.num('final_qc_min_score', 70)) then
            v_forced := 'score ' || coalesce(v_score::text, 'missing') || ' below minimum';
        end if;
        if v_forced is not null then
            v_verdict := 'FAIL';
        end if;
    end if;

    update public.renders
    set status = case v_verdict when 'PASS' then 'QC_PASS' else 'QC_FAIL' end,
        qc_verdict = v_verdict, qc_score = v_score,
        qc_result = p_result || jsonb_build_object('verdict', v_verdict, 'reviewer_verdict', p_result -> 'verdict')
                    || case when v_forced is null then '{}'::jsonb
                            else jsonb_build_object('overruled', v_forced) end
                    || case when v_lip_note is null then '{}'::jsonb
                            else jsonb_build_object('system_note', v_lip_note) end,
        updated_at = now()
    where id = p_render_id;
    perform m417_internal.usage(v_job.id, 'GEMINI', 'FINAL_QC');

    perform m417_internal.retire_artifacts(v_job.id, array['FINAL_QC_REPORT']);
    select coalesce(max(a.version), 0) + 1 into v_version
    from public.job_artifacts a where a.job_id = v_job.id and a.artifact_type = 'FINAL_QC_REPORT';
    insert into public.job_artifacts (job_id, artifact_type, producer, version, content)
    values (v_job.id, 'FINAL_QC_REPORT', 'GEMINI', v_version,
            p_result || jsonb_build_object('verdict', v_verdict, 'reviewer_verdict', p_result -> 'verdict')
            || case when v_lip_note is null then '{}'::jsonb else jsonb_build_object('system_note', v_lip_note) end);

    if v_verdict = 'PASS' then
        perform m417_internal.set_step(v_job.id, 33, 'FINAL_QC_PASSED', jsonb_build_object('render_id', p_render_id));
    else
        update public.episodes set state = 'ASSEMBLY' where id = v_job.episode_id and state = 'FINAL_QC';
        select count(*) into v_count from public.renders r where r.job_id = v_job.id;
        if v_count >= m417_internal.num('max_renders', 2) then
            perform m417_internal.block_job(
                v_job.id, 'FINAL_QC_FAILED', coalesce(v_forced || '. ', '') || coalesce(p_result ->> 'notes', ''));
        else
            perform m417_internal.set_step(v_job.id, 31, 'FINAL_QC_FAILED_RERENDER', jsonb_build_object('render_id', p_render_id));
        end if;
    end if;
    return m417_internal.job_status(v_job.id)
        || jsonb_build_object('render_id', p_render_id, 'verdict', v_verdict, 'score', v_score);
end;
$function$;

-- ----- step 34 ------------------------------------------------------
create or replace function public.approve_release(p_job_id uuid, p_actor text, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_decision text;
    v_version integer;
    v_decision_id uuid;
begin
    if upper(btrim(coalesce(p_actor, ''))) <> 'CLAUDE' then
        raise exception 'DIRECTOR_NOT_AUTHORIZED: %', coalesce(p_actor, '(empty)');
    end if;
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'DIRECTOR_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    v_decision := upper(btrim(coalesce(p_result ->> 'decision', '')));
    if v_decision not in ('APPROVE', 'REJECT') then
        raise exception 'RELEASE_DECISION_INVALID: %', coalesce(p_result ->> 'decision', '(empty)');
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 34);

    if v_decision = 'APPROVE' then
        if not exists (
            select 1 from public.renders r
            where r.job_id = p_job_id and r.status = 'QC_PASS'
              and r.render_no = (select max(r2.render_no) from public.renders r2 where r2.job_id = p_job_id))
        then
            raise exception 'RELEASE_APPROVAL_REQUIRES_FINAL_QC_PASS';
        end if;
        if coalesce((
            select pc.verdict from public.policy_checks pc
            where pc.job_id = p_job_id and pc.gate_no = 2
            order by pc.created_at desc limit 1), 'FAIL') <> 'PASS'
        then
            raise exception 'RELEASE_APPROVAL_REQUIRES_POLICY_GATE_2';
        end if;
    end if;

    select e.production_version into v_version from public.episodes e where e.id = v_job.episode_id;
    insert into public.director_decisions (
        job_id, episode_id, production_version, stage, decision, actor, notes, result)
    values (p_job_id, v_job.episode_id, v_version, 'RELEASE', v_decision, 'CLAUDE', p_result ->> 'notes', p_result)
    returning id into v_decision_id;
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'RELEASE_DECISION');

    if v_decision = 'APPROVE' then
        update public.episodes set state = 'READY_TO_PUBLISH' where id = v_job.episode_id;
        perform m417_internal.set_step(p_job_id, 35, 'RELEASE_APPROVED', jsonb_build_object('decision_id', v_decision_id));
    else
        perform m417_internal.block_job(p_job_id, 'RELEASE_REJECTED', p_result::text);
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('decision', v_decision, 'decision_id', v_decision_id);
end;
$function$;

-- ----- step 35 ------------------------------------------------------
-- Episodes are Shorts; a custom thumbnail is not part of this version.
create or replace function public.resolve_thumbnail(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 35);
    perform m417_internal.set_step(p_job_id, 36, 'THUMBNAIL_NOT_REQUIRED');
    return m417_internal.job_status(p_job_id) || jsonb_build_object('thumbnail', 'NOT_REQUIRED');
end;
$function$;

-- ----- step 37 ------------------------------------------------------
create or replace function public.save_publication_package(p_job_id uuid, p_selected_by text, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_title text;
    v_description text;
    v_tags jsonb := '[]'::jsonb;
    v_tag text;
    v_len integer := 0;
    v_privacy text := lower(m417_internal.txt('privacy_status', 'private'));
    v_package_id uuid;
begin
    if upper(btrim(coalesce(p_selected_by, ''))) <> 'CLAUDE' then
        raise exception 'PACKAGE_SELECTOR_NOT_AUTHORIZED: %', coalesce(p_selected_by, '(empty)');
    end if;
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'PACKAGE_MUST_BE_JSON_OBJECT';
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 37);

    v_title := btrim(regexp_replace(coalesce(p_result ->> 'title', ''), '[[:space:]]+', ' ', 'g'));
    v_title := replace(replace(v_title, '<', ''), '>', '');
    if v_title = '' then
        raise exception 'PUBLICATION_TITLE_REQUIRED';
    end if;
    v_title := left(v_title, 100);
    v_description := left(replace(replace(coalesce(p_result ->> 'description', ''), '<', ''), '>', ''), 4900);
    if v_privacy not in ('private', 'unlisted', 'public') then
        raise exception 'PRIVACY_STATUS_SETTING_INVALID: %', v_privacy;
    end if;

    -- YouTube allows about 500 characters of tags in total.
    if jsonb_typeof(p_result -> 'tags') = 'array' then
        for v_tag in
            select btrim(replace(replace(replace(t.value, ',', ' '), '<', ''), '>', ''))
            from jsonb_array_elements_text(p_result -> 'tags') t(value)
        loop
            continue when v_tag = '' or v_tags ? v_tag;
            exit when v_len + char_length(v_tag) + 1 > 450;
            v_tags := v_tags || to_jsonb(v_tag);
            v_len := v_len + char_length(v_tag) + 1;
        end loop;
    end if;

    -- Audience, synthetic-media and privacy declarations are owner
    -- settings; the models do not choose them.
    insert into public.publication_packages (
        job_id, title, description, tags, language, made_for_kids, contains_synthetic_media,
        privacy_status, selected_by, result)
    values (
        p_job_id, v_title, v_description, v_tags, nullif(btrim(p_result ->> 'language'), ''),
        m417_internal.flag('made_for_kids', true),
        m417_internal.flag('contains_synthetic_media', true),
        v_privacy, 'CLAUDE', p_result)
    on conflict (job_id) do update
        set title = excluded.title, description = excluded.description, tags = excluded.tags,
            language = excluded.language, made_for_kids = excluded.made_for_kids,
            contains_synthetic_media = excluded.contains_synthetic_media,
            privacy_status = excluded.privacy_status, result = excluded.result, updated_at = now()
    returning id into v_package_id;
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'METADATA_SELECTION');

    update public.episodes set title = v_title where id = v_job.episode_id;
    perform m417_internal.set_step(p_job_id, 38, 'PUBLICATION_PACKAGE_SAVED', jsonb_build_object('package_id', v_package_id));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('package_id', v_package_id, 'title', v_title, 'privacy_status', v_privacy);
end;
$function$;

-- ----- step 38 ------------------------------------------------------
create or replace function public.request_publish_approval(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_pkg public.publication_packages;
    v_path text;
    v_req record;
    v_chat text := m417_internal.txt('notify_chat_id', '');
    v_base text := rtrim(m417_internal.txt('storage_base_url', ''), '/');
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 38);
    if v_chat = '' then
        raise exception 'NOTIFY_CHAT_ID_NOT_SET: set system_text_settings.notify_chat_id';
    end if;
    if v_base = '' then
        raise exception 'STORAGE_BASE_URL_NOT_SET: set system_text_settings.storage_base_url';
    end if;
    select p.* into v_pkg from public.publication_packages p where p.job_id = p_job_id;
    if not found then
        raise exception 'PUBLICATION_PACKAGE_MISSING';
    end if;
    select r.storage_path into v_path
    from public.renders r
    where r.job_id = p_job_id and r.status = 'QC_PASS'
    order by r.render_no desc limit 1;
    if v_path is null then
        raise exception 'APPROVED_RENDER_MISSING';
    end if;

    select * into v_req
    from public.request_human_approval(
        'EPISODE_PUBLISH', v_job.episode_id, 'PIPELINE',
        jsonb_build_object('job_id', p_job_id, 'title', v_pkg.title, 'privacy_status', v_pkg.privacy_status,
                           'made_for_kids', v_pkg.made_for_kids),
        m417_internal.num('publish_approval_ttl_hours', 72)::integer);

    perform m417_internal.set_step(
        p_job_id, 38, 'PUBLISH_APPROVAL_REQUESTED',
        jsonb_build_object('request_id', v_req.request_id, 'expires_at', v_req.expires_at), 'WAITING_HUMAN');

    return m417_internal.job_status(p_job_id) || jsonb_build_object(
        'token', v_req.token,
        'title', v_pkg.title,
        'description', v_pkg.description,
        'storage_path', v_path,
        'storage_base_url', v_base,
        'notify_chat_id', v_chat,
        'expires_at', to_char(v_req.expires_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI'));
end;
$function$;

-- ----- approval links (Make M417-Onay) ------------------------------
create or replace function public.handle_approval_link(
    p_token text, p_decision text, p_decided_by text, p_channel text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_row public.approval_requests;
    v_decision text := upper(btrim(coalesce(p_decision, '')));
    v_job public.production_jobs;
    v_out_id uuid;
    v_scope text;
    v_blank jsonb := jsonb_build_object('scope_type', '', 'outcome', '', 'job_id', '', 'message', '');
begin
    if v_decision not in ('YES', 'NO') then
        return v_blank || jsonb_build_object('outcome', 'INVALID', 'message', 'Geçersiz karar. Bağlantıyı Telegram mesajından yeniden aç.');
    end if;
    select ar.* into v_row
    from public.approval_requests ar
    where ar.token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')
    for update;
    if not found then
        return v_blank || jsonb_build_object('outcome', 'INVALID', 'message', 'Bu bağlantı geçersiz.');
    end if;
    v_scope := case v_row.scope_type when 'EPISODE_PUBLISH' then 'PUBLICATION' else v_row.scope_type end;

    if v_row.scope_type = 'SHOT_ESCALATION' then
        select j.* into v_job
        from public.shots s join public.production_jobs j on j.episode_id = s.episode_id
        where s.id = v_row.scope_id;
    else
        select j.* into v_job from public.production_jobs j where j.episode_id = v_row.scope_id;
    end if;
    v_blank := v_blank || jsonb_build_object('scope_type', v_scope, 'job_id', coalesce(v_job.id::text, ''));

    if v_row.status <> 'PENDING' then
        return v_blank || jsonb_build_object(
            'outcome', 'ALREADY_DECIDED',
            'message', 'Bu istek için daha önce karar verilmiş: '
                || case v_row.status when 'APPROVED' then 'onaylandı' when 'REJECTED' then 'reddedildi'
                                     when 'EXPIRED' then 'süresi doldu' else 'yerine yenisi gönderildi' end || '.');
    end if;
    if v_row.expires_at <= now() then
        return v_blank || jsonb_build_object('outcome', 'EXPIRED', 'message', 'Bu bağlantının süresi dolmuş. Yeni bir onay isteği gerekiyor.');
    end if;
    if v_job.id is null then
        return v_blank || jsonb_build_object('outcome', 'INVALID', 'message', 'Bu istek bir üretim işine bağlı değil.');
    end if;
    perform m417_internal.lock_job(v_job.id);

    if v_row.scope_type = 'EPISODE_PUBLISH' then
        perform public.decide_human_approval(
            p_token, case v_decision when 'YES' then 'APPROVED' else 'REJECTED' end,
            coalesce(nullif(btrim(p_decided_by), ''), 'OWNER'), p_channel, null);
        if v_decision = 'YES' then
            perform m417_internal.set_step(v_job.id, 39, 'PUBLISH_APPROVED_BY_OWNER');
            return v_blank || jsonb_build_object('outcome', 'APPROVED', 'message', 'Onaylandı. Bölüm YouTube''a yükleniyor.');
        end if;
        perform m417_internal.block_job(v_job.id, 'PUBLISH_REJECTED_BY_OWNER', null);
        return v_blank || jsonb_build_object('outcome', 'REJECTED', 'message', 'Reddedildi. Bölüm yayınlanmayacak.');

    elsif v_row.scope_type = 'SHOT_ESCALATION' then
        if v_decision = 'YES' then
            select go.id into v_out_id
            from public.generation_outputs go
            join public.attempts a on a.id = go.attempt_id and a.status = 'SUCCEEDED'
            where go.shot_id = v_row.scope_id
              and go.storage_path is not null and btrim(go.storage_path) <> ''
            order by go.created_at desc
            limit 1;
            if v_out_id is null then
                return v_blank || jsonb_build_object('outcome', 'INVALID', 'message', 'Bu shot için kabul edilebilecek bir çıktı yok.');
            end if;
            perform public.resolve_escalated_shot(
                p_token, 'ACCEPT_OUTPUT', coalesce(nullif(btrim(p_decided_by), ''), 'OWNER'),
                null, v_out_id, p_channel);
            update public.production_jobs set last_activity_at = now() where id = v_job.id;
            return v_blank || jsonb_build_object('outcome', 'APPROVED', 'message', 'Çıktı kabul edildi. Üretim devam ediyor.');
        end if;
        perform public.resolve_escalated_shot(
            p_token, 'CANCEL_SHOT', coalesce(nullif(btrim(p_decided_by), ''), 'OWNER'),
            null, null, p_channel);
        update public.production_jobs set last_activity_at = now() where id = v_job.id;
        return v_blank || jsonb_build_object('outcome', 'REJECTED', 'message', 'Shot iptal edildi. Üretim kalan shot''larla devam ediyor.');
    end if;

    return v_blank || jsonb_build_object('outcome', 'INVALID', 'message', 'Bu istek türü bu bağlantıyla yanıtlanamaz.');
end;
$function$;

-- ----- step 39 ------------------------------------------------------
create or replace function public.claim_publication(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_pkg public.publication_packages;
    v_pub public.publications;
    v_approval_id uuid;
    v_path text;
    v_version integer;
    v_decision text;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 39);
    select p.* into v_pkg from public.publication_packages p where p.job_id = p_job_id;
    if not found then
        raise exception 'PUBLICATION_PACKAGE_MISSING';
    end if;
    select e.production_version into v_version from public.episodes e where e.id = v_job.episode_id;
    select ar.id into v_approval_id
    from public.approval_requests ar
    where ar.scope_type = 'EPISODE_PUBLISH'
      and ar.scope_id = v_job.episode_id
      and ar.scope_version = v_version
      and ar.status = 'APPROVED'
    order by ar.decided_at desc
    limit 1;
    if v_approval_id is null then
        raise exception 'PUBLISH_HUMAN_APPROVAL_REQUIRED';
    end if;
    select r.storage_path into v_path
    from public.renders r
    where r.job_id = p_job_id and r.status = 'QC_PASS'
    order by r.render_no desc limit 1;
    if v_path is null then
        raise exception 'APPROVED_RENDER_MISSING';
    end if;

    select p.* into v_pub from public.publications p where p.job_id = p_job_id for update;
    if found then
        v_decision := case v_pub.status when 'PUBLISHED' then 'ALREADY_PUBLISHED' else 'ALREADY_CLAIMED' end;
    else
        insert into public.publications (job_id, episode_id, package_id, approval_request_id, status)
        values (p_job_id, v_job.episode_id, v_pkg.id, v_approval_id, 'CLAIMED')
        returning * into v_pub;
        v_decision := 'CLAIMED';
        update public.production_jobs set last_activity_at = now() where id = p_job_id;
    end if;

    return jsonb_build_object(
        'decision', v_decision,
        'publication_id', v_pub.id,
        'storage_path', v_path,
        'title', v_pkg.title,
        'description', v_pkg.description,
        'tags_csv', coalesce((select string_agg(t.value, ',') from jsonb_array_elements_text(v_pkg.tags) t(value)), ''),
        'privacy_status', v_pkg.privacy_status,
        'made_for_kids', v_pkg.made_for_kids,
        'contains_synthetic_media', v_pkg.contains_synthetic_media,
        'notify_chat_id', m417_internal.txt('notify_chat_id', ''));
end;
$function$;

create or replace function public.record_publication(
    p_publication_id uuid, p_video_id text, p_url text, p_status text default 'PUBLISHED')
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_pub public.publications;
    v_job public.production_jobs;
begin
    if p_video_id is null or btrim(p_video_id) = '' then
        raise exception 'VIDEO_ID_REQUIRED';
    end if;
    if upper(btrim(coalesce(p_status, 'PUBLISHED'))) <> 'PUBLISHED' then
        raise exception 'PUBLICATION_STATUS_INVALID: %', p_status;
    end if;
    select p.* into v_pub from public.publications p where p.id = p_publication_id for update;
    if not found then
        raise exception 'PUBLICATION_NOT_FOUND';
    end if;
    v_job := m417_internal.lock_job(v_pub.job_id);
    if v_pub.status = 'PUBLISHED' then
        return m417_internal.job_status(v_job.id)
            || jsonb_build_object('publication_id', v_pub.id, 'video_id', v_pub.video_id, 'decision', 'ALREADY_RECORDED');
    end if;

    update public.publications
    set status = 'PUBLISHED', video_id = btrim(p_video_id),
        url = coalesce(nullif(btrim(p_url), ''), 'https://www.youtube.com/watch?v=' || btrim(p_video_id)),
        published_at = now()
    where id = p_publication_id;
    perform m417_internal.usage(v_job.id, 'YOUTUBE', 'UPLOAD');

    update public.episodes set state = 'PUBLISHED' where id = v_job.episode_id;
    update public.budgets set is_active = false
    where reserved_amount = 0
      and ((budget_type = 'EPISODE' and reference_id = v_job.episode_id)
        or (budget_type = 'SHOT' and reference_id in (
               select s.id from public.shots s where s.episode_id = v_job.episode_id)));
    perform m417_internal.set_step(
        v_job.id, 39, 'PUBLISHED', jsonb_build_object('video_id', btrim(p_video_id)), 'DONE');
    perform m417_internal.event(
        'EPISODE_PUBLISHED', 'INFO', 'Episode published to YouTube.',
        jsonb_build_object('job_id', v_job.id, 'video_id', btrim(p_video_id)), v_job.episode_id);

    return m417_internal.job_status(v_job.id)
        || jsonb_build_object('publication_id', p_publication_id, 'video_id', btrim(p_video_id), 'decision', 'RECORDED');
end;
$function$;

-- =====================================================================
-- 10. RPC: S9 learning, maintenance, administration
-- =====================================================================

-- ----- step 41 ------------------------------------------------------
create or replace function public.list_publications_for_analytics()
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object('items', coalesce(jsonb_agg(jsonb_build_object(
               'publication_id', p.id,
               'video_id', p.video_id,
               'snapshot_date', to_char((now() at time zone 'UTC')::date, 'YYYY-MM-DD'))
               order by p.published_at), '[]'::jsonb))
    from public.publications p
    where p.status = 'PUBLISHED'
      and p.video_id is not null
      and p.published_at > now() - make_interval(days => m417_internal.num('analytics_window_days', 90)::integer);
$function$;

-- Called up to twice a day per video: basic counts, then watch-time
-- figures. Values arrive as text; a missing value keeps what is stored.
create or replace function public.record_analytics_snapshot(
    p_publication_id uuid, p_snapshot_date date, p_metrics jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_m jsonb := coalesce(p_metrics, '{}'::jsonb);
begin
    if p_snapshot_date is null then
        raise exception 'SNAPSHOT_DATE_REQUIRED';
    end if;
    if jsonb_typeof(v_m) <> 'object' then
        raise exception 'METRICS_MUST_BE_JSON_OBJECT';
    end if;
    if not exists (select 1 from public.publications p where p.id = p_publication_id and p.status = 'PUBLISHED') then
        raise exception 'PUBLICATION_NOT_FOUND';
    end if;
    insert into public.analytics_snapshots as s (
        publication_id, snapshot_date, views, likes, comments, minutes_watched,
        average_view_duration_seconds, subscribers_gained, metrics)
    values (
        p_publication_id, p_snapshot_date,
        m417_internal.safe_numeric(v_m ->> 'views')::bigint,
        m417_internal.safe_numeric(v_m ->> 'likes')::bigint,
        m417_internal.safe_numeric(v_m ->> 'comments')::bigint,
        m417_internal.safe_numeric(v_m ->> 'minutes_watched'),
        m417_internal.safe_numeric(v_m ->> 'average_view_duration_seconds'),
        m417_internal.safe_numeric(v_m ->> 'subscribers_gained')::bigint,
        v_m)
    on conflict (publication_id, snapshot_date) do update
        set views = coalesce(excluded.views, s.views),
            likes = coalesce(excluded.likes, s.likes),
            comments = coalesce(excluded.comments, s.comments),
            minutes_watched = coalesce(excluded.minutes_watched, s.minutes_watched),
            average_view_duration_seconds = coalesce(excluded.average_view_duration_seconds, s.average_view_duration_seconds),
            subscribers_gained = coalesce(excluded.subscribers_gained, s.subscribers_gained),
            metrics = s.metrics || excluded.metrics,
            updated_at = now();
    return (
        select jsonb_build_object(
            'publication_id', s.publication_id, 'snapshot_date', s.snapshot_date,
            'views', s.views, 'likes', s.likes, 'comments', s.comments,
            'minutes_watched', s.minutes_watched,
            'average_view_duration_seconds', s.average_view_duration_seconds,
            'subscribers_gained', s.subscribers_gained)
        from public.analytics_snapshots s
        where s.publication_id = p_publication_id and s.snapshot_date = p_snapshot_date);
end;
$function$;

create or replace function public.episode_cost_summary(p_episode_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'episode_id', e.id,
        'content_id', e.content_id,
        'video_charged_usd', coalesce((
            select sum(cl.amount) from public.cost_ledger cl
            where cl.episode_id = e.id and cl.entry_type = 'SETTLE'), 0),
        'video_reserved_now_usd', coalesce((
            select b.reserved_amount from public.budgets b
            where b.budget_type = 'EPISODE' and b.reference_id = e.id
            order by b.created_at desc limit 1), 0),
        'episode_budget_usd', (
            select b.hard_limit from public.budgets b
            where b.budget_type = 'EPISODE' and b.reference_id = e.id
            order by b.created_at desc limit 1),
        'video_attempts', (
            select count(*) from public.attempts a
            join public.shots s on s.id = a.shot_id where s.episode_id = e.id),
        'service_usage', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'service', u.service, 'unit', u.unit, 'units', u.units, 'calls', u.calls,
                       'estimated_usd', u.estimated_usd) order by u.service)
            from (
                select su.service, su.unit, sum(su.units) as units, count(*) as calls,
                       round(sum(su.units) * max(sr.usd_per_unit), 4) as estimated_usd
                from public.service_usage su
                join public.production_jobs j on j.id = su.job_id
                left join public.service_rates sr on sr.service = su.service and sr.unit = su.unit
                where j.episode_id = e.id
                group by su.service, su.unit
            ) u), '[]'::jsonb),
        'note', 'video_charged_usd is recorded provider spend. estimated_usd is filled only for services with a row in service_rates.')
    from public.episodes e
    where e.id = p_episode_id;
$function$;

-- ----- step 42 ------------------------------------------------------
create or replace function public.weekly_learning_input()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    -- The report covers the seven days up to today, whenever it runs.
    v_week_end date := (now() at time zone 'UTC')::date;
    v_week_start date := v_week_end - 7;
    v_episodes jsonb;
    v_previous jsonb;
begin
    select coalesce(jsonb_agg(x.row order by x.published_at), '[]'::jsonb) into v_episodes
    from (
        select p.published_at,
               jsonb_build_object(
                   'title', pk.title,
                   'video_id', p.video_id,
                   'published_at', to_char(p.published_at at time zone 'UTC', 'YYYY-MM-DD'),
                   'topic', m417_internal.artifact(p.job_id, 'TOPIC_SELECTION') -> 'premise',
                   'hook', m417_internal.artifact(p.job_id, 'TOPIC_SELECTION') -> 'hook',
                   'characters', (
                       select coalesce(jsonb_agg(distinct c.value), '[]'::jsonb)
                       from public.shots s
                       join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
                       cross join lateral jsonb_array_elements_text(ss.character_codes) c(value)
                       where s.episode_id = p.episode_id),
                   'shots', (select count(*) from public.shots s where s.episode_id = p.episode_id and s.state = 'LOCKED'),
                   'duration_seconds', (
                       select sum(ss.duration_seconds)
                       from public.shots s
                       join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
                       where s.episode_id = p.episode_id and s.state = 'LOCKED'),
                   'latest', (
                       select jsonb_build_object(
                                  'as_of', s.snapshot_date, 'views', s.views, 'likes', s.likes, 'comments', s.comments,
                                  'minutes_watched', s.minutes_watched,
                                  'average_view_duration_seconds', s.average_view_duration_seconds,
                                  'subscribers_gained', s.subscribers_gained)
                       from public.analytics_snapshots s
                       where s.publication_id = p.id and s.snapshot_date <= v_week_end
                       order by s.snapshot_date desc limit 1),
                   'before_this_week', (
                       select jsonb_build_object('as_of', s.snapshot_date, 'views', s.views, 'likes', s.likes, 'comments', s.comments)
                       from public.analytics_snapshots s
                       where s.publication_id = p.id and s.snapshot_date < v_week_start
                       order by s.snapshot_date desc limit 1),
                   'production', public.episode_cost_summary(p.episode_id)
                                 - 'episode_id' - 'content_id' - 'note'
               ) as row
        from public.publications p
        join public.publication_packages pk on pk.id = p.package_id
        where p.status = 'PUBLISHED'
          and p.published_at > now() - interval '56 days'
    ) x;

    select jsonb_build_object('week_start', lr.week_start, 'headline', lr.report -> 'headline',
                              'recommendations', lr.report -> 'recommendations_for_next_topics')
    into v_previous
    from public.learning_reports lr
    where lr.week_start < v_week_start
    order by lr.week_start desc limit 1;

    return jsonb_build_object(
        'week_start', to_char(v_week_start, 'YYYY-MM-DD'),
        'input_text', jsonb_build_object(
            'week_start', v_week_start,
            'week_end', v_week_end,
            'episodes_published_last_8_weeks', v_episodes,
            'episode_count', jsonb_array_length(v_episodes),
            'previous_report', v_previous,
            'data_note', 'Numbers come from daily YouTube snapshots. A null means the value was not collected. before_this_week is the last snapshot taken before week_start; latest minus before_this_week is the change over the seven days. A missing before_this_week means the video is newer than the window.'
        )::text);
end;
$function$;

create or replace function public.save_learning_report(p_week_start date, p_report jsonb, p_model text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_summary text;
begin
    if p_week_start is null then
        raise exception 'WEEK_START_REQUIRED';
    end if;
    if p_report is null or jsonb_typeof(p_report) <> 'object' then
        raise exception 'REPORT_MUST_BE_JSON_OBJECT';
    end if;
    v_summary := coalesce(
        nullif(btrim(p_report ->> 'summary_for_owner_tr'), ''),
        nullif(btrim(p_report ->> 'headline'), ''),
        'Haftalık rapor kaydedildi.');
    v_summary := 'M417 / WIZZLEBURY haftalık rapor (' || to_char(p_week_start, 'DD.MM.YYYY') || E')\n\n' || v_summary;
    insert into public.learning_reports (week_start, report, model, summary)
    values (p_week_start, p_report, p_model, v_summary)
    on conflict (week_start) do update
        set report = excluded.report, model = excluded.model, summary = excluded.summary, updated_at = now();
    perform m417_internal.usage(null, 'CLAUDE', 'WEEKLY_REPORT');
    return jsonb_build_object(
        'week_start', p_week_start,
        'summary_text', left(v_summary, 3900),
        'notify_chat_id', m417_internal.txt('notify_chat_id', ''));
end;
$function$;

-- ----- maintenance --------------------------------------------------
-- The link that re-runs the scenario owning a job's current step.
create or replace function m417_internal.resume_url(p_job_id uuid, p_step integer)
 returns text language sql stable security definer set search_path to ''
as $function$
    select case
        when p_step between 6 and 15 then nullif(m417_internal.txt('webhook_s2', ''), '') || '?job_id=' || p_job_id
        when p_step between 16 and 21 then nullif(m417_internal.txt('webhook_s3', ''), '') || '?job_id=' || p_job_id
        when p_step between 22 and 29 then nullif(m417_internal.txt('webhook_s4_driver', ''), '') || '?source=manual'
        when p_step between 30 and 34 then nullif(m417_internal.txt('webhook_s6', ''), '') || '?job_id=' || p_job_id
        when p_step between 35 and 38 then nullif(m417_internal.txt('webhook_s7', ''), '') || '?job_id=' || p_job_id
        when p_step = 39 then nullif(m417_internal.txt('webhook_s8', ''), '') || '?job_id=' || p_job_id
    end;
$function$;

create or replace function public.pipeline_overview()
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'pipeline_enabled', m417_internal.flag('pipeline_enabled', false),
        'generation_enabled', m417_internal.flag('generation_enabled', false),
        'monthly_budget', (
            select jsonb_build_object('hard_limit', b.hard_limit, 'reserved', b.reserved_amount, 'settled', b.settled_amount,
                                      'available', b.hard_limit - b.reserved_amount - b.settled_amount)
            from public.budgets b
            where b.budget_type = 'MONTHLY' and b.reference_id is null and b.is_active = true
              and (b.period_start is null or b.period_start <= now())
              and (b.period_end is null or b.period_end > now())
            order by b.created_at desc limit 1),
        'jobs', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'job_id', j.id,
                       'content_id', e.content_id,
                       'title', e.title,
                       'episode_state', e.state,
                       'step_no', j.current_step,
                       'state', j.state,
                       'blocked_reason', j.blocked_reason,
                       'blocked_detail', j.blocked_detail,
                       'idle_minutes', floor(extract(epoch from (now() - j.last_activity_at)) / 60),
                       'resume_url', m417_internal.resume_url(j.id, j.current_step))
                   order by j.created_at desc)
            from (select * from public.production_jobs order by created_at desc limit 20) j
            join public.episodes e on e.id = j.episode_id), '[]'::jsonb));
$function$;

create or replace function public.daily_maintenance()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_lines text[] := array[]::text[];
    v_row record;
    v_idle integer := m417_internal.num('job_idle_alert_minutes', 30)::integer;
    v_n integer;
begin
    -- Approval links past their time are closed.
    update public.approval_requests
    set status = 'EXPIRED'
    where status = 'PENDING' and expires_at <= now();
    get diagnostics v_n = row_count;
    if v_n > 0 then
        v_lines := v_lines || format('%s onay bağlantısının süresi doldu.', v_n);
    end if;

    for v_row in
        select j.id, j.current_step, j.state, j.blocked_reason, j.blocked_detail, e.content_id,
               floor(extract(epoch from (now() - j.last_activity_at)) / 60)::integer as idle_minutes
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        where j.state in ('READY', 'BLOCKED', 'WAITING_HUMAN')
        order by j.created_at
    loop
        if v_row.state = 'BLOCKED' then
            v_lines := v_lines || format(
                E'%s durdu (adım %s): %s\n%s',
                v_row.content_id, v_row.current_step, v_row.blocked_reason,
                left(coalesce(v_row.blocked_detail, ''), 300));
        elsif v_row.state = 'WAITING_HUMAN' then
            if not exists (
                select 1 from public.approval_requests ar
                join public.production_jobs j on j.episode_id = ar.scope_id
                where j.id = v_row.id and ar.scope_type = 'EPISODE_PUBLISH' and ar.status = 'PENDING')
            then
                v_lines := v_lines || format(
                    '%s yayın onayı bekliyordu ama geçerli bir onay bağlantısı kalmadı. Yeni bağlantı için işi sürdür.',
                    v_row.content_id);
            elsif v_row.idle_minutes > 24 * 60 then
                v_lines := v_lines || format('%s yayın onayını bekliyor (%s saattir).', v_row.content_id, v_row.idle_minutes / 60);
            end if;
        elsif v_row.current_step between 22 and 29 then
            if m417_internal.flag('generation_enabled', false) is not true then
                v_lines := v_lines || format('%s video adımında bekliyor: ücretli üretim kapalı.', v_row.content_id);
            elsif v_row.idle_minutes > greatest(v_idle, 60)
              and not exists (
                  select 1 from public.approval_requests ar
                  join public.shots s on s.id = ar.scope_id
                  join public.production_jobs j on j.episode_id = s.episode_id
                  where j.id = v_row.id and ar.scope_type = 'SHOT_ESCALATION' and ar.status = 'PENDING')
            then
                v_lines := v_lines || format(
                    E'%s video adımında %s dakikadır ilerlemiyor. Sürdür: %s',
                    v_row.content_id, v_row.idle_minutes, coalesce(m417_internal.resume_url(v_row.id, v_row.current_step), '-'));
            end if;
        elsif v_row.idle_minutes > v_idle then
            v_lines := v_lines || format(
                E'%s adım %s''te %s dakikadır bekliyor. Sürdür: %s',
                v_row.content_id, v_row.current_step, v_row.idle_minutes,
                coalesce(m417_internal.resume_url(v_row.id, v_row.current_step), '-'));
        end if;
    end loop;

    if m417_internal.flag('pipeline_enabled', false) and not exists (
        select 1 from public.budgets b
        where b.budget_type = 'MONTHLY' and b.reference_id is null and b.is_active = true
          and (b.period_start is null or b.period_start <= now())
          and (b.period_end is null or b.period_end > now()))
    then
        v_lines := v_lines || 'Bu dönem için aktif aylık bütçe yok; yeni bölüm başlatılamaz.'::text;
    end if;

    for v_row in select * from public.find_stuck_attempts(90)
    loop
        v_lines := v_lines || format(
            'Takılan video denemesi: %s, durum %s, önerilen işlem %s.',
            v_row.provider, v_row.status, v_row.recommended_action);
    end loop;

    select count(*) into v_n
    from public.approval_requests ar
    where ar.scope_type = 'SHOT_ESCALATION' and ar.status = 'PENDING' and ar.created_at < now() - interval '6 hours';
    if v_n > 0 then
        v_lines := v_lines || format('%s shot kararını bekliyor (Telegram''daki onay mesajı).', v_n);
    end if;

    return jsonb_build_object(
        'has_issues', cardinality(v_lines) > 0,
        'message_text', case when cardinality(v_lines) = 0 then ''
            else left(E'M417 / WIZZLEBURY bakım raporu\n\n' || array_to_string(v_lines, E'\n\n'), 3900) end,
        'notify_chat_id', m417_internal.txt('notify_chat_id', ''),
        'issue_count', cardinality(v_lines));
end;
$function$;

-- ----- administration ----------------------------------------------
create or replace function public.set_pipeline_enabled(p_enabled boolean)
 returns boolean language plpgsql security definer set search_path to ''
as $function$
begin
    if p_enabled is null then
        raise exception 'ENABLED_REQUIRED';
    end if;
    update public.system_flags set value = p_enabled where key = 'pipeline_enabled';
    if not found then
        raise exception 'PIPELINE_FLAG_MISSING';
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values (
        case when p_enabled then 'PIPELINE_ENABLED' else 'PIPELINE_DISABLED' end,
        case when p_enabled then 'INFO' else 'WARNING' end,
        'CONTROL_PLANE',
        case when p_enabled then 'Job pipeline enabled' else 'Job pipeline disabled' end,
        jsonb_build_object('enabled', p_enabled));
    return p_enabled;
end;
$function$;

-- Opens the budget for the current calendar month (UTC). Earlier
-- monthly budgets without open reservations are closed.
create or replace function public.open_monthly_budget(p_hard_limit_usd numeric, p_actor text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_start timestamptz := date_trunc('month', now() at time zone 'UTC') at time zone 'UTC';
    v_end timestamptz := (date_trunc('month', now() at time zone 'UTC') + interval '1 month') at time zone 'UTC';
    v_id uuid;
    v_spent numeric := 0;
begin
    if p_hard_limit_usd is null or p_hard_limit_usd <= 0 then
        raise exception 'HARD_LIMIT_REQUIRED';
    end if;
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if exists (
        select 1 from public.budgets b
        where b.budget_type = 'MONTHLY' and b.reference_id is null and b.is_active = true
          and b.reserved_amount > 0)
    then
        raise exception 'MONTHLY_BUDGET_HAS_OPEN_RESERVATIONS';
    end if;
    -- Money already charged this month counts against the new limit.
    select coalesce(sum(cl.amount), 0) into v_spent
    from public.cost_ledger cl
    where cl.entry_type = 'SETTLE' and cl.created_at >= v_start and cl.created_at < v_end;
    if v_spent > p_hard_limit_usd then
        raise exception 'LIMIT_BELOW_SPEND_THIS_MONTH: % already charged', v_spent;
    end if;
    update public.budgets
    set is_active = false
    where budget_type = 'MONTHLY' and reference_id is null and is_active = true;
    insert into public.budgets (budget_type, reference_id, currency, hard_limit, settled_amount, period_start, period_end, is_active)
    values ('MONTHLY', null, 'USD', p_hard_limit_usd, v_spent, v_start, v_end, true)
    returning id into v_id;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('MONTHLY_BUDGET_OPENED', 'INFO', 'CONTROL_PLANE',
            'Monthly budget opened by ' || p_actor,
            jsonb_build_object('budget_id', v_id, 'hard_limit', p_hard_limit_usd, 'already_charged', v_spent,
                               'period_start', v_start, 'period_end', v_end));
    return jsonb_build_object('budget_id', v_id, 'hard_limit_usd', p_hard_limit_usd,
                              'already_charged_usd', v_spent,
                              'period_start', v_start, 'period_end', v_end);
end;
$function$;

-- The owner allows a video model to be used without a paid benchmark.
create or replace function public.approve_model_pilot(p_model_code text, p_actor text, p_note text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_model public.generation_models;
    v_id uuid;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    select gm.* into v_model from public.generation_models gm where gm.model_code = p_model_code;
    if not found then
        raise exception 'MODEL_NOT_FOUND: %', coalesce(p_model_code, '(empty)');
    end if;
    select pa.id into v_id
    from public.generation_model_pilot_approvals pa
    where pa.model_id = v_model.id and pa.revoked_at is null;
    if found then
        return jsonb_build_object('approval_id', v_id, 'model_code', v_model.model_code, 'decision', 'ALREADY_APPROVED');
    end if;
    insert into public.generation_model_pilot_approvals (model_id, approved_by, note)
    values (v_model.id, p_actor, p_note)
    returning id into v_id;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('MODEL_PILOT_APPROVED', 'WARNING', 'CONTROL_PLANE',
            'Video model approved for a pilot without a paid benchmark by ' || p_actor,
            jsonb_build_object('approval_id', v_id, 'model_id', v_model.id, 'model_code', v_model.model_code, 'note', p_note));
    return jsonb_build_object('approval_id', v_id, 'model_code', v_model.model_code, 'decision', 'APPROVED');
end;
$function$;

create or replace function public.revoke_model_pilot(p_model_code text, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_id uuid;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    update public.generation_model_pilot_approvals pa
    set revoked_at = now(), revoked_by = p_actor, revoke_reason = p_reason
    from public.generation_models gm
    where gm.id = pa.model_id and gm.model_code = p_model_code and pa.revoked_at is null
    returning pa.id into v_id;
    if v_id is null then
        return jsonb_build_object('model_code', p_model_code, 'decision', 'NO_ACTIVE_APPROVAL');
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('MODEL_PILOT_REVOKED', 'WARNING', 'CONTROL_PLANE',
            'Pilot approval of a video model revoked by ' || p_actor,
            jsonb_build_object('approval_id', v_id, 'model_code', p_model_code, 'reason', p_reason));
    return jsonb_build_object('approval_id', v_id, 'model_code', p_model_code, 'decision', 'REVOKED');
end;
$function$;

-- The owner names the public copy of a canonical reference image.
-- p_object_path is the file's path inside the public bucket.
create or replace function public.set_video_reference(
    p_asset_code text, p_object_path text, p_actor text, p_bucket text default 'public-refs')
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_asset_id uuid;
    v_path text := btrim(coalesce(p_object_path, ''));
    v_bucket text := btrim(coalesce(p_bucket, ''));
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    select ar.id into v_asset_id
    from public.asset_registry ar
    where ar.asset_code = p_asset_code and ar.status = 'LOCKED'
    order by ar.version desc
    limit 1;
    if not found then
        raise exception 'LOCKED_ASSET_NOT_FOUND: %', coalesce(p_asset_code, '(empty)');
    end if;
    if v_path = '' or v_path ~ '^/' or v_path ~ '[[:space:]?#]' or v_bucket = '' or v_bucket ~ '[/[:space:]?#]' then
        raise exception 'REFERENCE_PATH_INVALID: %/%', v_bucket, v_path;
    end if;
    insert into public.video_reference_images (asset_id, bucket, object_path, is_active, set_by)
    values (v_asset_id, v_bucket, v_path, true, p_actor)
    on conflict (asset_id) do update
        set bucket = excluded.bucket, object_path = excluded.object_path, is_active = true,
            set_by = excluded.set_by, updated_at = now();
    insert into public.events (event_type, severity, source, message, metadata)
    values ('VIDEO_REFERENCE_SET', 'INFO', 'CONTROL_PLANE',
            'Public reference image set for ' || p_asset_code || ' by ' || p_actor,
            jsonb_build_object('asset_code', p_asset_code, 'bucket', v_bucket, 'object_path', v_path));
    return jsonb_build_object(
        'asset_code', p_asset_code, 'decision', 'SET',
        'url', rtrim(m417_internal.txt('storage_base_url', ''), '/') || '/object/public/' || v_bucket || '/' || v_path);
end;
$function$;

create or replace function public.set_text_setting(p_key text, p_value text)
 returns text language plpgsql security definer set search_path to ''
as $function$
begin
    update public.system_text_settings
    set value = btrim(coalesce(p_value, '')), updated_at = now()
    where key = p_key;
    if not found then
        raise exception 'UNKNOWN_TEXT_SETTING: %', p_key;
    end if;
    if p_key = 'privacy_status' and lower(btrim(p_value)) not in ('private', 'unlisted', 'public') then
        raise exception 'PRIVACY_STATUS_INVALID: %', p_value;
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('SETTING_CHANGED', 'INFO', 'CONTROL_PLANE', 'Text setting changed: ' || p_key,
            jsonb_build_object('key', p_key));
    return btrim(coalesce(p_value, ''));
end;
$function$;

create or replace function public.set_numeric_setting(p_key text, p_value numeric)
 returns numeric language plpgsql security definer set search_path to ''
as $function$
begin
    if p_value is null then
        raise exception 'VALUE_REQUIRED';
    end if;
    update public.system_settings
    set value_numeric = p_value, updated_at = now()
    where key = p_key;
    if not found then
        raise exception 'UNKNOWN_NUMERIC_SETTING: %', p_key;
    end if;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('SETTING_CHANGED', 'INFO', 'CONTROL_PLANE', 'Numeric setting changed: ' || p_key,
            jsonb_build_object('key', p_key, 'value', p_value));
    return p_value;
end;
$function$;

create or replace function public.resume_production_job(p_job_id uuid, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.state not in ('BLOCKED', 'WAITING_HUMAN') then
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('decision', 'NOT_STOPPED',
                                  'resume_url', m417_internal.resume_url(p_job_id, v_job.current_step));
    end if;
    -- A job stopped by a counter gets a fresh count; the cause is in the log.
    update public.production_jobs
    set revision_count = case when v_job.blocked_reason = 'REVISION_LIMIT_REACHED' then 0 else revision_count end,
        validation_retry_count = case when v_job.blocked_reason = 'VALIDATION_RETRY_LIMIT_REACHED' then 0 else validation_retry_count end,
        topic_retry_count = case when v_job.blocked_reason = 'POLICY_GATE_1_FAILED' then 0 else topic_retry_count end,
        -- The watchdog starts the job on its next round; no link to click.
        kick_requested = true,
        watchdog_resumes = 0
    where id = p_job_id;
    perform m417_internal.set_step(
        p_job_id, v_job.current_step, 'RESUMED',
        jsonb_build_object('actor', p_actor, 'reason', p_reason,
                           'previous_state', v_job.state, 'previous_block', v_job.blocked_reason));
    perform m417_internal.event(
        'JOB_RESUMED', 'WARNING', 'Job resumed by ' || p_actor || ': ' || p_reason,
        jsonb_build_object('job_id', p_job_id, 'step_no', v_job.current_step, 'previous_block', v_job.blocked_reason),
        v_job.episode_id);
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('decision', 'RESUMED',
                              'resume_url', m417_internal.resume_url(p_job_id, v_job.current_step));
end;
$function$;

create or replace function public.cancel_production_job(p_job_id uuid, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_state text;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.state in ('DONE', 'CANCELLED') then
        return m417_internal.job_status(p_job_id) || jsonb_build_object('decision', 'ALREADY_FINISHED');
    end if;
    -- Money that is reserved or with a provider must be settled first.
    if exists (
        select 1 from public.attempts a
        join public.shots s on s.id = a.shot_id
        where s.episode_id = v_job.episode_id
          and a.status in ('BUDGET_RESERVED', 'SUBMITTED', 'GENERATING'))
    then
        raise exception 'JOB_HAS_ACTIVE_VIDEO_ATTEMPTS';
    end if;
    if exists (select 1 from public.publications p where p.job_id = p_job_id) then
        raise exception 'JOB_HAS_A_PUBLICATION_CLAIM';
    end if;
    select e.state into v_state from public.episodes e where e.id = v_job.episode_id;
    if v_state not in ('PUBLISHED', 'CANCELLED') then
        update public.episodes set state = 'CANCELLED' where id = v_job.episode_id;
    end if;
    update public.budgets set is_active = false
    where reserved_amount = 0
      and ((budget_type = 'EPISODE' and reference_id = v_job.episode_id)
        or (budget_type = 'SHOT' and reference_id in (
               select s.id from public.shots s where s.episode_id = v_job.episode_id)));
    perform m417_internal.set_step(
        p_job_id, v_job.current_step, 'CANCELLED',
        jsonb_build_object('actor', p_actor, 'reason', p_reason), 'CANCELLED');
    perform m417_internal.event(
        'JOB_CANCELLED', 'WARNING', 'Job cancelled by ' || p_actor || ': ' || p_reason,
        jsonb_build_object('job_id', p_job_id, 'step_no', v_job.current_step), v_job.episode_id);
    return m417_internal.job_status(p_job_id) || jsonb_build_object('decision', 'CANCELLED');
end;
$function$;

-- A review link that never reached the owner is replaced by a new one
-- on the next video tick.
create or replace function public.reissue_shot_review(p_shot_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_n integer;
begin
    update public.approval_requests
    set status = 'SUPERSEDED'
    where scope_type = 'SHOT_ESCALATION' and scope_id = p_shot_id and status = 'PENDING';
    get diagnostics v_n = row_count;
    return jsonb_build_object('superseded', v_n);
end;
$function$;

-- After a failed YouTube upload: frees the claim so step 39 can run again.
create or replace function public.reset_publication_claim(p_job_id uuid, p_actor text, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_pub public.publications;
begin
    if p_actor is null or btrim(p_actor) = '' or p_reason is null or btrim(p_reason) = '' then
        raise exception 'ACTOR_AND_REASON_REQUIRED';
    end if;
    v_job := m417_internal.lock_job(p_job_id);
    select p.* into v_pub from public.publications p where p.job_id = p_job_id for update;
    if not found then
        return jsonb_build_object('decision', 'NO_CLAIM');
    end if;
    if v_pub.status = 'PUBLISHED' then
        raise exception 'PUBLICATION_ALREADY_PUBLISHED';
    end if;
    delete from public.publications where id = v_pub.id;
    perform m417_internal.event(
        'PUBLICATION_CLAIM_RESET', 'WARNING',
        'Publication claim reset by ' || p_actor || ': ' || p_reason || '. Check the channel for a duplicate upload first.',
        jsonb_build_object('job_id', p_job_id), v_job.episode_id);
    return jsonb_build_object('decision', 'CLAIM_RESET',
                              'resume_url', m417_internal.resume_url(p_job_id, v_job.current_step));
end;
$function$;

-- Adds a track to the licensed library. Registering a track is the
-- owner's statement that the licence covers this use.
create or replace function public.register_music_track(
    p_track_code text, p_title text, p_role text, p_storage_path text,
    p_license_type text, p_verified_by text,
    p_license_url text default null, p_duration_seconds numeric default null, p_mood text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_id uuid;
begin
    if coalesce(btrim(p_track_code), '') = '' or coalesce(btrim(p_title), '') = ''
       or coalesce(btrim(p_storage_path), '') = '' or coalesce(btrim(p_license_type), '') = ''
       or coalesce(btrim(p_verified_by), '') = ''
    then
        raise exception 'TRACK_CODE_TITLE_PATH_LICENSE_AND_VERIFIER_REQUIRED';
    end if;
    if upper(btrim(p_role)) not in ('MUSIC', 'SFX') then
        raise exception 'TRACK_ROLE_INVALID: %', p_role;
    end if;
    if m417_internal.object_size(btrim(p_storage_path)) is null then
        raise exception 'TRACK_FILE_NOT_FOUND_IN_STORAGE: %', p_storage_path;
    end if;
    insert into public.music_tracks (
        track_code, title, role, mood, storage_path, duration_seconds, license_type, license_url,
        license_status, license_checked_by, license_checked_at)
    values (
        upper(btrim(p_track_code)), btrim(p_title), upper(btrim(p_role)), p_mood, btrim(p_storage_path),
        p_duration_seconds, btrim(p_license_type), p_license_url, 'VERIFIED', btrim(p_verified_by), now())
    on conflict (track_code) do update
        set title = excluded.title, role = excluded.role, mood = excluded.mood,
            storage_path = excluded.storage_path, duration_seconds = excluded.duration_seconds,
            license_type = excluded.license_type, license_url = excluded.license_url,
            license_status = 'VERIFIED', license_checked_by = excluded.license_checked_by,
            license_checked_at = now(), is_active = true
    returning id into v_id;
    return jsonb_build_object('track_id', v_id, 'track_code', upper(btrim(p_track_code)), 'license_status', 'VERIFIED');
end;
$function$;

-- ---------------------------------------------------------------------
-- 10. Resilience: step lease, voice hand-outs, watchdog, notices
-- ---------------------------------------------------------------------
create or replace function m417_internal.step_has_lease(p_step integer)
 returns boolean language sql immutable set search_path to ''
as $function$
    -- The steps that are one paid model call followed by one save.
    select p_step = any (array[6, 7, 8, 10, 11, 12, 14, 19, 32, 33, 34, 36, 37]);
$function$;

-- True while voice lines handed to a run have not come back yet.
create or replace function m417_internal.voice_batch_open(p_job_id uuid)
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select exists (
        select 1
        from public.voice_handouts h
        join public.shot_specifications ss on ss.id = h.shot_specification_id and ss.is_active = true
        join public.shots s on s.id = ss.shot_id
        join public.production_jobs j on j.episode_id = s.episode_id
        where j.id = p_job_id
          and h.handed_out_at > now() - make_interval(secs => m417_internal.num('voice_handout_seconds', 240)));
$function$;

create or replace function m417_internal.block_reason_tr(p_reason text)
 returns text language sql immutable set search_path to ''
as $function$
    select case p_reason
        when 'VIDEO_PREREQUISITES_MISSING' then 'Video üretimi için gereken model kaydı ya da bütçe eksik.'
        when 'NO_ACTIVE_ROUTING_POLICY' then 'Video modeli seçme kuralı tanımlı değil.'
        when 'NO_ELIGIBLE_VIDEO_MODEL' then 'Bu sahneyi üretebilecek uygun bir video modeli yok.'
        when 'VIDEO_ATTEMPT_REFUSED' then 'Video denemesi başlatılamadı (bütçe ya da hazırlık kontrolü).'
        when 'VOICE_TAKE_LIMIT_REACHED' then 'Bir replik için izin verilen ses denemeleri bitti.'
        when 'DIALOGUE_DOES_NOT_FIT_SHOT' then 'Bir replik, sahnesine sığmıyor.'
        when 'POLICY_GATE_1_FAILED' then 'Konu, çocuk güvenliği kontrolünden geçemedi.'
        when 'POLICY_GATE_2_FAILED' then 'Bitmiş video, güvenlik kontrolünden geçemedi.'
        when 'REVISION_LIMIT_REACHED' then 'Senaryo, izin verilen düzeltme sayısında onaylanamadı.'
        when 'VALIDATION_RETRY_LIMIT_REACHED' then 'Senaryo ya da sahne paketi kurallara uydurulamadı.'
        when 'FINAL_QC_FAILED' then 'Bitmiş video kalite kontrolünden geçemedi.'
        when 'RENDER_LIMIT_REACHED' then 'İzin verilen montaj denemeleri bitti.'
        when 'RELEASE_REJECTED' then 'Baş Yönetmen bitmiş videoyu onaylamadı.'
        when 'PUBLISH_REJECTED_BY_OWNER' then 'Yayın onayını sen reddettin.'
        when 'ALL_SHOTS_CANCELLED' then 'Bütün sahneler iptal edildi.'
        when 'PILOT_SHOT_CANCELLED' then 'İlk (pilot) sahne iptal edildi.'
        when 'SHOT_FAILED_WITHOUT_OUTPUT' then 'Bir sahne iki denemede de üretilemedi.'
        when 'BUDGET_GATE_1_FAILED' then 'Bütçe yetersiz ya da bu ay için bütçe açılmamış.'
        when 'BUDGET_GATE_2_FAILED' then 'Video için kalan bütçe yetersiz.'
        when 'STALLED' then 'İş ilerlemiyor; otomatik yeniden başlatmalar sonuç vermedi.'
        else 'Sistem bir kontrol noktasında durdu.'
    end;
$function$;

-- Decides what has to happen now; changes only the database.
--   RESUME: a READY job without activity is started again (a limited
--           number of times per step, then it is blocked as STALLED).
--   NOTIFY: the owner is told once about every stop.
create or replace function public.watchdog_tick()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_actions jsonb := '[]'::jsonb;
    v_idle interval := make_interval(mins => greatest(m417_internal.num('watchdog_idle_minutes', 12), 1)::integer);
    v_max integer := m417_internal.num('watchdog_max_resumes', 3)::integer;
    v_notify_url text := nullif(m417_internal.txt('webhook_notify', ''), '');
    v_chat text := nullif(m417_internal.txt('notify_chat_id', ''), '');
    v_job record;
    v_url text;
    v_resumes integer;
    v_key text;
begin
    if m417_internal.flag('pipeline_enabled', false) is not true then
        return jsonb_build_object('actions', v_actions, 'note', 'PIPELINE_DISABLED');
    end if;

    for v_job in
        select j.* from public.production_jobs j
        where j.state = 'READY'
        order by j.created_at
        for update skip locked
    loop
        v_url := m417_internal.resume_url(v_job.id, v_job.current_step);
        continue when v_url is null;
        -- The video stage only moves while paid generation is switched on.
        continue when v_job.current_step between 22 and 29
                      and m417_internal.flag('generation_enabled', false) is not true;
        continue when not (
            v_job.kick_requested
            or (v_job.last_activity_at < now() - v_idle
                and coalesce(v_job.watchdog_last_at, '-infinity'::timestamptz) < now() - v_idle));

        v_resumes := case when v_job.watchdog_step is not distinct from v_job.current_step
                          then v_job.watchdog_resumes else 0 end;
        if not v_job.kick_requested and v_resumes >= v_max then
            perform m417_internal.block_job(
                v_job.id, 'STALLED',
                format('No progress at step %s after %s automatic restarts.', v_job.current_step, v_resumes));
            update public.production_jobs
            set watchdog_resumes = 0, watchdog_step = null
            where id = v_job.id;
            continue;
        end if;

        update public.production_jobs
        set watchdog_step = current_step,
            watchdog_resumes = case when v_job.kick_requested then 0 else v_resumes + 1 end,
            watchdog_last_at = now(),
            kick_requested = false,
            step_claimed_at = null
        where id = v_job.id;
        insert into public.job_step_log (job_id, step_no, event, detail)
        values (v_job.id, v_job.current_step, 'WATCHDOG_RESTART',
                jsonb_build_object('attempt', case when v_job.kick_requested then 0 else v_resumes + 1 end,
                                   'owner_requested', v_job.kick_requested));
        v_actions := v_actions || jsonb_build_object(
            'type', 'RESUME', 'job_id', v_job.id, 'step_no', v_job.current_step,
            'url', v_url,
            'body', jsonb_build_object('job_id', v_job.id, 'source', 'watchdog'));
    end loop;

    -- A job that moves again may be reported again later.
    update public.production_jobs
    set notified_key = null
    where state <> 'BLOCKED' and notified_key is not null;

    if v_notify_url is not null and v_chat is not null then
        for v_job in
            select j.id, j.current_step, j.blocked_reason, j.blocked_detail, j.last_activity_at, j.notified_key,
                   coalesce(nullif(btrim(e.title), ''), e.content_id, 'adsız bölüm') as title, e.content_id
            from public.production_jobs j
            join public.episodes e on e.id = j.episode_id
            where j.state = 'BLOCKED'
            order by j.created_at
            for update of j skip locked
        loop
            v_key := coalesce(v_job.blocked_reason, '') || ':' || v_job.current_step || ':'
                     || extract(epoch from v_job.last_activity_at)::bigint;
            continue when v_job.notified_key is not distinct from v_key;
            update public.production_jobs set notified_key = v_key where id = v_job.id;
            v_actions := v_actions || jsonb_build_object(
                'type', 'NOTIFY', 'job_id', v_job.id, 'step_no', v_job.current_step,
                'url', v_notify_url,
                'body', jsonb_build_object(
                    'chat_id', v_chat,
                    'text', format(
                        E'⛔ Bölüm durdu\nBölüm: %s (%s)\nAdım: %s\nSebep: %s\nKod: %s%s\n\nDevam ettirmek için SQL Editor''da:\nselect public.resume_production_job(''%s'', ''FATIH'', ''devam'');',
                        v_job.title, v_job.content_id, v_job.current_step,
                        m417_internal.block_reason_tr(v_job.blocked_reason),
                        coalesce(v_job.blocked_reason, '-'),
                        case when coalesce(btrim(v_job.blocked_detail), '') = '' then ''
                             else E'\nAyrıntı: ' || left(v_job.blocked_detail, 300) end,
                        v_job.id)));
        end loop;
    end if;

    return jsonb_build_object('actions', v_actions, 'checked_at', now());
end;
$function$;

-- Runs one watchdog round and sends what it decided (needs pg_net).
create or replace function public.watchdog_run()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_tick jsonb;
    v_action jsonb;
    v_sent integer := 0;
begin
    if to_regnamespace('net') is null then
        raise exception 'PG_NET_NOT_ENABLED: enable the pg_net extension first';
    end if;
    v_tick := public.watchdog_tick();
    for v_action in select * from jsonb_array_elements(v_tick -> 'actions')
    loop
        perform net.http_post(url := v_action ->> 'url', body := v_action -> 'body');
        v_sent := v_sent + 1;
    end loop;
    return jsonb_build_object('sent', v_sent, 'actions', v_tick -> 'actions');
end;
$function$;

-- =====================================================================
-- 10b. Film grammar and the two-yes rule (010)
-- =====================================================================

-- ----- small helpers -------------------------------------------------
create or replace function m417_internal.film_on()
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select m417_internal.flag('film_grammar_enforced', false) is true;
$function$;

-- The eight shot sizes, whatever way the writer spelled them.
create or replace function m417_internal.film_size(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select case btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z]+', '_', 'g'), '_')
        when 'EXTREME_WIDE' then 'EXTREME_WIDE'
        when 'EWS' then 'EXTREME_WIDE'
        when 'ESTABLISHING' then 'EXTREME_WIDE'
        when 'WIDE' then 'WIDE'
        when 'WS' then 'WIDE'
        when 'FULL' then 'WIDE'
        when 'MEDIUM' then 'MEDIUM'
        when 'MS' then 'MEDIUM'
        when 'MEDIUM_CLOSE' then 'MEDIUM_CLOSE'
        when 'MEDIUM_CLOSE_UP' then 'MEDIUM_CLOSE'
        when 'MCU' then 'MEDIUM_CLOSE'
        when 'CLOSE_UP' then 'CLOSE_UP'
        when 'CLOSEUP' then 'CLOSE_UP'
        when 'CU' then 'CLOSE_UP'
        when 'EXTREME_CLOSE_UP' then 'EXTREME_CLOSE_UP'
        when 'ECU' then 'EXTREME_CLOSE_UP'
        when 'INSERT' then 'INSERT'
        when 'DETAIL' then 'INSERT'
        when 'OVER_SHOULDER' then 'OVER_SHOULDER'
        when 'OVER_THE_SHOULDER' then 'OVER_SHOULDER'
        when 'OTS' then 'OVER_SHOULDER'
        else null end;
$function$;

-- The framing sentence the video model reads for a shot size.
create or replace function m417_internal.film_size_sentence(p_size text)
 returns text language sql immutable set search_path to ''
as $function$
    select case p_size
        when 'EXTREME_WIDE' then 'Extreme wide establishing shot: the whole place is visible and the characters are small in the frame.'
        when 'WIDE' then 'Wide shot: full bodies from head to feet, with the surroundings clearly visible.'
        when 'MEDIUM' then 'Medium shot: framed from the waist up.'
        when 'MEDIUM_CLOSE' then 'Medium close-up: framed from the chest up.'
        when 'CLOSE_UP' then 'Close-up: one face fills the frame.'
        when 'EXTREME_CLOSE_UP' then 'Extreme close-up on a single detail such as the eyes or the hands.'
        when 'INSERT' then 'Insert detail shot: the object fills the frame; no faces.'
        when 'OVER_SHOULDER' then 'Over-the-shoulder shot: the camera looks past the back of one character''s head and shoulder at what is in front of them.'
        else '' end;
$function$;

-- How the speaker of a shot is staged: seen talking, heard from
-- off-screen, or seen from behind.
create or replace function m417_internal.voice_stage(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select case btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z]+', '_', 'g'), '_')
        when 'ON_CAMERA' then 'ON_CAMERA'
        when 'ON_SCREEN' then 'ON_CAMERA'
        when 'ONSCREEN' then 'ON_CAMERA'
        when 'VISIBLE' then 'ON_CAMERA'
        when 'WIDE' then 'ON_CAMERA'
        when 'OFF_SCREEN' then 'OFF_SCREEN'
        when 'OFFSCREEN' then 'OFF_SCREEN'
        when 'VOICE_OVER' then 'OFF_SCREEN'
        when 'BACK_TO_CAMERA' then 'BACK_TO_CAMERA'
        when 'BACK' then 'BACK_TO_CAMERA'
        when 'FROM_BEHIND' then 'BACK_TO_CAMERA'
        else null end;
$function$;

-- Longest spoken line (seconds of voice) a single cut can carry.
create or replace function m417_internal.max_line_seconds()
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select m417_internal.num('max_shot_edit_seconds', 4.5)
         - m417_internal.num('edit_voice_lead_seconds', 0.15)
         - m417_internal.num('edit_voice_tail_seconds', 0.35);
$function$;

-- The cut a shot gets: its planned length, made long enough for the
-- voice spoken in it.
create or replace function m417_internal.planned_cut(p_edit numeric, p_voice numeric)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select round(greatest(
        coalesce(p_edit, 0),
        case when coalesce(p_voice, 0) > 0
             then p_voice + m417_internal.num('edit_voice_lead_seconds', 0.15)
                          + m417_internal.num('edit_voice_tail_seconds', 0.35)
             else 0 end), 2);
$function$;

-- Seconds of voice a locked shot can carry in the edit. Shots planned
-- before the film rules keep the old measure: their whole duration.
create or replace function m417_internal.voice_room(p_spec_id uuid)
 returns numeric language sql stable security definer set search_path to ''
as $function$
    select case when ss.edit_seconds is null then ss.duration_seconds
           else ss.duration_seconds
                - m417_internal.num('edit_trim_lead_seconds', 0.2)
                - m417_internal.num('edit_voice_lead_seconds', 0.15)
                - m417_internal.num('edit_voice_tail_seconds', 0.35)
                - m417_internal.num('voice_duration_tolerance_seconds', 0.5) end
    from public.shot_specifications ss
    where ss.id = p_spec_id;
$function$;

-- The current script artifact of a job.
create or replace function m417_internal.current_script_id(p_job_id uuid)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select a.id from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SCRIPT' and a.is_current = true;
$function$;

-- Has this voter said YES to the current script, and not NO since?
create or replace function m417_internal.has_yes(p_job_id uuid, p_role text)
 returns boolean language sql stable security definer set search_path to ''
as $function$
    select coalesce((
        select v.decision = 'YES'
        from public.script_votes v
        where v.job_id = p_job_id
          and v.voter_role = p_role
          and v.script_artifact_id = m417_internal.current_script_id(p_job_id)
        order by v.created_at desc, v.id desc
        limit 1), false);
$function$;

-- A prop of the script by its name.
create or replace function m417_internal.script_prop(p_script jsonb, p_name text)
 returns jsonb language sql immutable set search_path to ''
as $function$
    select p.value
    from jsonb_array_elements(
        case when jsonb_typeof(p_script -> 'props') = 'array' then p_script -> 'props' else '[]'::jsonb end) p(value)
    where lower(btrim(p.value ->> 'name')) = lower(btrim(coalesce(p_name, '')))
    limit 1;
$function$;

-- ----- series bible --------------------------------------------------
create or replace function m417_internal.series_bible(p_job_id uuid)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_series public.series;
    v_profile public.production_creative_profiles;
    v_style jsonb;
    v_characters jsonb;
    v_locations jsonb;
    v_durations integer[];
    v_format jsonb;
    v_film boolean := m417_internal.film_on();
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;
    select s.* into v_series from public.series s where s.id = v_job.series_id;
    select p.* into v_profile from public.production_creative_profiles p where p.id = v_job.creative_profile_id;

    select to_jsonb(x) into v_style
    from (
        select sb.visual_style, sb.color_language, sb.lighting_language, sb.camera_language,
               sb.texture_language, sb.animation_language, sb.negative_rules
        from public.style_bibles sb
        where sb.series_id = v_series.id and sb.status <> 'ARCHIVED'
        order by sb.version desc
        limit 1
    ) x;

    select coalesce(jsonb_agg(jsonb_build_object(
               'code', c.character_code,
               'name', c.name,
               'age', c.age,
               'role', c.role_type,
               'description', c.canonical_description,
               'core_traits', c.personality -> 'core_traits',
               'weaknesses', c.personality -> 'weaknesses',
               'behavior_rules', c.behavior_rules,
               'relationships', c.relationship_rules,
               'has_voice', m417_internal.character_voice(c.id) is not null,
               'look_notes', (
                   select v.wardrobe_note
                   from public.asset_registry ar
                   join public.video_reference_images v on v.asset_id = ar.id and v.is_active = true
                   where ar.character_id = c.id and coalesce(btrim(v.wardrobe_note), '') <> ''
                   order by ar.version desc
                   limit 1),
               'reference_asset', (
                   select ar.asset_code
                   from public.asset_registry ar
                   where ar.character_id = c.id
                     and ar.asset_type = 'CHARACTER_REFERENCE'
                     and ar.status = 'LOCKED'
                   order by ar.version desc
                   limit 1)
           ) order by c.character_code), '[]'::jsonb)
    into v_characters
    from public.characters c
    where c.series_id = v_series.id
      and c.status = 'LOCKED';

    select coalesce(jsonb_agg(jsonb_build_object(
               'code', l.location_code,
               'name', l.name,
               'type', l.location_type,
               'description', left(l.canonical_description, 220),
               'reference_assets', (
                   select coalesce(jsonb_agg(ar.asset_code order by ar.asset_code), '[]'::jsonb)
                   from public.asset_registry ar
                   where ar.location_id = l.id
                     and ar.asset_type = 'LOCATION_REFERENCE'
                     and ar.status = 'LOCKED')
           ) order by l.location_code), '[]'::jsonb)
    into v_locations
    from public.locations l
    where l.series_id = v_series.id
      and l.status <> 'ARCHIVED';

    v_durations := m417_internal.allowed_shot_durations();

    v_format := jsonb_build_object(
        'production_mode', v_profile.production_mode,
        'aspect_ratio', v_profile.aspect_ratio,
        'total_duration_seconds_min', greatest(v_profile.target_duration_min_seconds, 6),
        'total_duration_seconds_target_max', v_profile.target_duration_max_seconds,
        'total_duration_seconds_hard_max', least(v_profile.hard_duration_max_seconds, 15),
        'hook_deadline_seconds', v_profile.hook_deadline_seconds,
        'allowed_shot_durations_seconds', coalesce(to_jsonb(v_durations), '"any whole number from 1 to 15"'::jsonb),
        'shot_duration_rule', 'Every shot duration must be one of allowed_shot_durations_seconds. The sum of all shot durations must lie inside the total duration limits.',
        'max_characters_per_shot', m417_internal.num('max_characters_per_shot', 3)::integer,
        'shot_cast_rule', format(
            'A shot shows at most %s characters; one or two is better. Whoever speaks in a shot is visible in it. Write scenes so that every shot works with that few characters on screen and carries one clear action; the others can be off-screen.',
            m417_internal.num('max_characters_per_shot', 3)::integer),
        'shot_package_rule', 'A shot package always contains every shot of the episode, also when it is a revision; every scene has at least one shot.',
        'video_prompt_rule', 'video_prompt is plain descriptive English for the video model: characters by their plain names, no codes, no asset names, no brackets, no spoken words.',
        'code_rule', 'Use the exact character and location codes listed here. Do not invent characters, locations or assets.',
        'dialogue_rule', 'Only characters with has_voice = true may speak.',
        'dialogue_timing_rule', format(
            'Spoken lines are checked against real speech time: about 1 second per %s characters (spaces and punctuation included) plus %s s per line, plus %s s for every sentence break inside a line (. ! ? or ... followed by more words). All lines spoken in a shot must fit inside that shot, and all lines of a scene inside that scene. A single-sentence line that fits: 2 s holds %s characters, 3 s holds %s, 4 s holds %s, 5 s holds %s. Prefer one short sentence per line; when in doubt, cut words or give the shot one more second.',
            m417_internal.num('speech_chars_per_second', 13)::text,
            m417_internal.num('speech_padding_seconds', 0.4)::text,
            m417_internal.num('speech_pause_seconds', 0.5)::text,
            m417_internal.speech_max_chars(2), m417_internal.speech_max_chars(3),
            m417_internal.speech_max_chars(4), m417_internal.speech_max_chars(5)),
        'creative_rules', v_profile.creative_rules,
        'quality_rules', v_profile.quality_rules);

    -- Under the film rules an episode is a planned edit: every shot is
    -- generated at a fixed length and the edit uses a cut out of it.
    if v_film then
        v_format := (v_format - 'total_duration_seconds_min' - 'total_duration_seconds_target_max'
                              - 'total_duration_seconds_hard_max' - 'shot_duration_rule' - 'shot_cast_rule')
            || jsonb_build_object(
                'episode_seconds_min', m417_internal.num('episode_min_seconds', 10),
                'episode_seconds_max', m417_internal.num('episode_max_seconds', 18),
                'shots_min', m417_internal.num('min_shots', 5)::integer,
                'shots_max', m417_internal.num('max_shots', 7)::integer,
                'cut_seconds_min', m417_internal.num('min_shot_edit_seconds', 0.8),
                'cut_seconds_max', m417_internal.num('max_shot_edit_seconds', 4.5),
                'hook_cut_seconds_max', m417_internal.num('hook_max_seconds', 2.5),
                'dialogue_lines_max', m417_internal.num('max_dialogue_lines', 4)::integer,
                'dialogue_line_chars_max', m417_internal.speech_max_chars(m417_internal.max_line_seconds()),
                'shot_sizes', jsonb_build_array('EXTREME_WIDE', 'WIDE', 'MEDIUM', 'MEDIUM_CLOSE', 'CLOSE_UP',
                                                'EXTREME_CLOSE_UP', 'INSERT', 'OVER_SHOULDER'),
                'voice_stagings', jsonb_build_array('ON_CAMERA', 'OFF_SCREEN', 'BACK_TO_CAMERA'),
                'shot_duration_rule', 'duration_seconds is the length the video model generates and must be one of allowed_shot_durations_seconds (use the shortest). edit_seconds is the cut the edit uses from the start of that clip, to one decimal place. The episode length is the sum of the cuts.',
                'edit_rule', 'An episode is a sequence of cuts. No two neighbouring shots have the same shot_size. At least three different sizes are used. One of the first three shots is WIDE or EXTREME_WIDE so the viewer knows where we are. At least one shot is a CLOSE_UP, EXTREME_CLOSE_UP or INSERT. The first cut is the hook.',
                'voice_rule', case when m417_internal.flag('speaker_closeup_allowed', false)
                    then 'Dialogue is cut shot by shot: at most one line is spoken in a shot, and a conversation is a chain of shots, each on the speaker or on the listener. voice_staging says how the speaker is staged: ON_CAMERA (seen talking), OFF_SCREEN (not in the shot; we watch the listener or an object) or BACK_TO_CAMERA (seen from behind).'
                    else 'Dialogue is cut shot by shot: at most one line is spoken in a shot, and a conversation is a chain of shots, each on the speaker or on the listener. voice_staging says how the speaker is staged: ON_CAMERA (seen talking, in a MEDIUM_CLOSE, MEDIUM, WIDE or EXTREME_WIDE shot), OFF_SCREEN (not in the shot; we watch the listener or an object) or BACK_TO_CAMERA (seen from behind, typically OVER_SHOULDER). Exact lip-sync is not produced yet, so nobody speaks in a CLOSE_UP or EXTREME_CLOSE_UP: those are silent looks, reactions and laughs.' end,
                'shot_cast_rule', format(
                    'A shot shows at most %s characters; one or two is better. Every shot carries one clear action.',
                    m417_internal.num('max_characters_per_shot', 3)::integer),
                'wardrobe_rule', 'The script fixes one outfit per character for the whole episode, chosen for the place and the activity, modest and suitable for a child, with no logos, brands or text. Each character has a distinct look and colour. look_notes of a character always hold.',
                'prop_rule', 'Every object that matters is a prop of the script with an exact description: colour, size, material, count. It looks the same in every shot.',
                -- Written for one-event micro shorts; a planned edit tells a small story.
                'creative_rules', v_profile.creative_rules - 'single_primary_event' - 'unnecessary_scene_changes_forbidden');
    end if;

    return jsonb_build_object(
        'series', jsonb_build_object(
            'code', v_series.series_code,
            'name', v_series.name,
            'language', v_series.primary_language,
            'target_audience', v_series.target_audience,
            'target_age_min', v_series.target_age_min,
            'target_age_max', v_series.target_age_max,
            'premise', v_series.premise,
            'world_rules', v_series.world_rules,
            'creative_rules', v_series.creative_rules,
            'forbidden_rules', v_series.forbidden_rules),
        'format', v_format,
        'style', coalesce(v_style, '{}'::jsonb),
        'characters', v_characters,
        'locations', v_locations);
end;
$function$;

-- ----- script validation --------------------------------------------
create or replace function m417_internal.validate_script(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_issues jsonb := '[]'::jsonb;
    v_scene jsonb;
    v_line jsonb;
    v_item jsonb;
    v_scene_no text;
    v_total numeric := 0;
    v_dur numeric;
    v_char uuid;
    v_scene_idx integer := 0;
    v_speech numeric;
    v_one numeric;
    v_lines integer := 0;
    v_tol numeric := m417_internal.num('voice_duration_tolerance_seconds', 0.5);
    v_film boolean := m417_internal.film_on();
    v_min numeric := 6;
    v_max numeric := 15;
    v_cast uuid[] := array[]::uuid[];
    v_dressed uuid[] := array[]::uuid[];
    v_name text;
    v_names text[] := array[]::text[];
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if v_film then
        v_min := m417_internal.num('episode_min_seconds', 10);
        v_max := m417_internal.num('episode_max_seconds', 18);
    end if;
    if jsonb_typeof(p_content -> 'scenes') is distinct from 'array'
       or jsonb_array_length(p_content -> 'scenes') = 0
    then
        return jsonb_build_array(m417_internal.issue(
            'SCRIPT', 'scenes', 'The script has no scenes array.',
            'Return the script in the required JSON shape with at least one scene.'));
    end if;
    for v_scene in select * from jsonb_array_elements(p_content -> 'scenes')
    loop
        v_scene_idx := v_scene_idx + 1;
        v_scene_no := coalesce(v_scene ->> 'scene_no', v_scene_idx::text);
        v_dur := m417_internal.safe_numeric(v_scene ->> 'duration_seconds');
        if v_dur is null or v_dur <= 0 then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no, 'duration_seconds is missing or not positive.',
                'Give every scene a positive duration in seconds.');
        else
            v_total := v_total + v_dur;
        end if;
        if coalesce(btrim(v_scene ->> 'location'), '') <> ''
           and m417_internal.resolve_location(v_job.series_id, v_scene ->> 'location') is null
        then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no,
                'Unknown location: ' || (v_scene ->> 'location'),
                'Use one of the location codes from the series bible.');
        end if;
        if v_film then
            if coalesce(btrim(v_scene ->> 'location'), '') = '' then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'scene ' || v_scene_no, 'The scene has no location.',
                    'Give every scene a location code from the series bible.');
            end if;
            if char_length(btrim(coalesce(v_scene ->> 'action', ''))) < 60 then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'scene ' || v_scene_no,
                    'action is missing or too thin to film.',
                    'Describe in at least 60 characters who is where, what exactly happens in order, and what causes what.');
            end if;
            if jsonb_typeof(v_scene -> 'characters') is distinct from 'array' then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'scene ' || v_scene_no, 'The scene has no characters array.',
                    'List the codes of every character seen or heard in the scene in characters.');
            else
                for v_name in select * from jsonb_array_elements_text(v_scene -> 'characters')
                loop
                    v_char := m417_internal.resolve_character(v_job.series_id, v_name);
                    if v_char is null then
                        v_issues := v_issues || m417_internal.issue(
                            'SCRIPT', 'scene ' || v_scene_no, 'Unknown character: ' || v_name,
                            'Use character codes from the series bible.');
                    elsif not (v_char = any (v_cast)) then
                        v_cast := v_cast || v_char;
                    end if;
                end loop;
            end if;
        end if;
        v_speech := 0;
        if jsonb_typeof(v_scene -> 'dialogue') = 'array' then
            for v_line in select * from jsonb_array_elements(v_scene -> 'dialogue')
            loop
                v_lines := v_lines + 1;
                v_one := m417_internal.speech_seconds(v_line ->> 'text');
                v_speech := v_speech + v_one;
                if coalesce(btrim(v_line ->> 'text'), '') = '' then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Dialogue line has no text.', 'Remove the line or give it text.');
                end if;
                v_char := m417_internal.resolve_character(v_job.series_id, v_line ->> 'character');
                if v_char is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Unknown speaking character: ' || coalesce(v_line ->> 'character', '(empty)'),
                        'Use a character code from the series bible.');
                elsif m417_internal.character_voice(v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        'Character has no locked voice: ' || (v_line ->> 'character'),
                        'Give the line to a character with has_voice = true.');
                end if;
                if v_film then
                    if v_char is not null and not (v_char = any (v_cast)) then
                        v_cast := v_cast || v_char;
                    end if;
                    -- One line is spoken inside one cut.
                    if v_one > m417_internal.max_line_seconds() then
                        v_issues := v_issues || m417_internal.issue(
                            'SCRIPT', 'scene ' || v_scene_no || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                            format('This line takes about %s s to say; a line is spoken inside one cut and may take at most %s s.',
                                   v_one, m417_internal.max_line_seconds()),
                            format('Shorten the line to one short sentence of at most %s characters (spaces included).',
                                   m417_internal.speech_max_chars(m417_internal.max_line_seconds())));
                    end if;
                end if;
            end loop;
        end if;
        -- Checked here, before any voice is paid for.
        if v_dur is not null and v_dur > 0 and v_speech > v_dur + v_tol then
            v_issues := v_issues || m417_internal.issue(
                'SCRIPT', 'scene ' || v_scene_no,
                format('The dialogue of this scene takes about %s s to say, but the scene lasts %s s.', v_speech, v_dur),
                format('Shorten the lines of this scene to at most %s characters in total (spaces included), or make the scene longer. See dialogue_timing_rule.',
                       m417_internal.speech_max_chars(v_dur)));
        end if;
    end loop;
    if v_total < v_min or v_total > v_max then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'total duration',
            format('Scene durations add up to %s seconds; the episode must be %s to %s seconds.', v_total, v_min, v_max),
            format('Adjust scene durations so the total is between %s and %s seconds.', v_min, v_max));
    end if;
    if not v_film then
        return v_issues;
    end if;

    -- Film rules: the script fixes everything the shots depend on.
    if char_length(btrim(coalesce(p_content ->> 'hook', ''))) < 40 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'hook', 'hook is missing or too short.',
            'In hook, describe in at least 40 characters exactly what the viewer sees and hears in the first two seconds and why they keep watching.');
    end if;
    if char_length(btrim(coalesce(p_content ->> 'payoff', ''))) < 30 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'payoff', 'payoff is missing or too short.',
            'In payoff, describe in at least 30 characters the final image or gag the episode ends on.');
    end if;
    if char_length(btrim(coalesce(p_content ->> 'look', ''))) < 20 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'look', 'look is missing or too short.',
            'In look, state the time of day, the weather and the light; it is the same in every shot.');
    end if;
    if v_lines > m417_internal.num('max_dialogue_lines', 4) then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'dialogue',
            format('The script has %s spoken lines; at most %s are allowed.', v_lines, m417_internal.num('max_dialogue_lines', 4)::integer),
            'Tell the story with pictures; keep only the lines that carry the joke.');
    end if;
    if jsonb_typeof(p_content -> 'wardrobe') is distinct from 'array' then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'wardrobe', 'The script has no wardrobe array.',
            'Add wardrobe: one entry {character, outfit} for every character of the episode.');
    else
        for v_item in select * from jsonb_array_elements(p_content -> 'wardrobe')
        loop
            v_char := m417_internal.resolve_character(v_job.series_id, v_item ->> 'character');
            if v_char is null then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'wardrobe', 'Unknown character in wardrobe: ' || coalesce(v_item ->> 'character', '(empty)'),
                    'Use character codes from the series bible.');
            elsif char_length(btrim(coalesce(v_item ->> 'outfit', ''))) < 25 then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'wardrobe', 'The outfit of ' || (v_item ->> 'character') || ' is missing or too vague.',
                    'Describe the outfit in at least 25 characters: garments, colours, shoes, anything worn or carried.');
            else
                v_dressed := v_dressed || v_char;
            end if;
        end loop;
    end if;
    for v_name in
        select c.character_code from public.characters c
        where c.id = any (v_cast) and not (c.id = any (v_dressed))
        order by c.character_code
    loop
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'wardrobe', v_name || ' appears in the episode but has no outfit in wardrobe.',
            'Add a wardrobe entry for ' || v_name || '.');
    end loop;
    if jsonb_typeof(p_content -> 'props') is distinct from 'array' then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'props', 'The script has no props array.',
            'Add props: one entry {name, description} for every object that matters (an empty array when there is none).');
    else
        for v_item in select * from jsonb_array_elements(p_content -> 'props')
        loop
            v_name := lower(btrim(coalesce(v_item ->> 'name', '')));
            if v_name = '' or char_length(btrim(coalesce(v_item ->> 'description', ''))) < 20 then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'props', 'A prop has no name or its description is too vague: ' || coalesce(nullif(v_name, ''), '(no name)'),
                    'Give every prop a short name and a description of at least 20 characters with colour, size and exact count.');
            elsif v_name = any (v_names) then
                v_issues := v_issues || m417_internal.issue(
                    'SCRIPT', 'props', 'Two props share the name ' || v_name || '.',
                    'Give every prop its own name.');
            else
                v_names := v_names || v_name;
            end if;
        end loop;
    end if;
    return v_issues;
end;
$function$;

-- ----- shot package validation ---------------------------------------
create or replace function m417_internal.validate_shot_package(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_script jsonb;
    v_issues jsonb := '[]'::jsonb;
    v_shot jsonb;
    v_beat jsonb;
    v_idx integer := 0;
    v_ref text;
    v_dur numeric;
    v_edit numeric;
    v_cut numeric;
    v_total numeric := 0;
    v_allowed integer[] := m417_internal.allowed_shot_durations();
    v_char text;
    v_line_no text;
    v_line jsonb;
    v_assigned text[] := array[]::text[];
    v_missing record;
    v_speech numeric;
    v_tol numeric := m417_internal.num('voice_duration_tolerance_seconds', 0.5);
    v_max_cast integer := m417_internal.num('max_characters_per_shot', 3)::integer;
    v_min_prompt integer := m417_internal.num('video_prompt_min_chars', 120)::integer;
    v_prompt text;
    v_cast uuid[];
    v_speaker uuid;
    v_scene record;
    v_film boolean := m417_internal.film_on();
    v_min numeric := 6;
    v_max numeric := 15;
    v_max_shots integer := 6;
    v_size text;
    v_prev_size text;
    v_sizes text[] := array[]::text[];
    v_stage text;
    v_line_count integer;
    v_at numeric;
    v_prev_at numeric;
    v_beats integer;
    v_prop text;
    v_trim numeric := m417_internal.num('edit_trim_lead_seconds', 0.2);
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    v_script := m417_internal.artifact(p_job_id, 'SCRIPT');
    if v_film then
        v_min := m417_internal.num('episode_min_seconds', 10);
        v_max := m417_internal.num('episode_max_seconds', 18);
        v_max_shots := m417_internal.num('max_shots', 7)::integer;
        v_min_prompt := m417_internal.num('film_video_prompt_min_chars', 200)::integer;
    end if;
    if jsonb_typeof(p_content -> 'shots') is distinct from 'array'
       or jsonb_array_length(p_content -> 'shots') = 0
    then
        return jsonb_build_array(m417_internal.issue(
            'SHOTS', 'shots', 'The shot package has no shots array.',
            'Return the shot package in the required JSON shape with at least one shot.'));
    end if;
    if jsonb_array_length(p_content -> 'shots') > v_max_shots then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'shots', format('More than %s shots.', v_max_shots), format('Use at most %s shots.', v_max_shots));
    end if;
    if v_film and jsonb_array_length(p_content -> 'shots') < m417_internal.num('min_shots', 5) then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'shots',
            format('Only %s shots; an episode is cut from at least %s.', jsonb_array_length(p_content -> 'shots'), m417_internal.num('min_shots', 5)::integer),
            'Break the action into more shots: establish the place, show the action, cut to reactions and details.');
    end if;
    for v_shot in select * from jsonb_array_elements(p_content -> 'shots')
    loop
        v_idx := v_idx + 1;
        v_ref := 'shot ' || coalesce(v_shot ->> 'shot_no', v_idx::text);
        v_dur := m417_internal.safe_numeric(v_shot ->> 'duration_seconds');
        if v_dur is null or v_dur < 1 or v_dur > 15 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'duration_seconds is missing or outside 1 to 15.',
                'Give the shot a duration from allowed_shot_durations_seconds.');
        else
            if not v_film then
                v_total := v_total + v_dur;
            end if;
            if v_allowed is not null
               and (v_dur <> trunc(v_dur) or not (v_dur::integer = any (v_allowed)))
            then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    'Duration ' || v_dur || ' is not supported by the video model. Allowed: ' || array_to_string(v_allowed, ', '),
                    'Use one of the allowed shot durations.');
            end if;
        end if;
        -- The video prompt is what the video model reads: it has to be
        -- real description, not a template or a list of codes.
        v_prompt := btrim(coalesce(v_shot ->> 'video_prompt', ''));
        if v_prompt = '' then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'video_prompt is empty.', 'Write the video prompt for this shot.');
        else
            if v_prompt ~ '[<>]' then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'video_prompt contains angle brackets or a placeholder such as <PROMPT: ...>.',
                    'Write video_prompt as plain descriptive English without brackets or placeholders.');
            end if;
            if v_prompt ~ '\m(CHR|LOC)_[A-Z0-9_]+' or v_prompt ~ '\m[A-Z][A-Z0-9]*(_[A-Z0-9]+)*_V[0-9]+\M' then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'video_prompt contains codes or asset names; the video model does not understand them.',
                    'Call characters by their plain names (for example Mia) and describe the place in words. Codes belong only in characters, location and reference_assets.');
            end if;
            if char_length(v_prompt) < v_min_prompt then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('video_prompt is only %s characters long; at least %s are needed.', char_length(v_prompt), v_min_prompt),
                    'Describe framing and camera, where each character is, what they do beat by beat, their expressions and body language, the place and the light.');
            end if;
        end if;
        v_cast := array[]::uuid[];
        if jsonb_typeof(v_shot -> 'characters') = 'array' then
            for v_char in select * from jsonb_array_elements_text(v_shot -> 'characters')
            loop
                if m417_internal.resolve_character(v_job.series_id, v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref, 'Unknown character: ' || v_char,
                        'Use character codes from the series bible.');
                elsif not (m417_internal.resolve_character(v_job.series_id, v_char) = any (v_cast)) then
                    v_cast := v_cast || m417_internal.resolve_character(v_job.series_id, v_char);
                end if;
            end loop;
        end if;
        if coalesce(btrim(v_shot ->> 'location'), '') <> ''
           and m417_internal.resolve_location(v_job.series_id, v_shot ->> 'location') is null
        then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'Unknown location: ' || (v_shot ->> 'location'),
                'Use a location code from the series bible.');
        end if;

        v_size := m417_internal.film_size(v_shot ->> 'shot_size');
        v_stage := m417_internal.voice_stage(v_shot ->> 'voice_staging');
        v_speech := 0;
        v_line_count := 0;
        if jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array' then
            for v_line_no in select * from jsonb_array_elements_text(v_shot -> 'dialogue_line_nos')
            loop
                v_line_count := v_line_count + 1;
                v_line := m417_internal.script_line(v_script, v_shot ->> 'scene_no', v_line_no);
                v_speech := v_speech + m417_internal.speech_seconds(v_line ->> 'text');
                if v_line is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref,
                        'dialogue_line_nos refers to line ' || v_line_no || ', which is not in scene ' || coalesce(v_shot ->> 'scene_no', '?') || ' of the script.',
                        'Reference only line numbers that exist in the script scene of this shot.');
                else
                    v_assigned := v_assigned || ((v_line ->> 'scene_no') || ':' || (v_line ->> 'line_no'));
                    v_speaker := m417_internal.resolve_character(v_job.series_id, v_line ->> 'character');
                    if not v_film then
                        -- Whoever speaks in a shot is seen in it.
                        if v_speaker is not null and not (v_speaker = any (v_cast)) then
                            v_cast := v_cast || v_speaker;
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'Line ' || v_line_no || ' is spoken by ' || (v_line ->> 'character') || ', who is not listed in characters of this shot.',
                                'Add the speaker to characters of this shot, or move the line to a shot of the same scene in which the speaker is visible.');
                        end if;
                    elsif v_speaker is not null then
                        -- The speaker's mouth is never seen.
                        if v_stage is null then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'A line is spoken in this shot but voice_staging is missing or unknown.',
                                'Set voice_staging to ON_CAMERA, OFF_SCREEN or BACK_TO_CAMERA. See voice_rule.');
                        elsif v_stage = 'OFF_SCREEN' and v_speaker = any (v_cast) then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'voice_staging is OFF_SCREEN but the speaker ' || (v_line ->> 'character') || ' is listed in characters.',
                                'Take the speaker out of characters and show the listener or an object, or use ON_CAMERA or BACK_TO_CAMERA.');
                        elsif v_stage in ('BACK_TO_CAMERA', 'ON_CAMERA') and not (v_speaker = any (v_cast)) then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'voice_staging is ' || v_stage || ' but the speaker ' || (v_line ->> 'character') || ' is not listed in characters.',
                                'Add the speaker to characters, or use OFF_SCREEN.');
                        elsif v_stage = 'ON_CAMERA' and v_size in ('CLOSE_UP', 'EXTREME_CLOSE_UP', 'INSERT')
                              and m417_internal.flag('speaker_closeup_allowed', false) is not true then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'A line is spoken ON_CAMERA in a ' || v_size || ' shot; exact lip-sync is not produced yet, so nobody speaks in a close shot.',
                                'Frame the speaker MEDIUM_CLOSE or wider, or keep the close shot on the listener and stage the line OFF_SCREEN.');
                        elsif v_stage = 'BACK_TO_CAMERA' and v_size in ('CLOSE_UP', 'EXTREME_CLOSE_UP', 'INSERT') then
                            v_issues := v_issues || m417_internal.issue(
                                'SHOTS', v_ref,
                                'voice_staging BACK_TO_CAMERA does not work in a ' || v_size || ' shot.',
                                'Use OVER_SHOULDER, MEDIUM or WIDE for a speaker seen from behind, or stage the line OFF_SCREEN.');
                        end if;
                    end if;
                end if;
            end loop;
        end if;
        if cardinality(v_cast) > v_max_cast then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref,
                format('%s characters are in this shot; at most %s can be shown.', cardinality(v_cast), v_max_cast),
                format('Show at most %s characters in a shot: frame the ones that matter for this beat and keep the others off-screen, or split the scene into more shots.', v_max_cast));
        end if;

        if not v_film then
            if v_dur is not null and v_dur >= 1 and v_speech > v_dur + v_tol then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('The lines spoken in this shot take about %s s to say, but the shot lasts %s s.', v_speech, v_dur),
                    format('Give this shot at least %s s (an allowed duration), or move one of its lines to a neighbouring shot of the same scene. Do not change the script text.',
                           ceil(v_speech - v_tol)));
            end if;
            continue;
        end if;

        -- Film rules for one shot ------------------------------------
        if v_size is null then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'shot_size is missing or unknown: ' || coalesce(v_shot ->> 'shot_size', '(empty)'),
                'Set shot_size to one of shot_sizes in the series bible.');
        else
            if v_prev_size is not null and v_prev_size = v_size then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'This shot has the same shot_size (' || v_size || ') as the shot before it.',
                    'Change the size of one of the two: a cut needs a clear change of framing.');
            end if;
            v_sizes := v_sizes || v_size;
        end if;
        v_prev_size := v_size;
        if v_line_count > 1 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, format('%s lines are spoken in this shot; at most one is allowed.', v_line_count),
                'Give every spoken line its own shot.');
        end if;
        v_edit := m417_internal.safe_numeric(v_shot ->> 'edit_seconds');
        if v_edit is null
           or v_edit < m417_internal.num('min_shot_edit_seconds', 0.8)
           or v_edit > m417_internal.num('max_shot_edit_seconds', 4.5)
        then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref,
                'edit_seconds is missing or outside the allowed cut length: ' || coalesce(v_shot ->> 'edit_seconds', '(empty)'),
                format('Give the shot an edit_seconds between %s and %s.',
                       m417_internal.num('min_shot_edit_seconds', 0.8), m417_internal.num('max_shot_edit_seconds', 4.5)));
        else
            v_cut := m417_internal.planned_cut(v_edit, v_speech);
            if v_dur is not null and v_cut > v_dur - v_trim then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('The cut needs %s s but the generated clip gives only %s s.', v_cut, v_dur - v_trim),
                    'Shorten edit_seconds, or move the spoken line to another shot.');
            end if;
            if v_idx = 1 and v_cut > m417_internal.num('hook_max_seconds', 2.5) then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref,
                    format('The first cut lasts %s s; the hook must be over in %s s.', v_cut, m417_internal.num('hook_max_seconds', 2.5)),
                    'Open on the most striking image of the episode in a short cut; a line spoken in it must be a word or two.');
            end if;
            v_total := v_total + v_cut;
            -- Timed beats: what happens when inside the cut.
            v_beats := 0;
            v_prev_at := null;
            if jsonb_typeof(v_shot -> 'beats') = 'array' then
                for v_beat in select * from jsonb_array_elements(v_shot -> 'beats')
                loop
                    v_beats := v_beats + 1;
                    v_at := m417_internal.safe_numeric(v_beat ->> 'at');
                    if v_at is null or v_at < 0 or v_at >= v_cut
                       or (v_prev_at is not null and v_at <= v_prev_at)
                       or (v_beats = 1 and v_at <> 0)
                    then
                        v_issues := v_issues || m417_internal.issue(
                            'SHOTS', v_ref, format('Beat %s has a wrong time: %s.', v_beats, coalesce(v_beat ->> 'at', '(empty)')),
                            'Beat times are seconds from the start of the cut: the first is 0, each later one is larger, all are inside the cut.');
                    end if;
                    v_prev_at := coalesce(v_at, v_prev_at);
                    if char_length(btrim(coalesce(v_beat ->> 'what', ''))) < m417_internal.num('min_beat_chars', 15) then
                        v_issues := v_issues || m417_internal.issue(
                            'SHOTS', v_ref, format('Beat %s does not say what happens.', v_beats),
                            'In what, say exactly who does what at that moment.');
                    end if;
                end loop;
            end if;
            if v_beats = 0 then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'The shot has no beats.',
                    'Add beats: [{at, what}] - at least one, the first at 0 - timing the action inside the cut to a tenth of a second.');
            end if;
        end if;
        if jsonb_typeof(v_shot -> 'props') = 'array' then
            for v_prop in select * from jsonb_array_elements_text(v_shot -> 'props')
            loop
                if m417_internal.script_prop(v_script, v_prop) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref, 'Unknown prop: ' || v_prop,
                        'List in props only names from props of the script.');
                end if;
            end loop;
        end if;
    end loop;

    if v_film then
        if (select count(distinct s) from unnest(v_sizes) s) < 3 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shots', 'Fewer than three different shot sizes are used.',
                'Vary the framing: wide to show the place, medium for action, close for reactions and details.');
        end if;
        if not exists (select 1 from unnest(v_sizes[1:3]) s where s in ('WIDE', 'EXTREME_WIDE')) then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shots', 'None of the first three shots is WIDE or EXTREME_WIDE.',
                'Show where we are early: make one of the first three shots a wide view of the place.');
        end if;
        if not exists (select 1 from unnest(v_sizes) s where s in ('CLOSE_UP', 'EXTREME_CLOSE_UP', 'INSERT')) then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shots', 'No close shot is used.',
                'Add at least one CLOSE_UP, EXTREME_CLOSE_UP or INSERT: a face reacting or the detail that matters.');
        end if;
    end if;
    if v_total < v_min or v_total > v_max then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'total duration',
            case when v_film
                 then format('The cuts add up to %s seconds; the episode must be %s to %s seconds.', v_total, v_min, v_max)
                 else 'Shot durations add up to ' || v_total || ' seconds; the episode must be 6 to 15 seconds.' end,
            case when v_film
                 then format('Change the number of shots or their edit_seconds so the total is between %s and %s seconds. A shot with a spoken line lasts at least as long as the line plus half a second.', v_min, v_max)
                 else 'Change the number of shots or their durations so the total is between 6 and 15 seconds.' end);
    end if;
    -- Every scene of the script needs at least one shot: a package is
    -- always the whole episode, also when it is a revision.
    for v_scene in
        select coalesce(sc.scene ->> 'scene_no', sc.idx::text) as scene_no
        from jsonb_array_elements(coalesce(v_script -> 'scenes', '[]'::jsonb)) with ordinality as sc(scene, idx)
        where not exists (
            select 1 from jsonb_array_elements(p_content -> 'shots') sh(value)
            where sh.value ->> 'scene_no' = coalesce(sc.scene ->> 'scene_no', sc.idx::text))
    loop
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'scene ' || v_scene.scene_no,
            'Scene ' || v_scene.scene_no || ' of the script has no shot.',
            'Return the complete shot package: every scene needs at least one shot, and shots that did not change must be included again.');
    end loop;
    -- Every scripted line must be spoken in exactly one shot.
    for v_missing in
        select coalesce(s.scene ->> 'scene_no', s.idx::text) as scene_no,
               coalesce(l.line ->> 'line_no', l.idx::text) as line_no
        from jsonb_array_elements(coalesce(v_script -> 'scenes', '[]'::jsonb)) with ordinality as s(scene, idx)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(s.scene -> 'dialogue') = 'array'
                 then s.scene -> 'dialogue' else '[]'::jsonb end
        ) with ordinality as l(line, idx)
    loop
        if not ((v_missing.scene_no || ':' || v_missing.line_no) = any (v_assigned)) then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'scene ' || v_missing.scene_no || ' line ' || v_missing.line_no,
                'This script line is not assigned to any shot.',
                'Add the line number to dialogue_line_nos of the shot in which it is spoken.');
        end if;
    end loop;
    if (select count(*) from unnest(v_assigned) a) <> (select count(distinct a) from unnest(v_assigned) a) then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'dialogue_line_nos', 'A script line is assigned to more than one shot.',
            'Assign every script line to exactly one shot.');
    end if;
    return v_issues;
end;
$function$;

-- ----- the prompt of a film shot -------------------------------------
-- What the video model reads for a planned shot: framing, the action
-- with its timing, who talks, then the wardrobe, props and look fixed by
-- the script - worded the same way in every shot of the episode - and
-- last the series style. When the text has to be cut, the end goes.
create or replace function m417_internal.compose_shot_prompt(
    p_series_id uuid, p_script jsonb, p_shot jsonb, p_character_ids uuid[],
    p_location_id uuid, p_speaker_id uuid, p_cut numeric)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_parts text[] := array[]::text[];
    v_text text;
    v_n integer := coalesce(cardinality(p_character_ids), 0);
    v_size text := m417_internal.film_size(p_shot ->> 'shot_size');
    v_stage text := m417_internal.voice_stage(p_shot ->> 'voice_staging');
    v_speaker text;
    v_window numeric;
begin
    v_parts := v_parts || m417_internal.film_size_sentence(v_size);
    v_parts := v_parts || left(btrim(coalesce(p_shot ->> 'video_prompt', '')), 800);

    select string_agg(
               'at ' || to_char(coalesce(m417_internal.safe_numeric(b.value ->> 'at'), 0), 'FM990.0') || ' s '
               || rtrim(left(btrim(coalesce(b.value ->> 'what', '')), 160), '. '),
               '; ' order by b.ord)
    into v_text
    from jsonb_array_elements(
        case when jsonb_typeof(p_shot -> 'beats') = 'array' then p_shot -> 'beats' else '[]'::jsonb end
    ) with ordinality as b(value, ord);
    v_window := ceil((coalesce(p_cut, 0) + m417_internal.num('edit_trim_lead_seconds', 0.2)) * 2) / 2;
    if v_text is not null then
        v_parts := v_parts || format(
            'Timing: %s. The action starts immediately and all of it happens within the first %s seconds; after that everyone holds the final pose.',
            v_text, to_char(v_window, 'FM990.0'));
    end if;

    select c.name into v_speaker from public.characters c where c.id = p_speaker_id;
    v_parts := v_parts || case
        when v_speaker is null then
            'Nobody speaks in this shot: no talking mouth movements. Feelings show in the eyes, eyebrows and body, in a smile, a gasp or a laugh.'
        when v_stage = 'ON_CAMERA' then
            v_speaker || ' is talking from the first moment of the shot, mouth moving naturally, with matching gestures. Nobody else talks: their mouths stay closed while they listen.'
        when v_stage = 'BACK_TO_CAMERA' then
            v_speaker || ' is talking but is seen only from behind, the back of the head and the shoulders; the face of ' || v_speaker || ' is never visible. Nobody else talks: their mouths stay closed while they listen.'
        else
            'A voice is heard from off-screen. Nobody visible talks: their mouths stay closed while they listen and react.'
        end;

    if coalesce(btrim(p_shot ->> 'acting'), '') <> '' then
        v_parts := v_parts || ('Acting: ' || left(btrim(p_shot ->> 'acting'), 180));
    end if;
    if coalesce(btrim(p_shot ->> 'camera'), '') <> '' then
        v_parts := v_parts || ('Camera: ' || left(btrim(p_shot ->> 'camera'), 150));
    end if;

    select string_agg(c.name || ' wears ' || rtrim(left(btrim(w.value ->> 'outfit'), 170), '. '),
                      '. ' order by c.character_code)
    into v_text
    from jsonb_array_elements(
        case when jsonb_typeof(p_script -> 'wardrobe') = 'array' then p_script -> 'wardrobe' else '[]'::jsonb end) w(value)
    join public.characters c
      on c.id = m417_internal.resolve_character(p_series_id, w.value ->> 'character')
    where c.id = any (coalesce(p_character_ids, array[]::uuid[]));
    if v_text is not null then
        v_parts := v_parts || ('Wardrobe in this episode, the same in every shot: ' || v_text || '.');
    end if;

    select string_agg(rtrim(left(btrim(m417_internal.script_prop(p_script, n.value) ->> 'description'), 150), '. '),
                      '; ' order by n.ord)
    into v_text
    from jsonb_array_elements_text(
        case when jsonb_typeof(p_shot -> 'props') = 'array' then p_shot -> 'props' else '[]'::jsonb end
    ) with ordinality as n(value, ord)
    where m417_internal.script_prop(p_script, n.value) is not null;
    if v_text is not null then
        v_parts := v_parts || ('Props, exactly as described and no extra copies: ' || v_text || '.');
    end if;

    if coalesce(btrim(p_script ->> 'look'), '') <> '' then
        v_parts := v_parts || ('Look: ' || rtrim(left(btrim(p_script ->> 'look'), 160), '. ') || '.');
    end if;
    if v_n >= 2 and m417_internal.txt('cast_rule_text', '') <> '' then
        v_parts := v_parts || m417_internal.txt('cast_rule_text', '');
    end if;
    v_parts := v_parts || 'Vertical 9:16 framing. No on-screen text, subtitles, logos or watermarks.'::text;

    select left(coalesce(sb.visual_style, ''), 220) into v_text
    from public.style_bibles sb
    where sb.series_id = p_series_id and sb.status <> 'ARCHIVED'
    order by sb.version desc
    limit 1;
    if coalesce(v_text, '') <> '' then
        v_parts := v_parts || ('Style. ' || v_text);
    end if;
    select l.name || ': ' || left(coalesce(l.canonical_description, ''), 180) into v_text
    from public.locations l where l.id = p_location_id;
    if v_text is not null then
        v_parts := v_parts || ('Location. ' || v_text);
    end if;
    select string_agg(c.name || ': ' || left(coalesce(c.canonical_description, ''), 120),
                      ' ' order by c.character_code)
    into v_text
    from public.characters c
    where c.id = any (coalesce(p_character_ids, array[]::uuid[]));
    if v_text is not null then
        v_parts := v_parts || ('Characters. ' || v_text);
    end if;
    return left(regexp_replace(array_to_string(v_parts, ' '), '[[:space:]]+', ' ', 'g'), 2400);
end;
$function$;

-- What the visual reviewer is told about a film shot.
create or replace function m417_internal.shot_qc_brief(
    p_series_id uuid, p_script jsonb, p_shot jsonb, p_character_ids uuid[], p_speaker_id uuid, p_cut numeric)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'shot_size', m417_internal.film_size(p_shot ->> 'shot_size'),
        'purpose', p_shot ->> 'purpose',
        'used_seconds', format(
            'The edit uses only about the first %s seconds of this clip. Judge those; what happens later does not matter.',
            to_char(ceil((coalesce(p_cut, 0) + m417_internal.num('edit_trim_lead_seconds', 0.2)) * 2) / 2, 'FM990.0')),
        'beats', case when jsonb_typeof(p_shot -> 'beats') = 'array' then p_shot -> 'beats' else '[]'::jsonb end,
        'speaker', (select c.name from public.characters c where c.id = p_speaker_id),
        'voice_staging', case when p_speaker_id is null then null
                              else m417_internal.voice_stage(p_shot ->> 'voice_staging') end,
        'mouth_rule', case when p_speaker_id is null
            then 'Nobody speaks in this shot. A character clearly talking is a defect; a gasp, a smile or a laugh is not.'
            else 'Only the speaker may be talking. The voice is added in the edit; exact lip-sync is not expected and is not a defect.' end,
        'wardrobe', coalesce((
            select jsonb_agg(jsonb_build_object('name', c.name, 'outfit', w.value ->> 'outfit') order by c.character_code)
            from jsonb_array_elements(
                case when jsonb_typeof(p_script -> 'wardrobe') = 'array' then p_script -> 'wardrobe' else '[]'::jsonb end) w(value)
            join public.characters c
              on c.id = m417_internal.resolve_character(p_series_id, w.value ->> 'character')
            where c.id = any (coalesce(p_character_ids, array[]::uuid[]))), '[]'::jsonb),
        'props', coalesce((
            select jsonb_agg(m417_internal.script_prop(p_script, n.value))
            from jsonb_array_elements_text(
                case when jsonb_typeof(p_shot -> 'props') = 'array' then p_shot -> 'props' else '[]'::jsonb end) n(value)
            where m417_internal.script_prop(p_script, n.value) is not null), '[]'::jsonb),
        'look', p_script ->> 'look',
        'cast_rule', m417_internal.txt('cast_rule_text', ''),
        'also_report', 'Add to details the field action_start_seconds: the second (a number) at which the described action visibly starts in this clip.');
$function$;

-- ----- reference images ----------------------------------------------
-- Reference images of a shot that a provider can fetch: the shot's
-- canonical references that have a public copy, in reference order.
-- Each element: {"n": 1, "role": "CHARACTER", "name": "Mia", "url": "https://...", "note": null}.
create or replace function m417_internal.shot_reference_images(p_spec_id uuid, p_limit integer)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select coalesce(jsonb_agg(jsonb_build_object(
               'n', x.n, 'role', x.reference_role, 'name', x.name, 'url', x.url,
               'note', x.note) order by x.n), '[]'::jsonb)
    from (
        select row_number() over (order by sra.reference_order, ar.asset_code) as n,
               sra.reference_role,
               coalesce(c.name, l.name, ar.asset_code) as name,
               nullif(btrim(coalesce(v.wardrobe_note, '')), '') as note,
               rtrim(m417_internal.txt('storage_base_url', ''), '/')
                   || '/object/public/' || v.bucket || '/' || v.object_path as url
        from public.shot_reference_assets sra
        join public.asset_registry ar on ar.id = sra.asset_id
        join public.video_reference_images v on v.asset_id = ar.id and v.is_active = true
        left join public.characters c on c.id = ar.character_id
        left join public.locations l on l.id = ar.location_id
        where sra.shot_specification_id = p_spec_id
          and sra.reference_role in ('CHARACTER', 'LOCATION')
          and m417_internal.txt('storage_base_url', '') <> ''
        order by sra.reference_order, ar.asset_code
        limit greatest(coalesce(p_limit, 4), 0)
    ) x;
$function$;

-- The complete request body for the provider. Make forwards it as is.
create or replace function m417_internal.build_provider_request(p_attempt_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_row record;
    v_route text;
    v_defaults jsonb;
    v_params jsonb;
    v_task text;
    v_refs jsonb;
    v_names text;
    v_notes text;
    v_lead text;
    v_fix text;
    v_tail text;
    v_input jsonb;
    v_max integer;
begin
    select a.provider, a.model, a.shot_id, gm.model_version, gm.capability_metadata,
           ss.id as spec_id, ss.generation_prompt, ss.negative_prompt, ss.aspect_ratio,
           ss.duration_seconds, ss.resolution, ss.edit_seconds
    into v_row
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    join public.generation_models gm on gm.id = grd.selected_model_id
    join public.shot_specifications ss on ss.id = grd.shot_specification_id
    where a.id = p_attempt_id;
    if not found then
        raise exception 'ATTEMPT_NOT_FOUND';
    end if;
    v_route := m417_internal.provider_route(v_row.provider);
    v_defaults := case when jsonb_typeof(v_row.capability_metadata -> 'request_defaults') = 'object'
                       then v_row.capability_metadata -> 'request_defaults' else '{}'::jsonb end;
    v_task := coalesce(v_row.capability_metadata ->> 'task_type', 'video_generation');

    if v_route = 'KLING' and v_task = 'omni_video_generation' then
        -- Kling Omni: reference images go in input.images and are named
        -- in the prompt as @image_1, @image_2 ... in list order. It has
        -- no negative_prompt field, so the short "Avoid" list is part of
        -- the prompt. The whole prompt stays inside 2500 characters.
        v_max := coalesce(nullif(v_row.capability_metadata ->> 'max_reference_images', '')::integer, 4);
        v_refs := m417_internal.shot_reference_images(v_row.spec_id, v_max);
        v_lead := '';
        if jsonb_array_length(v_refs) > 0 then
            select string_agg(
                       '@image_' || (r.value ->> 'n') || ' is '
                       || case when r.value ->> 'role' = 'LOCATION'
                               then 'the location ' || (r.value ->> 'name')
                               else r.value ->> 'name' end,
                       ', ' order by (r.value ->> 'n')::integer),
                   string_agg(r.value ->> 'note', ' ' order by (r.value ->> 'n')::integer)
                       filter (where r.value ->> 'note' is not null)
            into v_names, v_notes
            from jsonb_array_elements(v_refs) r(value);
            v_lead := 'Reference images: ' || v_names
                   || '. A character reference image shows one single character, sometimes in more than one view.'
                   || ' Keep every character''s face, hair, skin tone, age and body proportions exactly as in their reference image;'
                   || ' the outfit follows the wardrobe given below, or the reference image when none is given.'
                   || case when v_notes is null then '' else ' ' || v_notes end
                   || ' Exactly one of each named character. One continuous shot, never a collage or a split screen. ';
        end if;
        -- A take that was rejected tells the next one what to avoid.
        if v_row.edit_seconds is not null then
            select ' Correction: an earlier take of this shot was rejected because: '
                   || rtrim(left(regexp_replace(btrim(go.qc_notes), '[[:space:]]+', ' ', 'g'), 260), '. ')
                   || '. Do not repeat this. '
            into v_fix
            from public.generation_outputs go
            where go.shot_id = v_row.shot_id
              and go.qc_status = 'FAIL'
              and coalesce(btrim(go.qc_notes), '') <> ''
            order by go.created_at desc
            limit 1;
        end if;
        v_lead := v_lead || coalesce(v_fix, '');
        v_tail := case when coalesce(btrim(v_row.negative_prompt), '') <> ''
                       then ' Avoid: ' || left(btrim(v_row.negative_prompt), 300) else '' end;
        v_input := jsonb_build_object(
            'prompt', v_lead
                      || left(v_row.generation_prompt, greatest(2500 - length(v_lead) - length(v_tail), 200))
                      || v_tail,
            'version', coalesce(v_row.model_version, '3.0'),
            'resolution', coalesce(v_row.capability_metadata ->> 'resolution', '720p'),
            'duration', v_row.duration_seconds::integer,
            'aspect_ratio', v_row.aspect_ratio,
            'enable_audio', false);
        if jsonb_array_length(v_refs) > 0 then
            v_input := v_input || jsonb_build_object(
                'images', (select jsonb_agg(r.value ->> 'url' order by (r.value ->> 'n')::integer)
                           from jsonb_array_elements(v_refs) r(value)));
        end if;
        return jsonb_build_object(
            'model', coalesce(v_row.capability_metadata ->> 'api_model', 'kling'),
            'task_type', v_task,
            'input', v_input || v_defaults)::text;
    elsif v_route = 'KLING' then
        return jsonb_build_object(
            'model', coalesce(v_row.capability_metadata ->> 'api_model', 'kling'),
            'task_type', v_task,
            'input', jsonb_build_object(
                'prompt', v_row.generation_prompt,
                'negative_prompt', coalesce(v_row.negative_prompt, ''),
                'aspect_ratio', v_row.aspect_ratio,
                'duration', v_row.duration_seconds::integer,
                'version', coalesce(v_row.model_version, '2.6'),
                'mode', coalesce(v_row.capability_metadata ->> 'mode', 'std'),
                'enable_audio', false) || v_defaults)::text;
    elsif v_route = 'VEO' then
        v_params := jsonb_build_object(
            'aspectRatio', v_row.aspect_ratio,
            'durationSeconds', v_row.duration_seconds::integer);
        if coalesce(btrim(v_row.negative_prompt), '') <> '' then
            v_params := v_params || jsonb_build_object('negativePrompt', v_row.negative_prompt);
        end if;
        if v_row.resolution in ('720p', '1080p') then
            v_params := v_params || jsonb_build_object('resolution', v_row.resolution);
        end if;
        return jsonb_build_object(
            'instances', jsonb_build_array(jsonb_build_object('prompt', v_row.generation_prompt)),
            'parameters', v_params || v_defaults)::text;
    end if;
    raise exception 'PROVIDER_ROUTE_NOT_SUPPORTED: % (%)', v_row.provider, v_route;
end;
$function$;

-- ----- the edit ------------------------------------------------------
-- Everything the edit is made of, in order, with its storage path.
-- A film shot contributes a cut out of its clip: the planned length,
-- made long enough for the voice spoken in it, starting where the
-- reviewer saw the action begin. Older shots are used whole.
create or replace function m417_internal.edit_list(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    with job as (
        select j.episode_id from public.production_jobs j where j.id = p_job_id
    ),
    cfg as (
        select m417_internal.num('edit_voice_lead_seconds', 0.15) as lead,
               m417_internal.num('edit_voice_tail_seconds', 0.35) as tail,
               m417_internal.num('edit_trim_lead_seconds', 0.2) as trim_lead
    ),
    base as (
        select s.id, s.shot_order, s.shot_code, ss.id as spec_id, ss.duration_seconds, ss.edit_seconds,
               go.storage_path,
               coalesce(m417_internal.safe_numeric(go.qc_details ->> 'action_start_seconds'),
                        m417_internal.safe_numeric(go.qc_details -> 'details' ->> 'action_start_seconds')) as action_at,
               (select coalesce(sum(sap.duration_seconds), 0) + 0.1 * greatest(count(*) - 1, 0)
                from public.shot_audio_productions sap
                where sap.shot_specification_id = ss.id and sap.is_canonical = true) as voice_seconds
        from job
        join public.shots s on s.episode_id = job.episode_id and s.state = 'LOCKED'
        join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
        join public.generation_outputs go on go.shot_id = s.id and go.is_canonical = true
    ),
    cut as (
        select b.*,
               case when b.edit_seconds is null then b.duration_seconds
                    else round(least(
                        greatest(b.edit_seconds,
                                 case when b.voice_seconds > 0 then b.voice_seconds + cfg.lead + cfg.tail else 0 end),
                        b.duration_seconds - cfg.trim_lead), 2) end as length
        from base b cross join cfg
    ),
    shots as (
        select c.*,
               case when c.edit_seconds is null then 0
                    else round(greatest(least(coalesce(c.action_at - 0.1, cfg.trim_lead),
                                              c.duration_seconds - c.length), 0), 2) end as trim,
               coalesce(sum(c.length) over (order by c.shot_order
                   rows between unbounded preceding and 1 preceding), 0) as start_at
        from cut c cross join cfg
    ),
    voices as (
        select sh.shot_order, sap.audio_order, sap.storage_path, sap.duration_seconds,
               sh.start_at + cfg.lead
                 + coalesce(sum(sap.duration_seconds + 0.1) over (
                       partition by sh.id order by sap.audio_order
                       rows between unbounded preceding and 1 preceding), 0) as start_at
        from shots sh
        cross join cfg
        join public.shot_audio_productions sap
          on sap.shot_specification_id = sh.spec_id and sap.is_canonical = true
    ),
    music as (
        select mt.track_code, jmt.role, mt.storage_path, jmt.start_seconds, jmt.end_seconds, jmt.volume
        from public.job_music_tracks jmt
        join public.music_tracks mt on mt.id = jmt.track_id
        where jmt.job_id = p_job_id
    )
    select jsonb_build_object(
        'shots', coalesce((select jsonb_agg(jsonb_build_object(
                     'shot_code', shot_code, 'path', storage_path, 'start', start_at,
                     'length', length, 'trim', trim) order by shot_order) from shots), '[]'::jsonb),
        'voices', coalesce((select jsonb_agg(jsonb_build_object(
                     'path', storage_path, 'start', round(start_at, 3), 'length', duration_seconds)
                     order by shot_order, audio_order) from voices), '[]'::jsonb),
        'music', coalesce((select jsonb_agg(jsonb_build_object(
                     'track_code', track_code, 'role', role, 'path', storage_path,
                     'start', start_seconds, 'end', end_seconds, 'volume', volume)
                     order by start_seconds) from music), '[]'::jsonb),
        'total_seconds', coalesce((select sum(length) from shots), 0));
$function$;

-- ----- owner tools ---------------------------------------------------
-- The owner states what always holds for a character in generated video
-- (eye colour, height, a default outfit). An empty note removes it.
create or replace function public.set_video_wardrobe(p_asset_code text, p_note text, p_actor text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_asset_id uuid;
    v_note text := nullif(btrim(regexp_replace(coalesce(p_note, ''), '[[:space:]]+', ' ', 'g')), '');
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    if char_length(coalesce(v_note, '')) > 300 then
        raise exception 'WARDROBE_NOTE_TOO_LONG: at most 300 characters';
    end if;
    select v.asset_id into v_asset_id
    from public.video_reference_images v
    join public.asset_registry ar on ar.id = v.asset_id
    where ar.asset_code = p_asset_code;
    if not found then
        raise exception 'VIDEO_REFERENCE_NOT_FOUND: %', coalesce(p_asset_code, '(empty)');
    end if;
    update public.video_reference_images
    set wardrobe_note = v_note, updated_at = now()
    where asset_id = v_asset_id;
    insert into public.events (event_type, severity, source, message, metadata)
    values ('VIDEO_WARDROBE_SET', 'INFO', 'CONTROL_PLANE',
            'Video character note set for ' || p_asset_code || ' by ' || p_actor,
            jsonb_build_object('asset_code', p_asset_code, 'wardrobe_note', v_note));
    return jsonb_build_object('asset_code', p_asset_code, 'decision', 'SET', 'wardrobe_note', v_note);
end;
$function$;

-- ----- the duration envelope of an episode ---------------------------
-- These two guards date from before the film rules and measured an
-- episode by the summed length of its generated clips (6 to 15 s). A
-- film shot contributes its cut, and the envelope of a planned edit is
-- the one set for episodes. Everything else in them is unchanged.
create or replace function m417_internal.episode_envelope(p_episode_id uuid,
    out total numeric, out low numeric, out high numeric)
 language sql stable security definer set search_path to ''
as $function$
    select coalesce(sum(coalesce(ss.edit_seconds, ss.duration_seconds)), 0),
           case when bool_or(ss.edit_seconds is not null)
                then m417_internal.num('episode_min_seconds', 10) else 6 end,
           -- A voice may lengthen a cut, so the ceiling leaves room for that.
           case when bool_or(ss.edit_seconds is not null)
                then m417_internal.num('episode_max_seconds', 18) * 1.25 else 15 end
    from public.shots s
    join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
    where s.episode_id = p_episode_id;
$function$;

create or replace function public.validate_micro_short_manifest()
 returns trigger language plpgsql set search_path to ''
as $function$
declare
    v_production_mode text;
    v_manifest_shot_count integer;
    v_invalid_episode_count integer;
    v_invalid_binding_count integer;
    v_invalid_spec_count integer;
    v_pilot_binding_count integer;
    v_total_duration numeric;
    v_film boolean;
    v_low numeric := 6;
    v_high numeric := 15;
begin
    -- Only enforce the final production envelope when the manifest
    -- enters HUMAN_APPROVED or LOCKED.
    if new.status not in ('HUMAN_APPROVED', 'LOCKED') then
        return new;
    end if;

    select e.production_mode into v_production_mode
    from public.episodes e where e.id = new.episode_id;
    if not found then
        raise exception 'MICRO_SHORT_MANIFEST_EPISODE_NOT_FOUND';
    end if;
    -- SERIES_EPISODE is not governed by Micro Short policy.
    if v_production_mode <> 'MICRO_SHORT' then
        return new;
    end if;

    select count(*),
           count(*) filter (where s.episode_id is distinct from new.episode_id),
           count(*) filter (where ss.shot_id is distinct from pms.shot_id),
           count(*) filter (
               where ss.id is null
                  or ss.is_active is not true
                  or ss.status <> 'LOCKED'
                  or ss.locked_at is null
                  or ss.aspect_ratio <> '9:16'
                  or ss.duration_seconds < 1
                  or ss.duration_seconds > 15),
           coalesce(sum(coalesce(ss.edit_seconds, ss.duration_seconds)), 0),
           count(*) filter (where pms.shot_id = new.pilot_shot_id),
           coalesce(bool_or(ss.edit_seconds is not null), false)
    into v_manifest_shot_count, v_invalid_episode_count, v_invalid_binding_count,
         v_invalid_spec_count, v_total_duration, v_pilot_binding_count, v_film
    from public.production_manifest_shots pms
    left join public.shots s on s.id = pms.shot_id
    left join public.shot_specifications ss on ss.id = pms.shot_specification_id
    where pms.manifest_id = new.id;

    if v_manifest_shot_count < 1 then
        raise exception 'MICRO_SHORT_MANIFEST_EMPTY';
    end if;
    if v_invalid_episode_count > 0 then
        raise exception 'MICRO_SHORT_MANIFEST_EPISODE_MISMATCH';
    end if;
    if v_invalid_binding_count > 0 then
        raise exception 'MICRO_SHORT_MANIFEST_SPEC_BINDING_INVALID';
    end if;
    if v_invalid_spec_count > 0 then
        raise exception 'MICRO_SHORT_MANIFEST_SPEC_INVALID';
    end if;

    -- Duration envelope: 6-15 s of clips, or the planned edit's limits.
    if v_film then
        select e.low, e.high into v_low, v_high
        from m417_internal.episode_envelope(new.episode_id) e;
    end if;
    if v_total_duration < v_low or v_total_duration > v_high then
        raise exception 'MICRO_SHORT_MANIFEST_DURATION_INVALID: %', v_total_duration;
    end if;

    -- The pilot must be part of the exact manifest.
    if v_pilot_binding_count <> 1 then
        raise exception 'MICRO_SHORT_MANIFEST_PILOT_BINDING_REQUIRED';
    end if;
    return new;
end;
$function$;

create or replace function public.validate_micro_short_production_mode()
 returns trigger language plpgsql set search_path to ''
as $function$
declare
    v_mode text;
    v_episode_id uuid;
    v_invalid_specs integer;
    v_env record;
begin
    if tg_table_name = 'episodes' then
        if new.production_mode = 'MICRO_SHORT'
           and new.state not in ('PLANNED', 'PREPRODUCTION', 'BLOCKED', 'CANCELLED')
        then
            select count(*) filter (
                       where ss.aspect_ratio <> '9:16'
                          or ss.duration_seconds < 1
                          or ss.duration_seconds > 15)
            into v_invalid_specs
            from public.shots s
            join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
            where s.episode_id = new.id;
            if v_invalid_specs > 0 then
                raise exception 'MICRO_SHORT_FORMAT_INVALID';
            end if;
            select * into v_env from m417_internal.episode_envelope(new.id);
            if v_env.total < coalesce(v_env.low, 6) or v_env.total > coalesce(v_env.high, 15) then
                raise exception 'MICRO_SHORT_TOTAL_DURATION_INVALID: %', v_env.total;
            end if;
        end if;
        return new;
    end if;

    if tg_table_name = 'shot_specifications' then
        select s.episode_id, e.production_mode into v_episode_id, v_mode
        from public.shots s
        join public.episodes e on e.id = s.episode_id
        where s.id = new.shot_id;
        if not found then
            raise exception 'SHOT_EPISODE_NOT_FOUND';
        end if;
        if v_mode = 'MICRO_SHORT' and new.is_active = true then
            if new.aspect_ratio <> '9:16' then
                raise exception 'MICRO_SHORT_REQUIRES_9_16';
            end if;
            if new.duration_seconds < 1 or new.duration_seconds > 15 then
                raise exception 'MICRO_SHORT_SHOT_DURATION_INVALID';
            end if;
        end if;
        return new;
    end if;
    return new;
end;
$function$;

-- ----- two-yes rule --------------------------------------------------
-- The Assistant Director said NO to the script. The script goes back to
-- the Head Director with the reasons; after too many rounds the topic
-- itself is dropped and a new one is chosen.
create or replace function m417_internal.script_rejected(p_job_id uuid, p_vote jsonb, p_stated text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_round integer;
    v_retries integer;
    v_feedback jsonb;
    v_episode uuid;
begin
    update public.production_jobs
    set script_no_count = script_no_count + 1
    where id = p_job_id
    returning script_no_count, episode_id into v_round, v_episode;

    v_feedback := jsonb_build_object(
        'verdict', 'REVISE_SCRIPT',
        'source', 'ASSISTANT_DIRECTOR',
        'vote', 'NO',
        'stated_vote', p_stated,
        'minimum_score', m417_internal.num('script_vote_min_score', 7),
        'scores', coalesce(p_vote -> 'scores', '{}'::jsonb),
        'strengths', coalesce(p_vote -> 'strengths', '[]'::jsonb),
        'problems', coalesce(p_vote -> 'problems', '[]'::jsonb),
        'required_changes', coalesce(p_vote -> 'required_changes', '[]'::jsonb),
        'note', case when p_stated = 'YES'
                     then 'The Assistant Director said YES, but a score is below the minimum, so the vote counts as NO. Raise the weak scores.'
                     else 'The Assistant Director voted NO. Rewrite the script so that every required change is met.' end);

    if v_round > m417_internal.num('max_script_rejections', 2) then
        update public.production_jobs
        set topic_retry_count = topic_retry_count + 1,
            topic_feedback = coalesce(topic_feedback, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                'topic', m417_internal.artifact(p_job_id, 'TOPIC_SELECTION') -> 'title',
                'findings', coalesce(p_vote -> 'problems', '[]'::jsonb),
                'required_changes', jsonb_build_array(
                    'The Head Director and the Assistant Director could not agree on a script for this topic. Choose a different idea that is easier to tell in pictures.'))),
            revision_feedback = null,
            revision_count = 0,
            validation_retry_count = 0,
            script_no_count = 0
        where id = p_job_id
        returning topic_retry_count into v_retries;
        perform m417_internal.retire_artifacts(
            p_job_id, array['SCRIPT', 'SHOT_PACKAGE', 'PREQC_REPORT', 'SCRIPT_REVIEW']);
        perform m417_internal.event(
            'TOPIC_DROPPED_NO_AGREEMENT', 'WARNING',
            'The Assistant Director rejected the script too often; the topic is dropped.',
            jsonb_build_object('job_id', p_job_id, 'rounds', v_round, 'topic_retry', v_retries), v_episode);
        if v_retries > m417_internal.num('max_topic_retries', 2) then
            update public.production_jobs set current_step = 7 where id = p_job_id;
            perform m417_internal.block_job(p_job_id, 'SCRIPT_NOT_AGREED', v_feedback::text);
        else
            perform m417_internal.set_step(
                p_job_id, 7, 'TOPIC_DROPPED_NO_AGREEMENT', jsonb_build_object('retry_no', v_retries));
        end if;
    else
        update public.production_jobs
        set revision_feedback = v_feedback,
            validation_retry_count = 0
        where id = p_job_id;
        perform m417_internal.set_step(
            p_job_id, 10, 'REVISION_OPENED',
            jsonb_build_object('source', 'ASSISTANT_DIRECTOR', 'round', v_round));
    end if;
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('accepted', false, 'script_vote', 'NO', 'issues', '[]'::jsonb);
end;
$function$;

-- Both votes of the current script, for the owner's overview.
create or replace function m417_internal.two_yes(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'assistant_director', m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR'),
        'head_director', m417_internal.has_yes(p_job_id, 'HEAD_DIRECTOR'));
$function$;

-- ----- instructions kept in the database -----------------------------
-- The instruction for the model that works on this step, with the
-- material of the job filled in. Empty when the step has none here.
create or replace function m417_internal.step_prompt(
    p_job_id uuid, p_step integer, p_request text, p_feedback text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_code text := case p_step
        when 7 then 'TOPIC' when 10 then 'SCRIPT' when 11 then 'SHOT_PACKAGE'
        when 12 then 'PREQC' when 14 then 'DIRECTOR'
        when 31 then 'FINAL_QC' when 32 then 'FINAL_QC' end;
    v_body text;
    v_plan text := '[]';
    v_total text := '0';
    v_durations integer[] := m417_internal.allowed_shot_durations();
    v_last_no text;
    v_pair record;
begin
    if v_code is null then
        return '';
    end if;
    select sp.body into v_body
    from public.step_prompts sp
    where sp.prompt_code = v_code and sp.is_active = true;
    if v_body is null then
        return '';
    end if;

    select v.result::text into v_last_no
    from public.script_votes v
    where v.job_id = p_job_id and v.voter_role = 'ASSISTANT_DIRECTOR' and v.decision = 'NO'
      and exists (select 1 from public.job_artifacts a
                  where a.id = v.script_artifact_id
                    and a.created_at >= coalesce((
                        select max(t.created_at) from public.job_artifacts t
                        where t.job_id = p_job_id and t.artifact_type = 'TOPIC_SELECTION' and t.is_current), '-infinity'))
    order by v.created_at desc
    limit 1;

    -- The finished edit, cut by cut, for the reviewer of the final video.
    if v_code = 'FINAL_QC' then
        select coalesce(jsonb_agg(jsonb_build_object(
                   'cut', e.value ->> 'shot_code',
                   'starts_at', e.value -> 'start',
                   'seconds', e.value -> 'length',
                   'shot_size', ss.film_size,
                   'spoken_line', ss.dialogue,
                   'speaker_staging', ss.voice_staging,
                   'action', left(ss.narrative_action, 160))
                   order by (e.value ->> 'start')::numeric), '[]'::jsonb)::text,
               coalesce(sum((e.value ->> 'length')::numeric), 0)::text
        into v_plan, v_total
        from jsonb_array_elements(m417_internal.edit_list(p_job_id) -> 'shots') e(value)
        join public.production_jobs j on j.id = p_job_id
        join public.shots s on s.episode_id = j.episode_id and s.shot_code = e.value ->> 'shot_code'
        join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true;
    end if;

    for v_pair in
        select * from (values
            ('[[EDIT_PLAN]]', coalesce(v_plan, '[]')),
            ('[[TOTAL_SECONDS]]', coalesce(v_total, '0')),
            ('[[EP_MIN]]', m417_internal.num('episode_min_seconds', 10)::text),
            ('[[EP_MAX]]', m417_internal.num('episode_max_seconds', 18)::text),
            ('[[SHOTS_MIN]]', m417_internal.num('min_shots', 5)::integer::text),
            ('[[SHOTS_MAX]]', m417_internal.num('max_shots', 7)::integer::text),
            ('[[CUT_MIN]]', m417_internal.num('min_shot_edit_seconds', 0.8)::text),
            ('[[CUT_MAX]]', m417_internal.num('max_shot_edit_seconds', 4.5)::text),
            ('[[HOOK_MAX]]', m417_internal.num('hook_max_seconds', 2.5)::text),
            ('[[LINES_MAX]]', m417_internal.num('max_dialogue_lines', 4)::integer::text),
            ('[[LINE_CHARS]]', m417_internal.speech_max_chars(m417_internal.max_line_seconds())::text),
            ('[[GEN_SECONDS]]', coalesce(v_durations[1], 5)::text),
            ('[[MIN_SCORE]]', m417_internal.num('script_vote_min_score', 7)::integer::text),
            ('[[PROMPT_MIN]]', m417_internal.num('film_video_prompt_min_chars', 200)::integer::text),
            ('[[MAX_CAST]]', m417_internal.num('max_characters_per_shot', 3)::integer::text),
            ('[[BIBLE]]', m417_internal.series_bible(p_job_id)::text),
            ('[[REQUEST]]', coalesce(nullif(p_request, ''), '{}')),
            ('[[TRENDS]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'TREND_REPORT'), ''), 'none')),
            ('[[TOPIC]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'TOPIC_SELECTION'), ''), 'none')),
            ('[[SCRIPT]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'SCRIPT'), ''), 'none')),
            ('[[SHOT_PACKAGE]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'SHOT_PACKAGE'), ''), 'none')),
            ('[[ASSISTANT_REVIEW]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'SCRIPT_REVIEW'), ''), 'none')),
            ('[[PREQC_REPORT]]', coalesce(nullif(m417_internal.artifact_text(p_job_id, 'PREQC_REPORT'), ''), 'none')),
            ('[[LAST_REJECTION]]', coalesce(v_last_no, 'none')),
            ('[[FEEDBACK]]', coalesce(nullif(p_feedback, ''), 'none'))
        ) as x(token, val)
    loop
        v_body := replace(v_body, v_pair.token, v_pair.val);
    end loop;
    return v_body;
end;
$function$;

-- ----- functions changed for the film rules and the two-yes rule -----

create or replace function public.get_job_context(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_request jsonb;
    v_preqc text;
begin
    select j.* into v_job from public.production_jobs j where j.id = p_job_id;
    if not found then
        raise exception 'JOB_NOT_FOUND';
    end if;

    v_request := v_job.request;
    if v_job.topic_feedback is not null then
        v_request := v_request || jsonb_build_object('rejected_topics', v_job.topic_feedback);
    end if;

    -- While a revision is open the writer sees the feedback that opened
    -- it; afterwards the reviewers see the real pre-QC report.
    if v_job.current_step in (10, 11) and v_job.revision_feedback is not null then
        v_preqc := v_job.revision_feedback::text;
    else
        v_preqc := m417_internal.artifact_text(p_job_id, 'PREQC_REPORT');
    end if;

    return jsonb_build_object(
        'job_id', v_job.id,
        'step_no', v_job.current_step,
        'series_bible_text', m417_internal.series_bible(p_job_id)::text,
        'request_text', v_request::text,
        'trend_report_text', m417_internal.artifact_text(p_job_id, 'TREND_REPORT'),
        'topic_selection_text', m417_internal.artifact_text(p_job_id, 'TOPIC_SELECTION'),
        'script_text', m417_internal.artifact_text(p_job_id, 'SCRIPT'),
        'shot_package_text', m417_internal.artifact_text(p_job_id, 'SHOT_PACKAGE'),
        'preqc_report_text', v_preqc,
        'assistant_review_text', m417_internal.artifact_text(p_job_id, 'SCRIPT_REVIEW'),
        'two_yes_text', m417_internal.two_yes(p_job_id)::text,
        'prompt_text', m417_internal.step_prompt(p_job_id, v_job.current_step, v_request::text, v_preqc),
        'music_library_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'track_code', mt.track_code, 'title', mt.title, 'role', mt.role,
                       'mood', mt.mood, 'duration_seconds', mt.duration_seconds)
                       order by mt.track_code), '[]'::jsonb)::text
            from public.music_tracks mt
            where mt.is_active = true and mt.license_status = 'VERIFIED'),
        -- The accepted verdict only: the reviewer's raw verdict and the
        -- system note read as a contradiction to the policy gate.
        'final_qc_report_text', coalesce((
            select ((r.qc_result - 'reviewer_verdict' - 'system_note' - 'overruled')
                    || case when r.qc_result ? 'system_note'
                            then jsonb_build_object('lip_sync_policy',
                                 'Lip-sync is not produced in this version by owner decision; lip-sync findings are informational and do not affect the verdict.')
                            else '{}'::jsonb end)::text
            from public.renders r
            where r.job_id = p_job_id and r.qc_result is not null
            order by r.render_no desc
            limit 1), ''),
        'policy_checks_text', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'gate_no', pc.gate_no, 'verdict', pc.verdict, 'checker', pc.checker,
                       'findings', pc.result -> 'findings', 'notes', pc.result -> 'notes')
                       order by pc.created_at), '[]'::jsonb)::text
            -- The check in force per gate: a repeated gate replaces its
            -- earlier result instead of contradicting it.
            from (
                select distinct on (x.gate_no) x.*
                from public.policy_checks x
                where x.job_id = p_job_id
                order by x.gate_no, x.created_at desc
            ) pc),
        'metadata_candidates_text', m417_internal.artifact_text(p_job_id, 'METADATA_CANDIDATES'));
end;
$function$;

create or replace function public.save_artifact(
    p_job_id uuid, p_artifact_type text, p_producer text, p_content jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_type text := upper(btrim(coalesce(p_artifact_type, '')));
    v_producer text := upper(btrim(coalesce(p_producer, '')));
    v_step integer;
    v_owner text;
    v_issues jsonb := '[]'::jsonb;
    v_version integer;
    v_artifact_id uuid;
    v_verdict text;
    v_continue boolean;
    v_vote jsonb;
    v_stated text;
    v_decision text;
    v_low numeric;
    v_scored integer;
    v_vote_issue jsonb;
    v_script_id uuid;
    v_review_version integer;
begin
    select x.step, x.owner into v_step, v_owner
    from (values
        ('TREND_REPORT', 6, 'GROK'),
        ('TOPIC_SELECTION', 7, 'CLAUDE'),
        ('SCRIPT', 10, 'CLAUDE'),
        ('SHOT_PACKAGE', 11, 'OPENAI'),
        ('PREQC_REPORT', 12, 'GEMINI'),
        ('MUSIC_SFX_PLAN', 19, 'CLAUDE'),
        ('METADATA_CANDIDATES', 36, 'GROK')
    ) as x(atype, step, owner)
    where x.atype = v_type;
    if not found then
        raise exception 'ARTIFACT_TYPE_NOT_ACCEPTED: %', v_type;
    end if;
    if v_producer <> v_owner then
        raise exception 'PRODUCER_NOT_AUTHORIZED: % may not write %', v_producer, v_type;
    end if;
    if p_content is null or jsonb_typeof(p_content) <> 'object' then
        raise exception 'ARTIFACT_CONTENT_MUST_BE_JSON_OBJECT';
    end if;

    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, v_step);

    -- Shape checks that cannot be repaired by another round stop here.
    if v_type = 'TOPIC_SELECTION'
       and (coalesce(btrim(p_content ->> 'title'), '') = '' or coalesce(btrim(p_content ->> 'premise'), '') = '')
    then
        raise exception 'TOPIC_SELECTION_INCOMPLETE: title and premise are required';
    end if;
    if v_type = 'PREQC_REPORT' then
        v_verdict := upper(btrim(coalesce(p_content ->> 'verdict', '')));
        if v_verdict not in ('PASS', 'REVISE_SCRIPT', 'REVISE_SHOTS') then
            raise exception 'PREQC_VERDICT_INVALID: %', coalesce(p_content ->> 'verdict', '(empty)');
        end if;
    end if;
    if v_type = 'MUSIC_SFX_PLAN' and jsonb_typeof(p_content -> 'tracks') is distinct from 'array' then
        raise exception 'MUSIC_PLAN_TRACKS_MUST_BE_ARRAY';
    end if;
    if v_type = 'METADATA_CANDIDATES'
       and (jsonb_typeof(p_content -> 'candidates') is distinct from 'array'
            or jsonb_array_length(p_content -> 'candidates') = 0)
    then
        raise exception 'METADATA_CANDIDATES_REQUIRED';
    end if;

    -- Two-yes rule, first vote: the Assistant Director votes on the
    -- script in the same answer that carries the shots.
    if v_type = 'SHOT_PACKAGE' and m417_internal.flag('assistant_vote_required', false) then
        v_vote := p_content -> 'script_vote';
        v_stated := upper(btrim(coalesce(v_vote ->> 'decision', '')));
        v_script_id := m417_internal.current_script_id(p_job_id);
        if v_script_id is null then
            raise exception 'SCRIPT_MISSING';
        end if;
        select min(m417_internal.safe_numeric(s.value)),
               count(*) filter (where m417_internal.safe_numeric(s.value) is not null)
        into v_low, v_scored
        from jsonb_each_text(case when jsonb_typeof(v_vote -> 'scores') = 'object'
                                  then v_vote -> 'scores' else '{}'::jsonb end) s(key, value);
        if jsonb_typeof(v_vote) is distinct from 'object' or v_stated not in ('YES', 'NO') then
            v_vote_issue := m417_internal.issue(
                'SHOTS', 'script_vote', 'script_vote is missing, or its decision is not YES or NO.',
                'Return script_vote {decision, scores, strengths, problems, required_changes} together with the shots.');
        elsif v_stated = 'YES' and v_scored < 5 then
            v_vote_issue := m417_internal.issue(
                'SHOTS', 'script_vote', 'A YES needs the five scores: hook, story, humor, dialogue, filmability (1 to 10).',
                'Return all five scores in script_vote.scores.');
        else
            v_decision := case when v_stated = 'YES'
                                    and v_low >= m417_internal.num('script_vote_min_score', 7)
                               then 'YES' else 'NO' end;
            insert into public.script_votes (
                job_id, script_artifact_id, voter, voter_role, decision, stated_decision, scores, result)
            values (
                p_job_id, v_script_id, 'OPENAI', 'ASSISTANT_DIRECTOR', v_decision, v_stated,
                case when jsonb_typeof(v_vote -> 'scores') = 'object' then v_vote -> 'scores' else '{}'::jsonb end,
                v_vote);
            perform m417_internal.retire_artifacts(p_job_id, array['SCRIPT_REVIEW']);
            select coalesce(max(a.version), 0) + 1 into v_review_version
            from public.job_artifacts a
            where a.job_id = p_job_id and a.artifact_type = 'SCRIPT_REVIEW';
            insert into public.job_artifacts (job_id, artifact_type, producer, version, content)
            values (p_job_id, 'SCRIPT_REVIEW', 'OPENAI', v_review_version,
                    v_vote || jsonb_build_object('decision', v_decision, 'stated_decision', v_stated));
            if v_decision = 'NO' then
                perform m417_internal.usage(p_job_id, 'OPENAI', 'SCRIPT_REVIEW');
                return m417_internal.script_rejected(p_job_id, v_vote, v_stated)
                    || jsonb_build_object('version', v_review_version);
            end if;
        end if;
    end if;

    -- Problems the writer can fix go back to the writer.
    if v_type = 'SCRIPT' then
        v_issues := m417_internal.validate_script(p_job_id, p_content);
    elsif v_type = 'SHOT_PACKAGE' then
        v_issues := m417_internal.validate_shot_package(p_job_id, p_content);
        if v_vote_issue is not null then
            v_issues := jsonb_build_array(v_vote_issue) || v_issues;
        end if;
    end if;

    -- A new script makes the old shots and review stale; new shots make
    -- the old review stale.
    if v_type = 'SCRIPT' then
        perform m417_internal.retire_artifacts(p_job_id, array['SHOT_PACKAGE', 'PREQC_REPORT', 'SCRIPT_REVIEW']);
    elsif v_type = 'SHOT_PACKAGE' then
        perform m417_internal.retire_artifacts(p_job_id, array['PREQC_REPORT']);
    end if;
    perform m417_internal.retire_artifacts(p_job_id, array[v_type]);

    select coalesce(max(a.version), 0) + 1 into v_version
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = v_type;

    insert into public.job_artifacts (job_id, artifact_type, producer, version, content, validation_issues)
    values (p_job_id, v_type, v_producer, v_version, p_content, v_issues)
    returning id into v_artifact_id;

    perform m417_internal.usage(p_job_id, v_producer, v_type);

    if jsonb_array_length(v_issues) > 0 then
        v_continue := m417_internal.open_revision(
            p_job_id, v_step,
            jsonb_build_object(
                'verdict', case v_type when 'SCRIPT' then 'REVISE_SCRIPT' else 'REVISE_SHOTS' end,
                'source', 'SYSTEM_VALIDATION',
                'issues', v_issues),
            'SYSTEM_VALIDATION');
        return m417_internal.job_status(p_job_id)
            || jsonb_build_object('artifact_id', v_artifact_id, 'version', v_version,
                                  'accepted', false, 'issues', v_issues);
    end if;

    -- A clean script or shot package closes the feedback that asked for
    -- it, and the count of failed format checks starts again.
    if v_type in ('SCRIPT', 'SHOT_PACKAGE') then
        update public.production_jobs
        set revision_feedback = null,
            validation_retry_count = 0
        where id = p_job_id;
    end if;
    if v_type = 'TOPIC_SELECTION' then
        update public.episodes
        set title = left(p_content ->> 'title', 200),
            concept = p_content ->> 'premise'
        where id = v_job.episode_id;
        -- A new topic starts with a clean count of script rejections.
        update public.production_jobs set script_no_count = 0 where id = p_job_id;
    end if;

    perform m417_internal.set_step(
        p_job_id, v_step + 1, 'ARTIFACT_SAVED',
        jsonb_build_object('artifact_type', v_type, 'version', v_version, 'artifact_id', v_artifact_id));
    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('artifact_id', v_artifact_id, 'version', v_version,
                              'accepted', true, 'issues', '[]'::jsonb);
end;
$function$;

create or replace function public.record_final_director_decision(
    p_job_id uuid, p_actor text, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_decision text;
    v_version integer;
    v_decision_id uuid;
    v_feedback jsonb;
    v_ok boolean;
begin
    if upper(btrim(coalesce(p_actor, ''))) <> 'CLAUDE' then
        raise exception 'DIRECTOR_NOT_AUTHORIZED: %', coalesce(p_actor, '(empty)');
    end if;
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        raise exception 'DIRECTOR_RESULT_MUST_BE_JSON_OBJECT';
    end if;
    v_decision := upper(btrim(coalesce(p_result ->> 'decision', '')));
    if v_decision not in ('APPROVE', 'REVISE_SCRIPT', 'REVISE_SHOTS', 'REJECT') then
        raise exception 'DIRECTOR_DECISION_INVALID: %', coalesce(p_result ->> 'decision', '(empty)');
    end if;

    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 14);

    -- An approval that contradicts the reviews is not accepted as one.
    if v_decision = 'APPROVE' then
        if upper(coalesce(m417_internal.artifact(p_job_id, 'PREQC_REPORT') ->> 'verdict', '')) <> 'PASS' then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_PREQC_PASS';
        end if;
        if not exists (
            select 1 from public.policy_checks pc
            where pc.job_id = p_job_id and pc.gate_no = 1 and pc.verdict = 'PASS')
        then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_POLICY_GATE_1';
        end if;
        if upper(coalesce(p_result ->> 'child_safety_status', 'PASS')) = 'FAIL'
           or coalesce(p_result ->> 'production_ready', 'true') = 'false'
        then
            raise exception 'DIRECTOR_APPROVAL_CONTRADICTS_ITS_OWN_FINDINGS';
        end if;
        -- Two-yes rule: the Assistant Director's YES comes first.
        if m417_internal.flag('assistant_vote_required', false)
           and not m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR')
        then
            raise exception 'DIRECTOR_APPROVAL_REQUIRES_ASSISTANT_YES';
        end if;
    end if;

    select e.production_version into v_version from public.episodes e where e.id = v_job.episode_id;

    insert into public.director_decisions (
        job_id, episode_id, production_version, stage, decision, actor, notes, result)
    values (
        p_job_id, v_job.episode_id, v_version, 'PRODUCTION', v_decision, 'CLAUDE',
        p_result ->> 'director_notes', p_result)
    returning id into v_decision_id;
    perform m417_internal.usage(p_job_id, 'CLAUDE', 'DIRECTOR_DECISION');
    -- Two-yes rule, second vote.
    if m417_internal.current_script_id(p_job_id) is not null then
        insert into public.script_votes (
            job_id, script_artifact_id, voter, voter_role, decision, stated_decision, result)
        values (
            p_job_id, m417_internal.current_script_id(p_job_id), 'CLAUDE', 'HEAD_DIRECTOR',
            case when v_decision = 'APPROVE' then 'YES' else 'NO' end, v_decision, p_result);
    end if;

    if v_decision = 'APPROVE' then
        update public.production_jobs
        set director_decision_id = v_decision_id, revision_feedback = null
        where id = p_job_id;
        perform m417_internal.set_step(
            p_job_id, 15, 'DIRECTOR_APPROVED', jsonb_build_object('decision_id', v_decision_id));
    elsif v_decision = 'REJECT' then
        update public.episodes set state = 'CANCELLED' where id = v_job.episode_id;
        update public.budgets set is_active = false
        where budget_type = 'EPISODE' and reference_id = v_job.episode_id;
        perform m417_internal.set_step(
            p_job_id, 14, 'DIRECTOR_REJECTED',
            jsonb_build_object('decision_id', v_decision_id, 'notes', p_result ->> 'director_notes'),
            'CANCELLED');
        perform m417_internal.event(
            'JOB_REJECTED_BY_DIRECTOR', 'WARNING', 'Head Director rejected the production package.',
            jsonb_build_object('job_id', p_job_id, 'decision_id', v_decision_id), v_job.episode_id);
    else
        v_feedback := jsonb_build_object(
            'verdict', v_decision,
            'source', 'HEAD_DIRECTOR',
            'director_notes', p_result -> 'director_notes',
            'issues', coalesce((
                select jsonb_agg(m417_internal.issue(
                    case v_decision when 'REVISE_SCRIPT' then 'SCRIPT' else 'SHOTS' end,
                    'director', c.value, c.value))
                from jsonb_array_elements_text(
                    case when jsonb_typeof(p_result -> 'required_changes') = 'array'
                         then p_result -> 'required_changes' else '[]'::jsonb end) c(value)), '[]'::jsonb));
        v_ok := m417_internal.open_revision(
            p_job_id, case v_decision when 'REVISE_SCRIPT' then 10 else 11 end,
            v_feedback, 'HEAD_DIRECTOR');
    end if;

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('decision', v_decision, 'decision_id', v_decision_id);
end;
$function$;

create or replace function public.commit_production_package(p_job_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_episode public.episodes;
    v_decision public.director_decisions;
    v_script jsonb;
    v_pkg jsonb;
    v_shot_budget numeric;
    v_resolution text := m417_internal.txt('default_shot_resolution', '720p');
    v_voice_provider text := m417_internal.txt('voice_provider', 'fish_audio');
    v_profile public.production_creative_profiles;
    v_scene record;
    v_scene_ids jsonb := '{}'::jsonb;
    v_scene_locations jsonb := '{}'::jsonb;
    v_scene_id uuid;
    v_loc_id uuid;
    v_rec record;
    v_shot jsonb;
    v_idx integer := 0;
    v_shot_id uuid;
    v_spec_id uuid;
    v_first_shot_id uuid;
    v_char_ids uuid[];
    v_char_codes jsonb;
    v_asset_ids uuid[];
    v_asset_roles text[];
    v_asset_codes jsonb;
    v_asset record;
    v_lines jsonb;
    v_line record;
    v_char_id uuid;
    v_voice_id uuid;
    v_voice_language text;
    v_camera text;
    v_negative text;
    v_style_negative text;
    v_duration numeric;
    v_line_total integer := 0;
    v_manifest_id uuid;
    v_i integer;
    v_edit numeric;
    v_cut numeric;
    v_speaker_id uuid;
    v_stage text;
begin
    v_job := m417_internal.lock_job(p_job_id);
    perform m417_internal.require_step(v_job, 15);

    if m417_internal.flag('storyboard_required', true) then
        perform m417_internal.block_job(
            p_job_id, 'STORYBOARD_REQUIRED',
            'storyboard_required is on, but this pipeline has no storyboard step.');
        return m417_internal.job_status(p_job_id);
    end if;

    select d.* into v_decision
    from public.director_decisions d
    where d.id = v_job.director_decision_id
      and d.job_id = p_job_id
      and d.stage = 'PRODUCTION'
      and d.decision = 'APPROVE';
    if not found then
        raise exception 'DIRECTOR_APPROVAL_MISSING';
    end if;
    -- Two-yes rule: nothing is produced without a YES from both.
    if m417_internal.flag('assistant_vote_required', false)
       and not (m417_internal.has_yes(p_job_id, 'ASSISTANT_DIRECTOR')
                and m417_internal.has_yes(p_job_id, 'HEAD_DIRECTOR'))
    then
        raise exception 'TWO_YES_REQUIRED: %', m417_internal.two_yes(p_job_id)::text;
    end if;

    select e.* into v_episode from public.episodes e where e.id = v_job.episode_id for update;
    if v_episode.state <> 'PREPRODUCTION' then
        raise exception 'EPISODE_NOT_IN_PREPRODUCTION: %', v_episode.state;
    end if;
    if v_decision.production_version <> v_episode.production_version then
        raise exception 'DIRECTOR_APPROVAL_VERSION_STALE';
    end if;
    select p.* into v_profile
    from public.production_creative_profiles p where p.id = v_job.creative_profile_id;

    select a.content into v_script
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SCRIPT' and a.is_current
      and jsonb_array_length(a.validation_issues) = 0;
    select a.content into v_pkg
    from public.job_artifacts a
    where a.job_id = p_job_id and a.artifact_type = 'SHOT_PACKAGE' and a.is_current
      and jsonb_array_length(a.validation_issues) = 0;
    if v_script is null or v_pkg is null then
        raise exception 'VALID_SCRIPT_AND_SHOT_PACKAGE_REQUIRED';
    end if;

    v_shot_budget := m417_internal.safe_numeric(v_job.request ->> 'shot_budget_usd');

    select array_to_string(array(
               select jsonb_array_elements_text(sb.negative_rules)), ', ')
    into v_style_negative
    from public.style_bibles sb
    where sb.series_id = v_job.series_id and sb.status <> 'ARCHIVED'
      and jsonb_typeof(sb.negative_rules) = 'array'
    order by sb.version desc
    limit 1;

    update public.episodes
    set title = left(coalesce(nullif(btrim(v_script ->> 'title'), ''), title), 200),
        concept = coalesce(nullif(btrim(v_script ->> 'logline'), ''), concept),
        director_approval_id = v_decision.id
    where id = v_episode.id;

    -- Scenes ---------------------------------------------------------
    for v_scene in
        select s.scene, s.idx
        from jsonb_array_elements(v_script -> 'scenes') with ordinality as s(scene, idx)
    loop
        v_loc_id := m417_internal.resolve_location(v_job.series_id, v_scene.scene ->> 'location');
        insert into public.scenes (
            episode_id, scene_code, scene_order, title, description, location_id,
            estimated_duration_seconds, state)
        values (
            v_episode.id, 'SC' || lpad(v_scene.idx::text, 2, '0'), v_scene.idx,
            left(v_scene.scene ->> 'action', 120), v_scene.scene ->> 'action', v_loc_id,
            m417_internal.safe_numeric(v_scene.scene ->> 'duration_seconds'), 'SCRIPTED')
        returning id into v_scene_id;
        v_scene_ids := v_scene_ids
            || jsonb_build_object(coalesce(v_scene.scene ->> 'scene_no', v_scene.idx::text), v_scene_id);
        if v_loc_id is not null then
            v_scene_locations := v_scene_locations
                || jsonb_build_object(coalesce(v_scene.scene ->> 'scene_no', v_scene.idx::text), v_loc_id);
        end if;
    end loop;

    -- Shots ----------------------------------------------------------
    for v_rec in
        select t.elem
        from jsonb_array_elements(v_pkg -> 'shots') with ordinality as t(elem, ord)
        order by coalesce(m417_internal.safe_numeric(t.elem ->> 'shot_no'), t.ord), t.ord
    loop
        v_shot := v_rec.elem;
        v_idx := v_idx + 1;
        v_scene_id := (v_scene_ids ->> coalesce(v_shot ->> 'scene_no', ''))::uuid;
        v_duration := m417_internal.safe_numeric(v_shot ->> 'duration_seconds');

        -- A film shot carries its cut length and the staging of its line.
        v_edit := case when m417_internal.film_on()
                       then m417_internal.safe_numeric(v_shot ->> 'edit_seconds') end;
        v_stage := case when v_edit is not null then m417_internal.voice_stage(v_shot ->> 'voice_staging') end;

        -- Who is in the shot: listed characters plus everyone who speaks
        -- (a speaker staged off-screen is heard, not seen).
        v_lines := coalesce((
            select jsonb_agg(m417_internal.script_line(v_script, v_shot ->> 'scene_no', n.line_no) order by n.ord)
            from jsonb_array_elements_text(
                case when jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array'
                     then v_shot -> 'dialogue_line_nos' else '[]'::jsonb end
            ) with ordinality as n(line_no, ord)), '[]'::jsonb);

        select coalesce(array_agg(distinct x.id), array[]::uuid[]) into v_char_ids
        from (
            select m417_internal.resolve_character(v_job.series_id, c.value) as id
            from jsonb_array_elements_text(
                case when jsonb_typeof(v_shot -> 'characters') = 'array'
                     then v_shot -> 'characters' else '[]'::jsonb end) c(value)
            union
            select m417_internal.resolve_character(v_job.series_id, l.value ->> 'character')
            from jsonb_array_elements(v_lines) l(value)
            where v_stage is distinct from 'OFF_SCREEN'
        ) x
        where x.id is not null;

        v_speaker_id := m417_internal.resolve_character(v_job.series_id, v_lines -> 0 ->> 'character');
        v_cut := case when v_edit is not null then m417_internal.planned_cut(v_edit, (
                     select coalesce(sum(m417_internal.speech_seconds(l.value ->> 'text')), 0)
                     from jsonb_array_elements(v_lines) l(value))) end;

        select coalesce(jsonb_agg(c.character_code order by c.character_code), '[]'::jsonb)
        into v_char_codes
        from public.characters c where c.id = any (v_char_ids);

        v_loc_id := coalesce(
            m417_internal.resolve_location(v_job.series_id, v_shot ->> 'location'),
            (v_scene_locations ->> coalesce(v_shot ->> 'scene_no', ''))::uuid);

        -- Canonical references: one per character, then the location
        -- master, at most three in total.
        v_asset_ids := array[]::uuid[];
        v_asset_roles := array[]::text[];
        for v_asset in
            select x.asset_id, x.role
            from (
                select (
                           select ar.id from public.asset_registry ar
                           where ar.character_id = c.id
                             and ar.asset_type = 'CHARACTER_REFERENCE'
                             and ar.status = 'LOCKED'
                           order by ar.version desc, ar.asset_code
                           limit 1) as asset_id,
                       'CHARACTER'::text as role, 1 as grp, c.character_code as ord
                from public.characters c
                where c.id = any (v_char_ids)
                union all
                select (
                           select ar.id from public.asset_registry ar
                           where ar.location_id = v_loc_id
                             and ar.asset_type = 'LOCATION_REFERENCE'
                             and ar.status = 'LOCKED'
                           order by (ar.metadata ->> 'asset_role' = 'MASTER') desc nulls last,
                                    ar.version desc, ar.asset_code
                           limit 1),
                       'LOCATION', 2, ''
            ) x
            where x.asset_id is not null
            order by x.grp, x.ord
            limit 3
        loop
            v_asset_ids := v_asset_ids || v_asset.asset_id;
            v_asset_roles := v_asset_roles || v_asset.role;
        end loop;
        select coalesce(jsonb_agg(ar.asset_code order by ar.asset_code), '[]'::jsonb)
        into v_asset_codes
        from public.asset_registry ar where ar.id = any (v_asset_ids);

        insert into public.shots (episode_id, shot_code, shot_order, state, maximum_budget, scene_id)
        values (v_episode.id, 'SH' || lpad(v_idx::text, 2, '0'), v_idx, 'PLANNED', v_shot_budget, v_scene_id)
        returning id into v_shot_id;
        if v_first_shot_id is null then
            v_first_shot_id := v_shot_id;
        end if;

        insert into public.budgets (budget_type, reference_id, currency, hard_limit, is_active)
        values ('SHOT', v_shot_id, 'USD', v_shot_budget, true);

        v_camera := lower(coalesce(v_shot ->> 'camera', ''));
        v_negative := left(btrim(concat_ws(', ',
            nullif(btrim(v_shot ->> 'negative_prompt'), ''),
            nullif(v_style_negative, ''),
            'text, subtitles, watermark, logo')), 900);

        insert into public.shot_specifications (
            shot_id, version, is_active, narrative_action, dialogue, emotion, shot_size,
            camera_movement, duration_seconds, generation_prompt, negative_prompt,
            aspect_ratio, fps, resolution, character_codes, required_asset_codes,
            continuity_notes, audio_required, voice_required, status,
            edit_seconds, film_size, shot_purpose, voice_staging, beats, props, qc_brief)
        values (
            v_shot_id, 1, true,
            coalesce(nullif(btrim(v_shot ->> 'action'), ''), left(v_shot ->> 'video_prompt', 500)),
            nullif((select string_agg((l.value ->> 'character') || ': ' || (l.value ->> 'text'), ' / ')
                    from jsonb_array_elements(v_lines) l(value)), ''),
            nullif(btrim(v_shot ->> 'acting'), ''),
            case
                when v_edit is not null and m417_internal.film_size(v_shot ->> 'shot_size') is not null
                    then m417_internal.film_size(v_shot ->> 'shot_size')
                when v_camera ~ '(extreme close|close[- ]?up|closeup)' then 'CLOSE_UP'
                when v_camera ~ '(wide|establishing|long shot|full shot)' then 'WIDE'
                else 'MEDIUM'
            end,
            nullif(btrim(v_shot ->> 'camera'), ''),
            v_duration,
            case when v_edit is not null
                 then m417_internal.compose_shot_prompt(
                          v_job.series_id, v_script, v_shot, v_char_ids, v_loc_id, v_speaker_id, v_cut)
                 else m417_internal.compose_prompt(v_job.series_id, v_shot, v_char_ids, v_loc_id) end,
            v_negative,
            v_profile.aspect_ratio, 24, v_resolution, v_char_codes, v_asset_codes,
            nullif(btrim(v_shot ->> 'continuity_notes'), ''),
            false, jsonb_array_length(v_lines) > 0, 'DRAFT',
            v_edit,
            case when v_edit is not null then m417_internal.film_size(v_shot ->> 'shot_size') end,
            case when v_edit is not null then nullif(upper(btrim(v_shot ->> 'purpose')), '') end,
            case when jsonb_array_length(v_lines) > 0 then v_stage end,
            case when v_edit is not null and jsonb_typeof(v_shot -> 'beats') = 'array'
                 then v_shot -> 'beats' else '[]'::jsonb end,
            case when v_edit is not null and jsonb_typeof(v_shot -> 'props') = 'array'
                 then v_shot -> 'props' else '[]'::jsonb end,
            case when v_edit is not null
                 then m417_internal.shot_qc_brief(v_job.series_id, v_script, v_shot, v_char_ids, v_speaker_id, v_cut) end)
        returning id into v_spec_id;

        for v_i in 1 .. coalesce(array_length(v_asset_ids, 1), 0)
        loop
            insert into public.shot_reference_assets (
                shot_specification_id, asset_id, reference_role, reference_order, is_required)
            values (v_spec_id, v_asset_ids[v_i], v_asset_roles[v_i], v_i, true);
        end loop;

        -- Locked on the strength of the director decision.
        perform set_config('m417.director_lock', 'on', true);
        update public.shot_specifications set status = 'LOCKED' where id = v_spec_id;
        perform set_config('m417.director_lock', 'off', true);

        -- One planned voice take per dialogue line.
        for v_line in
            select l.value, l.ord
            from jsonb_array_elements(v_lines) with ordinality as l(value, ord)
        loop
            v_char_id := m417_internal.resolve_character(v_job.series_id, v_line.value ->> 'character');
            v_voice_id := m417_internal.character_voice(v_char_id);
            if v_char_id is null or v_voice_id is null then
                raise exception 'DIALOGUE_CHARACTER_HAS_NO_LOCKED_VOICE: %',
                    coalesce(v_line.value ->> 'character', '(empty)');
            end if;
            select vi.language into v_voice_language
            from public.voice_identities vi where vi.id = v_voice_id;
            insert into public.shot_audio_productions (
                shot_specification_id, character_id, voice_identity_id, audio_order,
                dialogue_text, language, provider, lip_sync_required, lip_sync_status,
                timing_metadata, status, take_no)
            values (
                v_spec_id, v_char_id, v_voice_id, v_line.ord,
                m417_internal.clean(v_line.value ->> 'text'), v_voice_language, v_voice_provider,
                false, 'NOT_REQUIRED',
                jsonb_build_object(
                    'scene_no', v_line.value ->> 'scene_no',
                    'line_no', v_line.value ->> 'line_no',
                    'emotion', v_line.value ->> 'emotion',
                    'estimated_seconds', v_line.value ->> 'estimated_seconds'),
                'PLANNED', 1);
            v_line_total := v_line_total + 1;
        end loop;

        -- No storyboard step: the storyboard stage is passed, not skipped
        -- silently, so the state machine and the event log both show it.
        update public.shots set state = 'STORYBOARD_PENDING' where id = v_shot_id;
        update public.shots set state = 'STORYBOARD_APPROVED' where id = v_shot_id;
    end loop;

    -- Manifest -------------------------------------------------------
    insert into public.production_manifests (
        episode_id, production_version, manifest_code, status, pilot_shot_id, director_approval_id)
    values (
        v_episode.id, v_episode.production_version,
        v_episode.content_id || '-M' || v_episode.production_version,
        'DRAFT', v_first_shot_id, v_decision.id)
    returning id into v_manifest_id;

    insert into public.production_manifest_shots (manifest_id, shot_id, shot_specification_id, manifest_order)
    select v_manifest_id, s.id, ss.id, s.shot_order
    from public.shots s
    join public.shot_specifications ss on ss.shot_id = s.id and ss.is_active = true
    where s.episode_id = v_episode.id
    order by s.shot_order;

    perform set_config('m417.director_lock', 'on', true);
    update public.production_manifests set status = 'LOCKED' where id = v_manifest_id;
    perform set_config('m417.director_lock', 'off', true);

    -- Episode: approved by the director decision, then authorised.
    update public.episodes set state = 'APPROVED' where id = v_episode.id;
    perform public.authorize_episode_production(v_episode.id);

    perform m417_internal.event(
        'PRODUCTION_PACKAGE_COMMITTED', 'INFO',
        'Production package committed on Head Director decision; storyboard stage waived.',
        jsonb_build_object('job_id', p_job_id, 'director_decision_id', v_decision.id,
                           'manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total,
                           'storyboard_required', false),
        v_episode.id);

    perform m417_internal.set_step(
        p_job_id, case when v_line_total > 0 then 16 else 19 end, 'PRODUCTION_PACKAGE_COMMITTED',
        jsonb_build_object('manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total));

    return m417_internal.job_status(p_job_id)
        || jsonb_build_object('manifest_id', v_manifest_id, 'shots', v_idx, 'dialogue_lines', v_line_total);
end;
$function$;

create or replace function m417_internal.judge_voice_take(p_take_id uuid, p_score numeric, p_forced_fail text)
 returns text language plpgsql security definer set search_path to ''
as $function$
declare
    v_take public.shot_audio_productions;
    v_spec_duration numeric;
    v_other numeric;
    v_reason text := p_forced_fail;
    v_size bigint;
begin
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id for update;
    if not found then
        raise exception 'VOICE_TAKE_NOT_FOUND';
    end if;
    if v_take.status = 'APPROVED' then
        return 'PASS';
    elsif v_take.status = 'REJECTED' then
        return 'FAIL';
    elsif v_take.status not in ('GENERATED', 'QC_PENDING') then
        raise exception 'VOICE_TAKE_NOT_READY_FOR_QC: %', v_take.status;
    end if;

    -- Room for voice in the cut of this shot (the whole shot for shots
    -- planned before the film rules).
    v_spec_duration := m417_internal.voice_room(v_take.shot_specification_id);
    select coalesce(sum(o.duration_seconds), 0) into v_other
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order <> v_take.audio_order
      and o.is_canonical = true;
    v_size := coalesce((v_take.timing_metadata ->> 'file_size_bytes')::bigint, 0);

    if v_reason is null and v_size < m417_internal.num('min_audio_bytes', 2000) then
        v_reason := 'AUDIO_FILE_TOO_SMALL';
    end if;
    if v_reason is null
       and v_other + v_take.duration_seconds
           > v_spec_duration + m417_internal.num('voice_duration_tolerance_seconds', 0.5)
    then
        v_reason := format('DIALOGUE_LONGER_THAN_SHOT: %s s of dialogue in a %s s shot',
                           round(v_other + v_take.duration_seconds, 2), v_spec_duration);
    end if;

    if v_reason is null then
        update public.shot_audio_productions
        set status = 'APPROVED', qc_status = 'PASS',
            qc_score = m417_internal.score100(p_score),
            reviewed_at = now(), is_canonical = true
        where id = p_take_id;
        return 'PASS';
    end if;
    update public.shot_audio_productions
    set status = 'REJECTED', qc_status = 'FAIL',
        qc_score = m417_internal.score100(p_score),
        qc_notes = v_reason, reviewed_at = now()
    where id = p_take_id;
    return 'FAIL';
end;
$function$;

create or replace function m417_internal.voice_retake_plan(
    p_take_id uuid, out speed numeric, out fits boolean, out detail text)
 language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_take public.shot_audio_productions;
    v_spec_duration numeric;
    v_other numeric;
    v_available numeric;
    v_natural numeric;
    v_prev_speed numeric;
    v_max numeric := m417_internal.num('max_voice_speed', 1.3);
begin
    speed := 1; fits := true; detail := null;
    select t.* into v_take from public.shot_audio_productions t where t.id = p_take_id;
    if not found or coalesce(v_take.qc_notes, '') not like 'DIALOGUE_LONGER_THAN_SHOT%' then
        return;
    end if;
    -- Room for voice in the cut of this shot (the whole shot for shots
    -- planned before the film rules).
    v_spec_duration := m417_internal.voice_room(v_take.shot_specification_id);
    select coalesce(sum(o.duration_seconds), 0) into v_other
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order <> v_take.audio_order
      and o.is_canonical = true;
    v_available := v_spec_duration + m417_internal.num('voice_duration_tolerance_seconds', 0.5) - v_other;
    v_prev_speed := round(greatest(coalesce(m417_internal.safe_numeric(v_take.timing_metadata ->> 'requested_speed'), 1), 1), 2);
    -- Length at normal speed: the newest take of this line recorded at speed 1.
    select o.duration_seconds into v_natural
    from public.shot_audio_productions o
    where o.shot_specification_id = v_take.shot_specification_id
      and o.audio_order = v_take.audio_order
      and o.duration_seconds is not null
      and coalesce(m417_internal.safe_numeric(o.timing_metadata ->> 'requested_speed'), 1) <= 1.001
    order by o.take_no desc
    limit 1;
    v_natural := round(coalesce(v_natural, v_take.duration_seconds * v_prev_speed), 2);
    v_available := round(v_available, 2);
    if v_available <= 0 then
        fits := false;
        detail := format('needs %s s at normal speed; the other lines already fill the %s s shot', v_natural, v_spec_duration);
        return;
    end if;
    speed := ceil(v_natural / v_available * 1.04 * 100) / 100;
    if speed > v_max then
        fits := false;
        detail := format('needs %s s at normal speed, %s s are available in the %s s shot; faster than %sx is not allowed',
                         v_natural, v_available, v_spec_duration, v_max);
    elsif v_prev_speed >= speed - 0.005 then
        -- Already asked for this speed and it still did not fit.
        fits := false;
        detail := format('still %s s after a retake at %sx; %s s are available in the %s s shot',
                         round(v_take.duration_seconds, 2), v_prev_speed, v_available, v_spec_duration);
    end if;
end;
$function$;

create or replace function m417_internal.video_scan(p_mutate boolean)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_items jsonb := '[]'::jsonb;
    v_waiting integer := 0;
    v_gen boolean := m417_internal.flag('generation_enabled', false);
    v_stale interval := make_interval(mins => m417_internal.num('video_claim_stale_minutes', 5)::integer);
    v_poll_gap interval := make_interval(secs => m417_internal.num('video_poll_min_interval_seconds', 45));
    v_timeout interval := make_interval(mins => m417_internal.num('video_poll_timeout_minutes', 45)::integer);
    v_blank jsonb := jsonb_build_object(
        'action', '', 'job_id', '', 'shot_id', '', 'attempt_id', '', 'provider', '',
        'submit_url', '', 'provider_request_text', '', 'poll_url', '', 'download_url', '',
        'storage_path', '', 'qc_context_text', '', 'notify_chat_id', '', 'review_text', '',
        'storage_base_url', '');
    v_job record;
    v_shot record;
    v_att public.attempts;
    v_has_att boolean;
    v_out record;
    v_manifest_id uuid;
    v_pilot_id uuid;
    v_pilot_state text;
    v_blocked boolean;
    v_resets integer;
    v_open integer;
    v_locked integer;
    v_emits integer;
begin
    if m417_internal.flag('pipeline_enabled', false) is not true then
        return jsonb_build_object('items', v_items, 'waiting', 0);
    end if;

    -- An advance to assembly that Make has not confirmed is handed out again.
    for v_job in
        select j.id
        from public.production_jobs j
        where j.current_step = 30 and j.state = 'READY'
          and j.video_advanced_at is not null
          and j.video_advance_acked_at is null
    loop
        v_items := v_items || (v_blank || jsonb_build_object('action', 'ADVANCE', 'job_id', v_job.id));
    end loop;

    for v_job in
        select j.id, j.episode_id, e.content_id, e.production_version, s.series_code
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        join public.series s on s.id = j.series_id
        where j.current_step = 22 and j.state = 'READY'
        order by j.created_at
    loop
        select pm.id, pm.pilot_shot_id into v_manifest_id, v_pilot_id
        from public.production_manifests pm
        where pm.episode_id = v_job.episode_id
          and pm.production_version = v_job.production_version
          and pm.status = 'LOCKED';
        if not found then
            if p_mutate then
                perform m417_internal.block_job(v_job.id, 'LOCKED_MANIFEST_MISSING', null);
            end if;
            continue;
        end if;
        select s.state into v_pilot_state from public.shots s where s.id = v_pilot_id;
        v_blocked := false;

        for v_shot in
            select s.id, s.shot_code, s.state, ss.id as spec_id, ss.duration_seconds,
                   ss.narrative_action, ss.camera_movement, ss.dialogue, ss.continuity_notes,
                   ss.character_codes, ss.qc_brief
            from public.production_manifest_shots pms
            join public.shots s on s.id = pms.shot_id
            join public.shot_specifications ss on ss.id = pms.shot_specification_id
            where pms.manifest_id = v_manifest_id
            order by pms.manifest_order
        loop
            exit when v_blocked;
            continue when v_shot.state in ('LOCKED', 'CANCELLED');

            select a.* into v_att
            from public.attempts a
            where a.shot_id = v_shot.id
            order by a.attempt_no desc
            limit 1;
            v_has_att := found;

            if v_shot.state = 'ESCALATED' then
                select go.id, go.storage_path, go.qc_notes, go.qc_score into v_out
                from public.generation_outputs go
                where go.shot_id = v_shot.id
                  and go.storage_path is not null and btrim(go.storage_path) <> ''
                order by go.created_at desc
                limit 1;
                if not found then
                    if p_mutate then
                        perform m417_internal.block_job(
                            v_job.id, 'SHOT_FAILED_WITHOUT_OUTPUT',
                            v_shot.shot_code || ': both attempts failed and there is no clip to review.');
                    end if;
                    v_blocked := true;
                elsif exists (
                    select 1 from public.approval_requests ar
                    where ar.scope_type = 'SHOT_ESCALATION'
                      and ar.scope_id = v_shot.id
                      and ar.status = 'PENDING'
                      and ar.expires_at > now())
                then
                    null;  -- waiting for the owner
                else
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'HUMAN_REVIEW',
                        'job_id', v_job.id,
                        'shot_id', v_shot.id,
                        'storage_path', v_out.storage_path,
                        'notify_chat_id', m417_internal.txt('notify_chat_id', ''),
                        'storage_base_url', m417_internal.txt('storage_base_url', ''),
                        'review_text', format('%s / %s. QC: %s (score %s)',
                            v_job.content_id, v_shot.shot_code,
                            coalesce(nullif(v_out.qc_notes, ''), '-'),
                            coalesce(v_out.qc_score::text, '-'))));
                end if;

            elsif v_has_att and v_att.status = 'BUDGET_RESERVED' then
                if v_att.submission_claimed_at is null then
                    if v_gen then
                        v_items := v_items || (v_blank || jsonb_build_object(
                            'action', 'SUBMIT',
                            'job_id', v_job.id,
                            'shot_id', v_shot.id,
                            'attempt_id', v_att.id,
                            'provider', m417_internal.provider_route(v_att.provider),
                            'submit_url', m417_internal.submit_url(v_att.provider, v_att.model),
                            'provider_request_text', m417_internal.build_provider_request(v_att.id)));
                    end if;
                elsif v_att.submission_claimed_at < now() - v_stale then
                    select count(*) into v_resets
                    from public.events ev
                    where ev.attempt_id = v_att.id
                      and ev.event_type = 'ATTEMPT_SUBMISSION_CLAIM_RESET';
                    if v_resets >= 2 then
                        -- Three submissions that never produced a job id:
                        -- stop paying attention to this attempt.
                        if p_mutate then
                            perform public.release_generation_attempt_v2(
                                v_att.id, 'FAILED', 'SUBMISSION_FAILED_REPEATEDLY',
                                'The provider never returned a job id after 3 submissions.');
                            perform m417_internal.note_model_health(
                                v_att.id, 'DEGRADED', 'Submission failed repeatedly without a job id.');
                        end if;
                        v_waiting := v_waiting + 1;
                    else
                        v_items := v_items || (v_blank || jsonb_build_object(
                            'action', 'RECONCILE',
                            'job_id', v_job.id,
                            'shot_id', v_shot.id,
                            'attempt_id', v_att.id,
                            'provider', m417_internal.provider_route(v_att.provider)));
                    end if;
                else
                    v_waiting := v_waiting + 1;
                end if;

            elsif v_has_att and v_att.status in ('SUBMITTED', 'GENERATING') then
                if coalesce(v_att.started_at, v_att.created_at) < now() - v_timeout then
                    if p_mutate then
                        perform public.release_generation_attempt_v2(
                            v_att.id, 'FAILED', 'PROVIDER_TIMEOUT',
                            'No result from the provider within the time limit. Reservation released; check the provider bill for this job id.');
                        perform m417_internal.event(
                            'VIDEO_PROVIDER_TIMEOUT', 'CRITICAL',
                            'A submitted video attempt timed out. The provider may still have charged for it.',
                            jsonb_build_object('provider', v_att.provider, 'provider_job_id', v_att.provider_job_id,
                                               'estimated_cost', v_att.estimated_cost),
                            v_job.episode_id, v_shot.id, v_att.id);
                        perform m417_internal.note_model_health(v_att.id, 'DEGRADED', 'Generation timed out.');
                    end if;
                    v_waiting := v_waiting + 1;
                elsif v_att.last_provider_check_at is null
                   or v_att.last_provider_check_at < now() - v_poll_gap then
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'POLL',
                        'job_id', v_job.id,
                        'shot_id', v_shot.id,
                        'attempt_id', v_att.id,
                        'provider', m417_internal.provider_route(v_att.provider),
                        'poll_url', m417_internal.poll_url(v_att.provider, v_att.provider_job_id)));
                else
                    v_waiting := v_waiting + 1;
                end if;

            elsif v_has_att and v_att.status = 'SUCCEEDED'
              and v_shot.state in ('GENERATED', 'QC_PENDING') then
                v_emits := 1;
                if p_mutate then
                    insert into public.video_action_state (attempt_id, output_emits)
                    values (v_att.id, 1)
                    on conflict (attempt_id) do update
                        set output_emits = public.video_action_state.output_emits + 1, updated_at = now()
                    returning output_emits into v_emits;
                end if;
                v_items := v_items || (v_blank || jsonb_build_object(
                    'action', 'PROCESS_OUTPUT',
                    'job_id', v_job.id,
                    'shot_id', v_shot.id,
                    'attempt_id', v_att.id,
                    'provider', m417_internal.provider_route(v_att.provider),
                    'download_url', coalesce(v_att.provider_result_url, ''),
                    'storage_path', format('%s/%s/video/%s_A%s_%s.mp4',
                        v_job.series_code, v_job.content_id, v_shot.shot_code, v_att.attempt_no,
                        m417_internal.rand_suffix()),
                    'qc_context_text', jsonb_build_object(
                        'shot', v_shot.shot_code,
                        'duration_seconds', v_shot.duration_seconds,
                        'action', v_shot.narrative_action,
                        'camera', v_shot.camera_movement,
                        'dialogue', case when m417_internal.flag('lip_sync_enforced', false)
                                         then v_shot.dialogue else null end,
                        'continuity_notes', v_shot.continuity_notes,
                        'film', v_shot.qc_brief,
                        'characters', (
                            select coalesce(jsonb_agg(jsonb_build_object(
                                       'name', c.name, 'description', c.canonical_description,
                                       'look_notes', (
                                           select v.wardrobe_note
                                           from public.asset_registry ar
                                           join public.video_reference_images v
                                             on v.asset_id = ar.id and v.is_active = true
                                           where ar.character_id = c.id
                                             and coalesce(btrim(v.wardrobe_note), '') <> ''
                                           limit 1))), '[]'::jsonb)
                            from public.characters c
                            where c.status = 'LOCKED'
                              and v_shot.character_codes ? c.character_code))::text));

            elsif v_shot.state in ('STORYBOARD_APPROVED', 'AUDIO_READY', 'RETRY_REQUIRED') then
                if not v_gen then
                    null;  -- paid generation is switched off
                elsif v_shot.id = v_pilot_id or v_pilot_state = 'LOCKED' then
                    v_items := v_items || (v_blank || jsonb_build_object(
                        'action', 'ACQUIRE', 'job_id', v_job.id, 'shot_id', v_shot.id));
                elsif v_pilot_state = 'CANCELLED' then
                    if p_mutate then
                        perform m417_internal.block_job(
                            v_job.id, 'PILOT_SHOT_CANCELLED',
                            'The pilot shot was cancelled; the remaining shots cannot pass the pilot gate.');
                    end if;
                    v_blocked := true;
                elsif v_pilot_state <> 'ESCALATED' then
                    v_waiting := v_waiting + 1;  -- pilot still in progress
                end if;
            end if;
        end loop;

        continue when v_blocked;

        select count(*) filter (where s.state not in ('LOCKED', 'CANCELLED')),
               count(*) filter (where s.state = 'LOCKED')
        into v_open, v_locked
        from public.production_manifest_shots pms
        join public.shots s on s.id = pms.shot_id
        where pms.manifest_id = v_manifest_id;

        if v_open = 0 then
            if v_locked = 0 then
                if p_mutate then
                    perform m417_internal.block_job(v_job.id, 'ALL_SHOTS_CANCELLED', null);
                end if;
            else
                -- The step moves before Make is told, so the assembly
                -- scenario finds the job at step 30 when it is called.
                if p_mutate then
                    update public.episodes set state = 'ASSEMBLY' where id = v_job.episode_id;
                    perform m417_internal.set_step(
                        v_job.id, 30, 'VIDEO_COMPLETE', jsonb_build_object('locked_shots', v_locked));
                    update public.production_jobs set video_advanced_at = now() where id = v_job.id;
                end if;
                v_items := v_items || (v_blank || jsonb_build_object('action', 'ADVANCE', 'job_id', v_job.id));
            end if;
        end if;
    end loop;

    return jsonb_build_object('items', v_items, 'waiting', v_waiting);
end;
$function$;

create or replace function public.create_render(p_job_id uuid, p_signed_urls jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_job public.production_jobs;
    v_render public.renders;
    v_base text := rtrim(m417_internal.txt('storage_base_url', ''), '/');
    v_urls jsonb := '{}'::jsonb;
    v_item jsonb;
    v_edit jsonb;
    v_clip jsonb;
    v_video jsonb := '[]'::jsonb;
    v_voice jsonb := '[]'::jsonb;
    v_sfx jsonb := '[]'::jsonb;
    v_soundtrack jsonb;
    v_tracks jsonb := '[]'::jsonb;
    v_timeline jsonb;
    v_request jsonb;
    v_url text;
    v_total numeric;
begin
    v_job := m417_internal.lock_job(p_job_id);
    if v_job.state <> 'READY' or v_job.current_step not between 31 and 32 then
        raise exception 'STEP_MISMATCH: job is at step % (%)', v_job.current_step, v_job.state;
    end if;
    if v_base = '' then
        raise exception 'STORAGE_BASE_URL_NOT_SET: set system_text_settings.storage_base_url';
    end if;
    select r.* into v_render
    from public.renders r where r.job_id = p_job_id and r.status = 'CREATED'
    order by r.render_no desc limit 1
    for update;
    if not found then
        raise exception 'NO_RENDER_WAITING_FOR_A_TIMELINE';
    end if;
    if p_signed_urls is null or jsonb_typeof(p_signed_urls) <> 'array' then
        raise exception 'SIGNED_URLS_MUST_BE_ARRAY';
    end if;

    for v_item in select * from jsonb_array_elements(p_signed_urls)
    loop
        v_url := coalesce(v_item ->> 'signedURL', v_item ->> 'signedUrl');
        if v_url is not null and coalesce(v_item ->> 'error', '') = '' then
            v_urls := v_urls || jsonb_build_object(
                v_item ->> 'path',
                case when v_url like 'http%' then v_url
                     else v_base || case when v_url like '/%' then v_url else '/' || v_url end end);
        end if;
    end loop;

    v_edit := m417_internal.edit_list(p_job_id);
    v_total := (v_edit ->> 'total_seconds')::numeric;

    for v_clip in select * from jsonb_array_elements(v_edit -> 'shots')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        v_video := v_video || jsonb_build_object(
            'asset', jsonb_build_object('type', 'video', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 0)
                     || case when coalesce((v_clip ->> 'trim')::numeric, 0) > 0
                             then jsonb_build_object('trim', (v_clip ->> 'trim')::numeric) else '{}'::jsonb end,
            'start', (v_clip ->> 'start')::numeric,
            'length', (v_clip ->> 'length')::numeric,
            'fit', 'cover');
    end loop;
    for v_clip in select * from jsonb_array_elements(v_edit -> 'voices')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        v_voice := v_voice || jsonb_build_object(
            'asset', jsonb_build_object('type', 'audio', 'src', v_urls ->> (v_clip ->> 'path'), 'volume', 1),
            'start', (v_clip ->> 'start')::numeric,
            'length', (v_clip ->> 'length')::numeric);
    end loop;
    for v_clip in select * from jsonb_array_elements(v_edit -> 'music')
    loop
        if not (v_urls ? (v_clip ->> 'path')) then
            raise exception 'SIGNED_URL_MISSING: %', v_clip ->> 'path';
        end if;
        if v_clip ->> 'role' = 'MUSIC' and v_soundtrack is null then
            v_soundtrack := jsonb_build_object(
                'src', v_urls ->> (v_clip ->> 'path'),
                'effect', 'fadeOut',
                'volume', (v_clip ->> 'volume')::numeric);
        else
            v_sfx := v_sfx || jsonb_build_object(
                'asset', jsonb_build_object('type', 'audio', 'src', v_urls ->> (v_clip ->> 'path'),
                                            'volume', (v_clip ->> 'volume')::numeric),
                'start', least((v_clip ->> 'start')::numeric, greatest(v_total - 0.5, 0)),
                'length', greatest(least(coalesce((v_clip ->> 'end')::numeric, v_total), v_total)
                                   - least((v_clip ->> 'start')::numeric, greatest(v_total - 0.5, 0)), 0.5));
        end if;
    end loop;

    -- Shotstack draws the first track on top; audio order does not matter.
    if jsonb_array_length(v_voice) > 0 then
        v_tracks := v_tracks || jsonb_build_object('clips', v_voice);
    end if;
    if jsonb_array_length(v_sfx) > 0 then
        v_tracks := v_tracks || jsonb_build_object('clips', v_sfx);
    end if;
    v_tracks := v_tracks || jsonb_build_object('clips', v_video);

    v_timeline := jsonb_build_object('background', '#000000', 'tracks', v_tracks);
    if v_soundtrack is not null then
        v_timeline := v_timeline || jsonb_build_object('soundtrack', v_soundtrack);
    end if;
    v_request := jsonb_build_object(
        'timeline', v_timeline,
        'output', jsonb_build_object(
            'format', 'mp4',
            'aspectRatio', '9:16',
            'resolution', m417_internal.txt('render_resolution', 'hd')));

    update public.renders
    set request = v_request, updated_at = now()
    where id = v_render.id;
    update public.production_jobs set last_activity_at = now() where id = p_job_id;

    return jsonb_build_object(
        'render_id', v_render.id,
        'shotstack_request_text', v_request::text,
        'total_seconds', v_total);
end;
$function$;

create or replace function public.complete_render(p_render_id uuid, p_storage_path text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_render public.renders;
    v_job public.production_jobs;
    v_size bigint;
begin
    select r.* into v_render from public.renders r where r.id = p_render_id for update;
    if not found then
        raise exception 'RENDER_NOT_FOUND';
    end if;
    if v_render.status not in ('DONE', 'STORED') then
        raise exception 'RENDER_NOT_DONE: %', v_render.status;
    end if;
    v_size := m417_internal.object_size(p_storage_path);
    if v_size is null then
        raise exception 'RENDER_FILE_NOT_FOUND_IN_STORAGE: %', coalesce(p_storage_path, '(empty)');
    end if;
    if v_size < m417_internal.num('min_video_bytes', 20000) then
        raise exception 'RENDER_FILE_TOO_SMALL: % bytes', v_size;
    end if;
    v_job := m417_internal.lock_job(v_render.job_id);

    update public.renders
    set status = 'STORED', storage_path = p_storage_path, updated_at = now()
    where id = p_render_id;

    -- An edit rendered again after the owner resumed a job stopped at
    -- final QC arrives here with the job already at step 32; the episode
    -- has to reach FINAL_QC on that path as well.
    if v_job.state = 'READY' and v_job.current_step in (31, 32) then
        update public.episodes set state = 'FINAL_QC'
        where id = v_job.episode_id and state = 'ASSEMBLY';
    end if;
    if v_job.current_step = 31 and v_job.state = 'READY' then
        perform m417_internal.set_step(
            v_job.id, 32, 'RENDER_STORED', jsonb_build_object('render_id', p_render_id, 'storage_path', p_storage_path));
    end if;
    return m417_internal.job_status(v_job.id)
        || jsonb_build_object('render_id', p_render_id, 'status', 'STORED');
end;
$function$;

create or replace function m417_internal.block_reason_tr(p_reason text)
 returns text language sql immutable set search_path to ''
as $function$
    select case p_reason
        when 'VIDEO_PREREQUISITES_MISSING' then 'Video üretimi için gereken model kaydı ya da bütçe eksik.'
        when 'NO_ACTIVE_ROUTING_POLICY' then 'Video modeli seçme kuralı tanımlı değil.'
        when 'NO_ELIGIBLE_VIDEO_MODEL' then 'Bu sahneyi üretebilecek uygun bir video modeli yok.'
        when 'VIDEO_ATTEMPT_REFUSED' then 'Video denemesi başlatılamadı (bütçe ya da hazırlık kontrolü).'
        when 'VOICE_TAKE_LIMIT_REACHED' then 'Bir replik için izin verilen ses denemeleri bitti.'
        when 'DIALOGUE_DOES_NOT_FIT_SHOT' then 'Bir replik, sahnesine sığmıyor.'
        when 'POLICY_GATE_1_FAILED' then 'Konu, çocuk güvenliği kontrolünden geçemedi.'
        when 'POLICY_GATE_2_FAILED' then 'Bitmiş video, güvenlik kontrolünden geçemedi.'
        when 'REVISION_LIMIT_REACHED' then 'Senaryo, izin verilen düzeltme sayısında onaylanamadı.'
        when 'VALIDATION_RETRY_LIMIT_REACHED' then 'Senaryo ya da sahne paketi kurallara uydurulamadı.'
        when 'FINAL_QC_FAILED' then 'Bitmiş video kalite kontrolünden geçemedi.'
        when 'RENDER_LIMIT_REACHED' then 'İzin verilen montaj denemeleri bitti.'
        when 'RELEASE_REJECTED' then 'Baş Yönetmen bitmiş videoyu onaylamadı.'
        when 'PUBLISH_REJECTED_BY_OWNER' then 'Yayın onayını sen reddettin.'
        when 'ALL_SHOTS_CANCELLED' then 'Bütün sahneler iptal edildi.'
        when 'PILOT_SHOT_CANCELLED' then 'İlk (pilot) sahne iptal edildi.'
        when 'SHOT_FAILED_WITHOUT_OUTPUT' then 'Bir sahne iki denemede de üretilemedi.'
        when 'BUDGET_GATE_1_FAILED' then 'Bütçe yetersiz ya da bu ay için bütçe açılmamış.'
        when 'BUDGET_GATE_2_FAILED' then 'Video için kalan bütçe yetersiz.'
        when 'SCRIPT_NOT_AGREED' then 'Yönetmen ile yardımcı yönetmen senaryoda anlaşamadı; iki evet çıkmadı.'
        when 'STALLED' then 'İş ilerlemiyor; otomatik yeniden başlatmalar sonuç vermedi.'
        else 'Sistem bir kontrol noktasında durdu.'
    end;
$function$;

-- ----- the instructions, version 1 -----------------------------------
update public.step_prompts set is_active = false
where prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE', 'PREQC', 'DIRECTOR', 'FINAL_QC') and version <> 1 and is_active;

insert into public.step_prompts (prompt_code, version, is_active, note, body) values
('TOPIC', 1, true, 'Step 7, Head Director: choose the story idea.', $p$Choose the single best story idea for the next WIZZLEBURY episode: a vertical animated short of [[EP_MIN]] to [[EP_MAX]] seconds for children and families.

A good idea is a tiny complete story, not a situation:
- One character wants something concrete; something gets in the way; it escalates in two or three steps; it ends on a surprise that is funny or warm.
- It can be told almost entirely in pictures. A viewer with the sound off still understands it.
- The very first image makes a stranger stop scrolling: something is already happening and raises a question.
- The comedy comes from who the characters are (their traits in the series bible), not from random events.
- It is easy to film with an AI video model in short separate shots: at most [[MAX_CAST]] characters in a picture, simple big physical actions, clear props. Avoid readable text, screens, crowds, sports with fast balls, water and liquids, mirrors, tiny hand work.
- Canon and child safety outweigh trend appeal. Nothing dangerous that a child could copy.

If the production request contains a brief, follow it. Never repeat a topic listed under rejected_topics in the request; read why it was rejected.

Trend report: [[TRENDS]]
Series bible: [[BIBLE]]
Production request: [[REQUEST]]

Return exactly this JSON shape:
{"title": "", "premise": "", "source_trend": "", "characters": [""], "location": "", "emotional_beat": "", "hook": "", "target_duration_seconds": 0, "rationale": "", "rejected_alternatives": [{"topic": "", "reason": ""}]}

premise tells the whole story in three to five sentences: the want, the obstacle, each escalation, the payoff. hook is the first image. characters and location are codes from the series bible.$p$),

('SCRIPT', 1, true, 'Step 10, Head Director: write the script.', $p$Write the script of this WIZZLEBURY episode. You are the Head Director and the writer. The Assistant Director will read your script, score it and vote YES or NO; nothing is filmed without that YES and your own final YES. Write the script you would be proud to sign.

LENGTH AND SHAPE
- The finished episode lasts [[EP_MIN]] to [[EP_MAX]] seconds and will be cut into [[SHOTS_MIN]] to [[SHOTS_MAX]] short shots. Scene durations add up to a total inside that range.
- At most [[LINES_MAX]] spoken lines. Every line is one short sentence of at most [[LINE_CHARS]] characters, spaces included. Lines are checked automatically against real speaking time.

STORY
- hook: the first two seconds. Start in the middle of something already happening; put a question in the viewer's head. No greeting, no setup, no title.
- Then a clear want, an obstacle, two or three escalations each bigger than the last, a turn nobody expected, and a payoff that answers the hook. End on a short button: one last look, line or gag.
- Tell it in pictures. Dialogue is real conversation between the characters: short, quick, back and forth, each line answering the one before; one character never explains the plot. Give the funniest words to the character whose nature they fit.
- Every character acts from the traits, weaknesses and relationships in the series bible. The lead character drives the story.
- Warm, funny, lively. Never scary, never mean, nothing a child could copy and get hurt.

WRITE IT SO IT CANNOT BE FILMED WRONG
Each shot is later generated separately by an AI video model that sees only one description at a time and remembers nothing. Whatever you leave open, it will invent differently in every shot.
- action of every scene: who is where (left, right, foreground, background), what exactly happens in order, what causes what, and how each character reacts. State exact counts and what must not happen ("one ball, never two", "the tree does not fall").
- wardrobe: one outfit per character for the whole episode, chosen for the place and the activity (school, park, sport, rain, a party ...). Garments, colours, shoes, anything worn or carried. Modest and suitable for a child; no logos, brands or writing. Every character has a clearly different look and main colour; the lead is the most eye-catching. Anything in look_notes of a character in the series bible always holds.
- props: every object that matters, with colour, size, material and exact count. One entry per object. Describe it once here and use the same name everywhere.
- look: time of day, weather, light and colour mood, the same in every shot.
- Only characters and locations from the series bible, by their codes. Only characters with has_voice = true speak.
- Keep it filmable: at most [[MAX_CAST]] characters seen at once, simple big physical actions, clear props. Avoid readable text and signs, screens, crowds, fast ball games, water and liquids, mirrors, tiny hand work such as tying knots.

INPUTS
Selected topic: [[TOPIC]]
Series bible: [[BIBLE]]
Previous script (if any): [[SCRIPT]]
Feedback on the previous script (if any): [[FEEDBACK]]

If there is feedback, this is a rewrite. Meet every required change and fix every problem, keep what was praised, and say in revision_notes what you changed. If the feedback gives scores, raise the weak ones: a better hook, a sharper turn, funnier lines.

Return exactly this JSON shape:
{"title": "", "logline": "", "hook": "", "payoff": "", "look": "", "wardrobe": [{"character": "", "outfit": ""}], "props": [{"name": "", "description": ""}], "scenes": [{"scene_no": 1, "location": "", "characters": [""], "duration_seconds": 0, "action": "", "dialogue": [{"line_no": 1, "character": "", "text": "", "emotion": ""}], "sound_notes": ""}], "total_duration_seconds": 0, "revision_notes": ""}

line_no restarts at 1 in every scene. A scene without speech has an empty dialogue array. Before answering, check: the total is inside the range; no line is longer than [[LINE_CHARS]] characters; every character has an outfit; every object that matters is a prop; a stranger could draw each scene from its action alone.$p$),

('SHOT_PACKAGE', 1, true, 'Step 11, Assistant Director: vote on the script, then plan the shots.', $p$You are the Assistant Director of WIZZLEBURY, a premium stylized 3D animated series of vertical shorts for children and families. Claude, the Head Director, wrote the script below. You do two things in one answer: you vote on the script, and if your vote is YES you plan every shot.

PART 1 - YOUR VOTE (two-yes rule)
Nothing is filmed unless you and the Head Director both say YES. Read the script as the viewer who decides in two seconds whether to keep watching, and as the person who has to film it.
Score each from 1 to 10:
- hook: do the first two seconds stop a stranger from scrolling?
- story: want, obstacle, escalation, a real turn, a payoff that lands?
- humor: is it actually funny or charming, from character and not from accident?
- dialogue: short, natural, back and forth, each line worth its seconds?
- filmability: can an AI video model shoot it in short separate shots without ambiguity? Are wardrobe, props and look exact?
Vote YES only if you would film exactly this script and every score is at least [[MIN_SCORE]]. Otherwise vote NO. A NO costs nothing; a weak episode costs the channel. Do not vote NO for things you can solve yourself in the staging.
When you vote NO: problems says precisely what is weak and where; required_changes gives concrete rewrites - a better hook image, a sharper line, a stronger payoff - that would earn your YES. Return "shots": [].
Your last rejection of this topic (if any): [[LAST_REJECTION]]
If there is one, check that each required change was met before you vote.

PART 2 - THE SHOT PACKAGE (only when you vote YES)
Turn the script into the complete edit of the episode: every cut, planned to a tenth of a second. Do not change the story, the dialogue text or who speaks.

How the film is made: every shot is generated separately by an AI video model as a clip of [[GEN_SECONDS]] seconds, and the edit uses the first edit_seconds of it. The model sees one shot at a time and remembers nothing.

THE EDIT
- [[SHOTS_MIN]] to [[SHOTS_MAX]] shots. Each cut lasts [[CUT_MIN]] to [[CUT_MAX]] seconds (edit_seconds, one decimal). The cuts add up to [[EP_MIN]] to [[EP_MAX]] seconds.
- Shot 1 is the hook: the most striking image of the story, at most [[HOOK_MAX]] seconds.
- shot_size is one of EXTREME_WIDE, WIDE, MEDIUM, MEDIUM_CLOSE, CLOSE_UP, EXTREME_CLOSE_UP, INSERT, OVER_SHOULDER. Two neighbouring shots never have the same size. Use at least three sizes. One of the first three shots is WIDE or EXTREME_WIDE so the viewer knows where we are. Use close shots for reactions and INSERT shots for the object that matters.
- Cut like a film: establish, act, react. Show the cause, then the face that sees it. Vary the rhythm: quick cuts of about one second for reactions and surprises, longer ones for action and for lines. End on the payoff and a short button.
- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.

DIALOGUE
- At most one spoken line per shot. A conversation is a chain of shots: the speaker, then the answer, then a reaction. Every script line goes into dialogue_line_nos of exactly one shot of its own scene (line numbers restart in every scene).
- A shot with a line lasts at least the speaking time of the line plus half a second (see dialogue_timing_rule in the series bible).
- voice_staging says how the speaker is staged: ON_CAMERA (seen talking; shot size MEDIUM_CLOSE or wider), OFF_SCREEN (not in the shot: we watch the listener react, or an object) or BACK_TO_CAMERA (seen from behind, typically OVER_SHOULDER on the listener). Exact lip-sync is not produced yet, so nobody speaks in a CLOSE_UP or EXTREME_CLOSE_UP: those are silent looks, reactions and laughs.
- characters lists exactly the characters visible in the shot, at most [[MAX_CAST]]; one or two is better. An OFF_SCREEN speaker is not listed.

EVERY SHOT
- beats: what happens when inside the cut, in seconds from its start: [{"at": 0.0, "what": "..."}, {"at": 0.6, "what": "..."}]. The first beat is at 0. Each beat is one visible action or change of expression. The action must start at once: the cut is short.
- video_prompt: what the video model reads. Plain English, present tense, [[PROMPT_MIN]] to 800 characters, one continuous shot without cuts. In this order: who is where in the frame, what each one does and how, expressions and body language, the place around them. Characters by their plain names exactly as in the series bible. No codes, no file names, no brackets, no spoken words. Self-contained: never "as before" or "the same".
- Do not describe faces, hair, outfits, props or the light in video_prompt: the system adds the wardrobe, the listed props and the look from the script to every shot in identical words. Name the props the shot shows in props, using the prop names of the script.
- Acting is specific and visible: eyebrows, eyes, hands, posture ("her eyes go wide, then a slow grin spreads"). One clear action per shot, simple and physically plausible.
- camera: angle and movement (static, slow push-in, pan, low angle ...). action: one sentence. acting: the emotional beat. purpose: HOOK, SETUP, ACTION, REACTION, DIALOGUE, PAYOFF or BUTTON. negative_prompt: a short comma-separated list of what to avoid. continuity_notes: what must match the neighbouring shots.
- duration_seconds is always [[GEN_SECONDS]]. aspect_ratio is always "9:16". shot_no counts 1, 2, 3 ... through the episode. location is a location code.

INPUTS
Script: [[SCRIPT]]
Series bible: [[BIBLE]]
Previous shot package (if any): [[SHOT_PACKAGE]]
Feedback on the previous shot package (if any): [[FEEDBACK]]
If there is feedback on the shots, this is a revision: fix every listed issue and return the complete package again, including the shots that did not change. If the script did not change, repeat your vote.

Return one raw JSON object only, no markdown, no code fences, in exactly this shape:
{"script_vote": {"decision": "YES or NO", "scores": {"hook": 0, "story": 0, "humor": 0, "dialogue": 0, "filmability": 0}, "strengths": [""], "problems": [""], "required_changes": [""]}, "shots": [{"shot_no": 1, "scene_no": 1, "purpose": "", "shot_size": "", "camera": "", "duration_seconds": [[GEN_SECONDS]], "edit_seconds": 0.0, "aspect_ratio": "9:16", "characters": [""], "location": "", "props": [""], "beats": [{"at": 0.0, "what": ""}], "dialogue_line_nos": [], "voice_staging": "", "action": "", "acting": "", "video_prompt": "", "negative_prompt": "", "continuity_notes": ""}], "total_edit_seconds": 0.0, "continuity_risks": [""]}

Before answering, check your own work: the number of shots and the sum of the cuts are inside the limits; shot 1 is at most [[HOOK_MAX]] seconds; no two neighbours share a size; a wide shot is among the first three; every script line is in exactly one shot and that shot is long enough; nobody speaks in a close-up; every shot has beats starting at 0; every video_prompt is self-contained and free of codes.$p$),

('PREQC', 1, true, 'Step 12, QC Inspector: check the package before production.', $p$You are the Pre-Production QC Inspector of WIZZLEBURY. This is a planning gate only. Review the script and the shot package against the series bible before any money is spent.

How the film is made: every shot is generated separately by an AI video model that sees only the video_prompt of that shot (the system adds the wardrobe, the props and the look of the script to each one), and the edit uses the first edit_seconds of each clip. Voices are recorded separately and laid over the cuts; exact lip-sync is not produced and is not an issue to report.

Check:
- Canon: characters behave and speak as the series bible says; only known characters and locations.
- Story on screen: do the shots, in order, tell the script so that a viewer with the sound off understands it? Does shot 1 hook? Does the last shot pay off?
- Continuity between shots: where each character stands, which props are present, what happened before. A video_prompt that depends on another shot ("as before") is an issue.
- Ambiguity: anything the video model could show wrongly - unclear counts, unclear cause and effect, two actions in one shot, an action that cannot be shown in the length of the cut.
- Dialogue: every line is in the right shot, the speaker is staged as voice_staging says, nobody else is described as talking.
- Wardrobe and props: suitable for children, without logos, brands or writing; exact enough to look the same in every shot.
- Child safety: nothing frightening, nothing dangerous to copy.
Lengths, shot counts, shot sizes and line timing were already checked by the system; do not report them.

Script: [[SCRIPT]]
Shot package: [[SHOT_PACKAGE]]
Series bible: [[BIBLE]]

OUTPUT FORMAT (mandatory). Respond with exactly one raw JSON object. No markdown, no code fences, no commentary, no extra keys:
{"verdict": "PASS or REVISE_SCRIPT or REVISE_SHOTS", "issues": [{"target": "SCRIPT or SHOTS", "ref": "scene / line / shot reference", "severity": "LOW or MEDIUM or HIGH", "detail": "what is wrong", "fix": "what to change"}], "continuity_status": "PASS or FAIL", "character_identity_status": "PASS or FAIL", "lip_sync_status": "READY", "notes": "short summary"}

Rules:
- The key is "verdict". "issues" is an empty array when nothing needs fixing.
- If any issue has severity MEDIUM or HIGH, the verdict is REVISE_SCRIPT (the problem is in the script) or REVISE_SHOTS (the problem is in the shot package). Use MEDIUM or HIGH only for something that would visibly damage the episode or break a rule; say exactly what to change.
- LOW issues alone do not block: the verdict is PASS.$p$),

('DIRECTOR', 1, true, 'Step 14, Head Director: the final YES or NO.', $p$Make the final Head Director decision on this production package. This is the second YES of the two-yes rule: the Assistant Director has voted YES on your script and planned the shots. Your APPROVE authorizes paid production, so approve only a package you would stake the episode budget on.

Read the shot package as the finished film, cut by cut:
- Does shot 1 stop a stranger from scrolling?
- Does every cut show exactly one clear thing, and does the order tell the story without sound?
- Do the cuts breathe - wide to place us, close for faces, inserts for the object that matters - and does the rhythm build to the payoff?
- Is every video_prompt complete on its own and impossible to misread?
- Is the dialogue staged as a real exchange?

APPROVE requires a pre-QC verdict of PASS and no child-safety concern. Use REVISE_SHOTS when the shots do not do the script justice, and REVISE_SCRIPT when the script itself must change (the Assistant Director will vote again); give precise required_changes. Use REJECT only when the topic itself cannot work.

Script: [[SCRIPT]]
Assistant Director's vote and review: [[ASSISTANT_REVIEW]]
Shot package: [[SHOT_PACKAGE]]
Pre-QC report: [[PREQC_REPORT]]
Series bible: [[BIBLE]]

Return exactly this JSON shape:
{"decision": "APPROVE, REVISE_SCRIPT, REVISE_SHOTS or REJECT", "director_notes": "", "required_changes": [""], "child_safety_status": "PASS or FAIL", "production_ready": true}$p$),

('FINAL_QC', 1, true, 'Steps 31-32, QC Inspector: judge the finished edit.', $p$You are the Final QC Inspector of WIZZLEBURY. Watch the attached finished edit of a family-friendly vertical animated short, with sound, and judge it against the script and the planned edit below.

How it was made: every cut is a separately generated clip; the voices were recorded separately and laid over the cuts. Exact lip-sync is not produced in this version: do not fail the edit for lip-sync, and report lip_sync as FAIL only when a character who is not the speaker is clearly the one talking during a line.

Check:
- dialogue_match: every scripted line is audible, in order, and its words match the script.
- audio_mix: voices are clear, do not overlap each other and are not masked by music.
- edit_order: the cuts follow the planned edit and tell the story of the script.
- character_consistency: each character looks like the same child in every cut (face, hair, outfit as in wardrobe of the script).
- visual_artifacts: glitches, black frames, broken anatomy, duplicated characters or objects, unwanted text. A prop or background that looks slightly different between two cuts is reported in notes but does not fail the edit by itself. A small "shotstack" watermark, if present, comes from the editor's trial mode: ignore it.
- duration_and_format: vertical 9:16, about [[TOTAL_SECONDS]] seconds long (within two seconds).
- child_safety: nothing frightening, nothing dangerous to copy.
Be strict about real defects a viewer would notice; do not fail for matters of taste.

Script: [[SCRIPT]]
Planned edit: [[EDIT_PLAN]]

Return one raw JSON object only, no markdown, no code fences. score is between 0 and 1.
{"verdict": "PASS or FAIL", "score": 0.0, "notes": "", "details": {"dialogue_match": "PASS or FAIL", "lip_sync": "PASS or FAIL", "audio_mix": "PASS or FAIL", "edit_order": "PASS or FAIL", "character_consistency": "PASS or FAIL", "visual_artifacts": "PASS or FAIL", "duration_and_format": "PASS or FAIL", "child_safety": "PASS or FAIL"}}$p$)
on conflict (prompt_code, version) do update
    set body = excluded.body, note = excluded.note, is_active = true;

-- =====================================================================
-- 12. Short format (012): camera plan, loop scripts, keyframe first
-- =====================================================================
-- Why: a video model that gets only words and character references
-- invents the composition of every shot again - heights, outfits and
-- framing drift from shot to shot. From here on a still picture of the
-- first instant of every shot is generated first, the owner approves it,
-- and the video model animates that exact picture. The camera is
-- planned from a fixed vocabulary instead of free text, and a script is
-- one small looping story.

-- ----- storage -------------------------------------------------------
-- One row per still picture made for a shot. Only a picture the owner
-- approved may become the start frame of a paid video generation.
create table if not exists public.shot_keyframes (
    id uuid primary key default gen_random_uuid(),
    job_id uuid not null references public.production_jobs(id) on delete restrict,
    shot_id uuid not null references public.shots(id) on delete restrict,
    take_no integer not null,
    status text not null default 'PENDING',
    prompt text not null,
    reference_images jsonb not null default '[]'::jsonb,
    storage_path text,
    handed_out_at timestamptz,
    check_score numeric,
    check_result jsonb,
    note text,
    decided_by text,
    decided_at timestamptz,
    created_at timestamptz not null default now(),
    constraint shot_keyframes_status_check check (status in ('PENDING', 'GENERATED', 'APPROVED', 'REJECTED', 'FAILED')),
    constraint shot_keyframes_take_check check (take_no > 0),
    constraint shot_keyframes_take_unique unique (shot_id, take_no),
    constraint shot_keyframes_decided_check check (status <> 'APPROVED' or (decided_by is not null and decided_at is not null))
);
create unique index if not exists uq_shot_keyframes_approved
    on public.shot_keyframes (shot_id) where (status = 'APPROVED');
create index if not exists idx_shot_keyframes_job on public.shot_keyframes (job_id, created_at);
alter table public.shot_keyframes enable row level security;

do $$
declare
    v_role text;
begin
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on public.shot_keyframes from %I', v_role);
        end if;
    end loop;
end $$;

insert into public.system_flags (key, value, description) values
    ('keyframe_required', false, 'Keyframe first: no paid video generation for a shot until the owner approved a still picture of its first frame.'),
    ('camera_plan_enforced', false, 'Every shot names a camera angle, a camera move and its first frame from the fixed vocabulary.'),
    ('short_format_enforced', false, 'A script is one looping short: it states how it loops, its music mood, and keeps every line to a few words.')
on conflict (key) do nothing;

insert into public.system_settings (key, value_numeric, description) values
    ('max_keyframe_takes', 3, 'Pictures tried for one shot before a person has to look.'),
    ('keyframe_min_score', 70, 'A picture scored below this by the automatic check is made again (0-100).'),
    ('keyframe_handout_seconds', 300, 'A picture handed out for generation and not delivered is handed out again after this long.'),
    ('min_keyframe_bytes', 5000, 'Smallest file accepted as a picture.'),
    ('max_line_words', 6, 'Most words in one spoken line of a short.'),
    ('max_beats_per_shot', 3, 'Most timed beats in one shot of a short: one event and the reaction to it.'),
    ('max_parallel_video_attempts', 3, 'Most video generations in flight at the same time, over all jobs.')
on conflict (key) do nothing;

insert into public.system_text_settings (key, value, description) values
    ('keyframe_bucket', 'public-refs', 'Public storage bucket for keyframe pictures; the video model fetches them by URL.'),
    ('keyframe_model', 'gemini-3.1-flash-image', 'Image model that draws the keyframes.'),
    ('keyframe_image_size', '1K', 'Resolution asked from the image model.'),
    ('webhook_keyframes', '', 'Make webhook that draws pending keyframes.')
on conflict (key) do nothing;

-- ----- functions that get a 012 layer on top ----------------------------
-- Seven existing functions keep their body under a second name and get a
-- thin layer with the old name. Nothing is dropped or renamed: the body
-- is copied. The block runs every time: whenever the function under the
-- old name is not that layer (first run, or an older migration was
-- applied again), its body is copied to the base again.
do $$
declare
    r record;
    v_def text;
begin
    for r in
        select x.*, p.oid
        from (values
            ('m417_internal', 'validate_shot_package', 'validate_shot_package_film'),
            ('m417_internal', 'validate_script', 'validate_script_film'),
            ('m417_internal', 'build_provider_request', 'build_provider_request_base'),
            ('m417_internal', 'video_scan', 'video_scan_base'),
            ('m417_internal', 'step_prompt', 'step_prompt_base'),
            ('m417_internal', 'resume_url', 'resume_url_base'),
            ('public', 'prepare_shot_attempt', 'prepare_shot_attempt_base')
        ) as x(nsp, fn, base)
        join pg_namespace n on n.nspname = x.nsp
        join pg_proc p on p.pronamespace = n.oid and p.proname = x.fn
        where p.prosrc not like '%M417-LAYER-012%'
    loop
        v_def := pg_get_functiondef(r.oid);
        if position('FUNCTION ' || r.nsp || '.' || r.fn || '(' in v_def) = 0 then
            raise exception 'M417_012_CANNOT_COPY: %.%', r.nsp, r.fn;
        end if;
        execute replace(v_def, 'FUNCTION ' || r.nsp || '.' || r.fn || '(',
                               'FUNCTION m417_internal.' || r.base || '(');
    end loop;
end $$;

-- ----- camera vocabulary ---------------------------------------------
create or replace function m417_internal.camera_angle(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select case btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z0-9]+', '_', 'g'), '_')
        when 'EYE_LEVEL' then 'EYE_LEVEL'
        when 'EYELEVEL' then 'EYE_LEVEL'
        when 'LOW_ANGLE' then 'LOW_ANGLE'
        when 'LOW' then 'LOW_ANGLE'
        when 'HIGH_ANGLE' then 'HIGH_ANGLE'
        when 'HIGH' then 'HIGH_ANGLE'
        when 'TOP_DOWN' then 'TOP_DOWN'
        when 'OVERHEAD' then 'TOP_DOWN'
        when 'BIRDS_EYE' then 'TOP_DOWN'
        when 'PROFILE' then 'PROFILE'
        when 'SIDE' then 'PROFILE'
        when 'SIDE_ON' then 'PROFILE'
        when 'SIDE_VIEW' then 'PROFILE'
        when 'THREE_QUARTER' then 'THREE_QUARTER'
        when 'THREE_QUARTERS' then 'THREE_QUARTER'
        when 'DRONE' then 'DRONE'
        when 'AERIAL' then 'DRONE'
        else null end;
$function$;

create or replace function m417_internal.camera_move(p_text text)
 returns text language sql immutable set search_path to ''
as $function$
    select case btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z0-9]+', '_', 'g'), '_')
        when 'STATIC' then 'STATIC'
        when 'LOCKED_OFF' then 'STATIC'
        when 'FIXED' then 'STATIC'
        when 'PUSH_IN' then 'PUSH_IN'
        when 'DOLLY_IN' then 'PUSH_IN'
        when 'PULL_BACK' then 'PULL_BACK'
        when 'PULL_OUT' then 'PULL_BACK'
        when 'DOLLY_OUT' then 'PULL_BACK'
        when 'TRACK' then 'TRACK'
        when 'TRACKING' then 'TRACK'
        when 'FOLLOW' then 'TRACK'
        when 'PAN' then 'PAN'
        when 'RISE' then 'RISE'
        when 'CRANE_UP' then 'RISE'
        when 'DRONE_DESCEND' then 'DRONE_DESCEND'
        when 'HANDHELD' then 'HANDHELD'
        else null end;
$function$;

-- What the picture model reads for an angle.
create or replace function m417_internal.camera_angle_sentence(p_angle text)
 returns text language sql immutable set search_path to ''
as $function$
    select case p_angle
        when 'EYE_LEVEL' then 'Camera at the children''s eye level.'
        when 'LOW_ANGLE' then 'Low-angle shot looking slightly up at the character.'
        when 'HIGH_ANGLE' then 'High-angle shot looking down at the scene.'
        when 'TOP_DOWN' then 'Top-down shot from directly above.'
        when 'PROFILE' then 'Side-on profile shot; the character is seen exactly from the side.'
        when 'THREE_QUARTER' then 'Three-quarter view of the characters.'
        when 'DRONE' then 'Aerial drone shot from high above the place.'
        else '' end;
$function$;

-- What the video model reads for a move.
create or replace function m417_internal.camera_move_sentence(p_move text)
 returns text language sql immutable set search_path to ''
as $function$
    select case p_move
        when 'STATIC' then 'Static camera, no camera movement.'
        when 'PUSH_IN' then 'Slow push-in toward the face; no other camera movement.'
        when 'PULL_BACK' then 'Slow pull-back that reveals more of the scene; no other camera movement.'
        when 'TRACK' then 'The camera tracks sideways, keeping pace with the character.'
        when 'PAN' then 'Slow pan from left to right.'
        when 'RISE' then 'The camera rises slowly upward.'
        when 'DRONE_DESCEND' then 'The drone descends slowly toward the children.'
        when 'HANDHELD' then 'Slight handheld shake; the framing stays the same.'
        else '' end;
$function$;

-- ----- the plan of a committed shot ------------------------------------
-- The shot as the Assistant Director planned it, read from the shot
-- package in force (shot SH03 is the third element).
create or replace function m417_internal.shot_plan(p_shot_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select a.content -> 'shots' -> (s.shot_order - 1)
    from public.shots s
    join public.production_jobs j on j.episode_id = s.episode_id
    join public.job_artifacts a
      on a.job_id = j.id and a.artifact_type = 'SHOT_PACKAGE' and a.is_current
    where s.id = p_shot_id
    order by a.version desc
    limit 1;
$function$;

create or replace function m417_internal.approved_keyframe(p_shot_id uuid)
 returns uuid language sql stable security definer set search_path to ''
as $function$
    select k.id from public.shot_keyframes k
    where k.shot_id = p_shot_id and k.status = 'APPROVED'
    limit 1;
$function$;

create or replace function m417_internal.keyframe_url(p_storage_path text)
 returns text language sql stable security definer set search_path to ''
as $function$
    select rtrim(m417_internal.txt('storage_base_url', ''), '/') || '/object/public/'
           || m417_internal.txt('keyframe_bucket', 'public-refs') || '/' || p_storage_path;
$function$;

-- Where the first frames of a job stand: shots still to be approved,
-- pictures waiting for the owner, pictures that can be drawn now, and
-- shots whose takes are used up.
create or replace function m417_internal.keyframe_counts(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'shots', count(*),
        'approved', count(*) filter (where x.approved),
        'review', count(*) filter (where not x.approved and x.status = 'GENERATED' and x.checked),
        'drawing', count(*) filter (where not x.approved
                                      and (x.status = 'PENDING' or (x.status = 'GENERATED' and not x.checked))),
        'drawable', count(*) filter (where not x.approved and x.status is distinct from 'GENERATED'
                                       and x.status is distinct from 'PENDING'
                                       and (x.take_no is null
                                            or x.take_no < m417_internal.num('max_keyframe_takes', 3)
                                            or coalesce(x.decided_by, '') = 'OWNER')),
        'exhausted', count(*) filter (where not x.approved and x.status in ('REJECTED', 'FAILED')
                                        and x.take_no >= m417_internal.num('max_keyframe_takes', 3)
                                        and coalesce(x.decided_by, '') <> 'OWNER'))
    from (
        select s.id,
               m417_internal.approved_keyframe(s.id) is not null as approved,
               k.status, k.take_no, k.decided_by, coalesce(k.checked, false) as checked
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        join public.production_manifests pm
          on pm.episode_id = j.episode_id and pm.production_version = e.production_version and pm.status = 'LOCKED'
        join public.production_manifest_shots pms on pms.manifest_id = pm.id
        join public.shots s on s.id = pms.shot_id
        left join lateral (
            select kk.status, kk.take_no, kk.decided_by, kk.check_result is not null as checked
            from public.shot_keyframes kk
            where kk.shot_id = s.id
            order by kk.take_no desc
            limit 1) k on true
        where j.id = p_job_id
          and s.state not in ('LOCKED', 'CANCELLED')
    ) x;
$function$;

-- What the owner is told on Telegram when the pictures of a job are
-- all drawn, or when a shot has used up its takes. Empty otherwise.
create or replace function m417_internal.keyframe_owner_text(p_job_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_c jsonb := m417_internal.keyframe_counts(p_job_id);
    v_title text;
    v_open integer;
    v_list text;
begin
    v_open := (v_c ->> 'drawable')::integer + (v_c ->> 'drawing')::integer;
    if v_open > 0 or ((v_c ->> 'review')::integer = 0 and (v_c ->> 'exhausted')::integer = 0) then
        return '';
    end if;
    select coalesce(nullif(btrim(e.title), ''), e.content_id) into v_title
    from public.production_jobs j join public.episodes e on e.id = j.episode_id
    where j.id = p_job_id;
    if (v_c ->> 'exhausted')::integer > 0 then
        select string_agg(
                   x.shot_code || ': ' || coalesce(nullif(x.note, ''), '-')
                   || case when x.storage_path is null then ''
                           else E'\n' || m417_internal.keyframe_url(x.storage_path) end,
                   E'\n' order by x.shot_order)
        into v_list
        from (
            select s.shot_code, s.shot_order, k.note, k.storage_path, k.status, k.take_no, k.decided_by
            from public.production_jobs j
            join public.shots s on s.episode_id = j.episode_id
            join lateral (
                select kk.* from public.shot_keyframes kk
                where kk.shot_id = s.id
                order by kk.take_no desc
                limit 1) k on true
            where j.id = p_job_id
              and s.state not in ('LOCKED', 'CANCELLED')
              and m417_internal.approved_keyframe(s.id) is null
        ) x
        where x.status in ('REJECTED', 'FAILED')
          and x.take_no >= m417_internal.num('max_keyframe_takes', 3)
          and coalesce(x.decided_by, '') <> 'OWNER';
        return format(
            E'🖼 %s: %s çekimden %s tanesinin karesi %s denemede otomatik kontrolden geçmedi. Son hâline sen bak:\n%s\n\nUygunsa Claude''a "SH.. onay", değilse "SH.. yeniden: neden" yaz.',
            v_title, v_c ->> 'shots', v_c ->> 'exhausted', m417_internal.num('max_keyframe_takes', 3)::integer,
            coalesce(v_list, '-'));
    end if;
    return format(
        E'🖼 %s: %s çekimin ilk kareleri hazır (yukarıdaki resimler). Hepsi uygunsa Claude''a "kareler onay" yaz; beğenmediğin kareyi numarasıyla ve nedeniyle söyle. Onay vermeden video üretilmez.',
        v_title, v_c ->> 'shots');
end;
$function$;

-- Calls a Make webhook from inside the database (pg_net sends it after
-- the transaction commits). Without pg_net or without an address
-- nothing happens; the watchdog then starts the work a little later.
create or replace function m417_internal.kick(p_url text, p_body jsonb)
 returns boolean language plpgsql security definer set search_path to ''
as $function$
begin
    if coalesce(btrim(p_url), '') = '' or to_regnamespace('net') is null then
        return false;
    end if;
    perform net.http_post(url := p_url, body := coalesce(p_body, '{}'::jsonb));
    return true;
exception when others then
    return false;
end;
$function$;

create or replace function m417_internal.kick_keyframes(p_job_id uuid, p_source text)
 returns boolean language sql security definer set search_path to ''
as $function$
    select m417_internal.kick(
        nullif(m417_internal.txt('webhook_keyframes', ''), '') || '?job_id=' || p_job_id,
        jsonb_build_object('job_id', p_job_id, 'source', p_source));
$function$;

-- Where a job is restarted. While first frames are being drawn that is
-- the keyframe scenario; while they wait for the owner there is nothing
-- to restart, so the watchdog leaves the job alone.
create or replace function m417_internal.resume_url(p_job_id uuid, p_step integer)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_c jsonb;
begin
    -- M417-LAYER-012
    if p_step = 22 and m417_internal.flag('keyframe_required', false) then
        v_c := m417_internal.keyframe_counts(p_job_id);
        if (v_c ->> 'approved')::integer < (v_c ->> 'shots')::integer then
            if (v_c ->> 'drawable')::integer + (v_c ->> 'drawing')::integer > 0 then
                return nullif(m417_internal.txt('webhook_keyframes', ''), '') || '?job_id=' || p_job_id;
            end if;
            return null;
        end if;
    end if;
    return m417_internal.resume_url_base(p_job_id, p_step);
end;
$function$;

-- ----- validation: the camera plan ------------------------------------
create or replace function m417_internal.validate_camera_plan(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_issues jsonb := '[]'::jsonb;
    v_shot jsonb;
    v_idx integer := 0;
    v_count integer;
    v_ref text;
    v_angle text;
    v_move text;
    v_size text;
    v_stage text;
    v_spoken boolean;
begin
    if not (m417_internal.film_on() and m417_internal.flag('camera_plan_enforced', false)) then
        return v_issues;
    end if;
    if jsonb_typeof(p_content -> 'shots') is distinct from 'array' then
        return v_issues;
    end if;
    v_count := jsonb_array_length(p_content -> 'shots');
    for v_shot in select * from jsonb_array_elements(p_content -> 'shots')
    loop
        v_idx := v_idx + 1;
        v_ref := 'shot ' || coalesce(v_shot ->> 'shot_no', v_idx::text);
        v_angle := m417_internal.camera_angle(v_shot ->> 'camera_angle');
        v_move := m417_internal.camera_move(v_shot ->> 'camera_move');
        v_size := m417_internal.film_size(v_shot ->> 'shot_size');
        v_stage := m417_internal.voice_stage(v_shot ->> 'voice_staging');
        v_spoken := jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array'
                    and jsonb_array_length(v_shot -> 'dialogue_line_nos') > 0;
        if v_angle is null then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'camera_angle is missing or unknown: ' || coalesce(v_shot ->> 'camera_angle', '(empty)'),
                'Set camera_angle to EYE_LEVEL, LOW_ANGLE, HIGH_ANGLE, TOP_DOWN, PROFILE, THREE_QUARTER or DRONE.');
        elsif v_angle = 'DRONE' then
            if v_idx <> 1 and v_idx <> v_count then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'A DRONE angle is used in the middle of the short.',
                    'Use DRONE only in the first shot (to show the place) or in the last one (to pull away from it).');
            end if;
            if v_size is not null and v_size not in ('WIDE', 'EXTREME_WIDE') then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'A DRONE angle is combined with shot_size ' || v_size || '.',
                    'A drone shot is WIDE or EXTREME_WIDE.');
            end if;
        end if;
        if v_move is null then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'camera_move is missing or unknown: ' || coalesce(v_shot ->> 'camera_move', '(empty)'),
                'Set camera_move to exactly one of STATIC, PUSH_IN, PULL_BACK, TRACK, PAN, RISE, DRONE_DESCEND or HANDHELD.');
        else
            if v_move = 'DRONE_DESCEND' and v_angle is distinct from 'DRONE' then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'camera_move DRONE_DESCEND needs camera_angle DRONE.',
                    'Use DRONE_DESCEND only with camera_angle DRONE, or choose another move.');
            end if;
            if v_spoken and v_stage = 'ON_CAMERA' and v_move not in ('STATIC', 'PUSH_IN') then
                v_issues := v_issues || m417_internal.issue(
                    'SHOTS', v_ref, 'A line is spoken ON_CAMERA while the camera does a ' || v_move || '.',
                    'Keep the camera STATIC or PUSH_IN in a shot where a character is seen talking.');
            end if;
        end if;
        if char_length(btrim(coalesce(v_shot ->> 'first_frame', ''))) < 80 then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'first_frame is missing or too thin to draw.',
                'In first_frame, describe in 80 to 500 characters the still picture of the first instant of the shot: who is where in the frame, each pose and expression, where each prop is. No movement, nothing that happens later.');
        end if;
    end loop;
    return v_issues;
end;
$function$;

-- The film rules keep their own function; the shot package is checked
-- against them and against the camera plan.

-- One event per shot. A video model that is asked for two events in a
-- few seconds performs one and drops the other, so a shot of a short
-- carries one event and the reaction to it.
create or replace function m417_internal.validate_one_event(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_issues jsonb := '[]'::jsonb;
    v_shot jsonb;
    v_idx integer := 0;
    v_n integer;
    v_max integer := m417_internal.num('max_beats_per_shot', 3)::integer;
begin
    if not (m417_internal.film_on() and m417_internal.flag('short_format_enforced', false)) or v_max <= 0 then
        return v_issues;
    end if;
    if jsonb_typeof(p_content -> 'shots') is distinct from 'array' then
        return v_issues;
    end if;
    for v_shot in select * from jsonb_array_elements(p_content -> 'shots')
    loop
        v_idx := v_idx + 1;
        continue when jsonb_typeof(v_shot -> 'beats') is distinct from 'array';
        v_n := jsonb_array_length(v_shot -> 'beats');
        if v_n > v_max then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', 'shot ' || coalesce(v_shot ->> 'shot_no', v_idx::text),
                format('The shot has %s beats; a shot of a short has at most %s.', v_n, v_max),
                format('Keep one event and the reaction to it, in at most %s beats, and rewrite action and video_prompt to match. The video model performs one event per shot and drops a second one: what does not fit is left out, not squeezed in.', v_max));
        end if;
    end loop;
    return v_issues;
end;
$function$;
create or replace function m417_internal.validate_shot_package(p_job_id uuid, p_content jsonb)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    -- M417-LAYER-012
    select m417_internal.validate_shot_package_film(p_job_id, p_content)
        || m417_internal.validate_camera_plan(p_job_id, p_content)
        || m417_internal.validate_one_event(p_job_id, p_content);
$function$;

-- ----- validation: the looping short ------------------------------------
create or replace function m417_internal.validate_short_script(p_job_id uuid, p_content jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_issues jsonb := '[]'::jsonb;
    v_scene jsonb;
    v_line jsonb;
    v_words integer;
    v_max integer := m417_internal.num('max_line_words', 6)::integer;
    v_moods text[];
    v_mood text := lower(btrim(coalesce(p_content ->> 'music_mood', '')));
begin
    if not (m417_internal.film_on() and m417_internal.flag('short_format_enforced', false)) then
        return v_issues;
    end if;
    if char_length(btrim(coalesce(p_content ->> 'loop', ''))) < 30 then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'loop', 'loop is missing or too short.',
            'In loop, say in at least 30 characters how the last image leads back to the first one, so the short can be watched again and again.');
    end if;
    select array_agg(distinct lower(btrim(mt.mood))) into v_moods
    from public.music_tracks mt
    where mt.is_active = true and mt.license_status = 'VERIFIED' and mt.role = 'MUSIC'
      and coalesce(btrim(mt.mood), '') <> '';
    if v_mood = '' then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'music_mood', 'music_mood is missing.',
            'Name the music mood of the short in music_mood' || case when v_moods is null then '.'
                else ': one of ' || array_to_string(v_moods, ', ') || '.' end);
    elsif v_moods is not null and not (v_mood = any (v_moods)) then
        v_issues := v_issues || m417_internal.issue(
            'SCRIPT', 'music_mood', 'music_mood "' || v_mood || '" is not in the music library.',
            'Use one of: ' || array_to_string(v_moods, ', ') || '.');
    end if;
    if jsonb_typeof(p_content -> 'scenes') = 'array' then
        for v_scene in select * from jsonb_array_elements(p_content -> 'scenes')
        loop
            continue when jsonb_typeof(v_scene -> 'dialogue') is distinct from 'array';
            for v_line in select * from jsonb_array_elements(v_scene -> 'dialogue')
            loop
                v_words := coalesce(array_length(
                    regexp_split_to_array(btrim(coalesce(v_line ->> 'text', '')), '\s+'), 1), 0);
                if btrim(coalesce(v_line ->> 'text', '')) <> '' and v_words > v_max then
                    v_issues := v_issues || m417_internal.issue(
                        'SCRIPT', 'scene ' || coalesce(v_scene ->> 'scene_no', '?') || ' line ' || coalesce(v_line ->> 'line_no', '?'),
                        format('This line has %s words; a line of a short has at most %s.', v_words, v_max),
                        format('Say it in at most %s words, or let the picture say it.', v_max));
                end if;
            end loop;
        end loop;
    end if;
    return v_issues;
end;
$function$;


create or replace function m417_internal.validate_script(p_job_id uuid, p_content jsonb)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    -- M417-LAYER-012
    select m417_internal.validate_script_film(p_job_id, p_content)
        || m417_internal.validate_short_script(p_job_id, p_content);
$function$;

-- ----- the prompt of a keyframe ----------------------------------------
-- What the picture model reads: framing and angle, the frozen first
-- instant, who the reference images are, then outfits, props and look in
-- the words of the script. When the text has to be cut, the end goes.
create or replace function m417_internal.keyframe_prompt(p_shot_id uuid, p_note text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_parts text[] := array[]::text[];
    v_plan jsonb := m417_internal.shot_plan(p_shot_id);
    v_job public.production_jobs;
    v_spec public.shot_specifications;
    v_script jsonb;
    v_refs jsonb;
    v_text text;
    v_notes text;
    v_char_ids uuid[];
    v_loc uuid;
begin
    select j.* into v_job
    from public.shots s join public.production_jobs j on j.episode_id = s.episode_id
    where s.id = p_shot_id;
    select ss.* into v_spec
    from public.shot_specifications ss
    where ss.shot_id = p_shot_id and ss.is_active = true;
    if v_job.id is null or v_spec.id is null or v_plan is null then
        raise exception 'KEYFRAME_SHOT_NOT_PLANNED';
    end if;
    v_script := m417_internal.artifact(v_job.id, 'SCRIPT');
    select coalesce(array_agg(c.id order by c.character_code), array[]::uuid[]) into v_char_ids
    from public.characters c
    where c.series_id = v_job.series_id and v_spec.character_codes ? c.character_code;
    v_loc := m417_internal.resolve_location(v_job.series_id, v_plan ->> 'location');
    v_refs := m417_internal.shot_reference_images(v_spec.id, 4);

    v_parts := v_parts || 'One still frame from a 3D animated family film, vertical 9:16 picture.'::text;
    v_parts := v_parts || m417_internal.film_size_sentence(m417_internal.film_size(v_plan ->> 'shot_size'));
    v_parts := v_parts || m417_internal.camera_angle_sentence(m417_internal.camera_angle(v_plan ->> 'camera_angle'));
    v_parts := v_parts || ('The picture shows the exact first instant of the shot, frozen: '
        || rtrim(left(btrim(coalesce(nullif(btrim(v_plan ->> 'first_frame'), ''),
                                     v_plan -> 'beats' -> 0 ->> 'what',
                                     v_plan ->> 'action', '')), 500), '. ') || '.');

    if jsonb_array_length(v_refs) > 0 then
        select string_agg(
                   'image ' || (r.value ->> 'n') || ' is '
                   || case when r.value ->> 'role' = 'LOCATION'
                           then 'the place ' || (r.value ->> 'name')
                           else r.value ->> 'name' end,
                   ', ' order by (r.value ->> 'n')::integer),
               string_agg(r.value ->> 'note', ' ' order by (r.value ->> 'n')::integer)
                   filter (where r.value ->> 'note' is not null)
        into v_text, v_notes
        from jsonb_array_elements(v_refs) r(value);
        v_parts := v_parts || ('Reference images, in the order given: ' || v_text
            || '. Keep every character''s face, hair, skin tone, age and body proportions exactly as in their reference image; the outfit follows the description below.'
            || case when v_notes is null then '' else ' ' || v_notes end);
    end if;

    select string_agg(c.name || ' wears ' || rtrim(left(btrim(w.value ->> 'outfit'), 170), '. '),
                      '. ' order by c.character_code)
    into v_text
    from jsonb_array_elements(
        case when jsonb_typeof(v_script -> 'wardrobe') = 'array' then v_script -> 'wardrobe' else '[]'::jsonb end) w(value)
    join public.characters c
      on c.id = m417_internal.resolve_character(v_job.series_id, w.value ->> 'character')
    where c.id = any (v_char_ids);
    if v_text is not null then
        v_parts := v_parts || ('Outfits: ' || v_text || '.');
    end if;

    select string_agg(rtrim(left(btrim(m417_internal.script_prop(v_script, n.value) ->> 'description'), 150), '. '),
                      '; ' order by n.ord)
    into v_text
    from jsonb_array_elements_text(
        case when jsonb_typeof(v_plan -> 'props') = 'array' then v_plan -> 'props' else '[]'::jsonb end
    ) with ordinality as n(value, ord)
    where m417_internal.script_prop(v_script, n.value) is not null;
    if v_text is not null then
        v_parts := v_parts || ('Props, exactly as described and no extra copies: ' || v_text || '.');
    end if;

    if coalesce(btrim(v_script ->> 'look'), '') <> '' then
        v_parts := v_parts || ('Look: ' || rtrim(left(btrim(v_script ->> 'look'), 160), '. ') || '.');
    end if;
    if cardinality(v_char_ids) >= 2 and m417_internal.txt('cast_rule_text', '') <> '' then
        v_parts := v_parts || m417_internal.txt('cast_rule_text', '');
    end if;
    v_parts := v_parts || 'Exactly one of each named character and nobody else in the picture. Sharp and clean, no motion blur. No text, letters, numbers, subtitles, logos or watermarks anywhere.'::text;

    if coalesce(btrim(p_note), '') <> '' then
        v_parts := v_parts || ('Correction: an earlier picture of this shot was rejected because: '
            || rtrim(left(regexp_replace(btrim(p_note), '[[:space:]]+', ' ', 'g'), 300), '. ')
            || '. Do not repeat this.');
    end if;

    select left(coalesce(sb.visual_style, ''), 220) into v_text
    from public.style_bibles sb
    where sb.series_id = v_job.series_id and sb.status <> 'ARCHIVED'
    order by sb.version desc
    limit 1;
    if coalesce(v_text, '') <> '' then
        v_parts := v_parts || ('Style. ' || v_text);
    end if;
    select l.name || ': ' || left(coalesce(l.canonical_description, ''), 180) into v_text
    from public.locations l where l.id = v_loc;
    if v_text is not null then
        v_parts := v_parts || ('Place. ' || v_text);
    end if;
    return left(regexp_replace(array_to_string(v_parts, ' '), '[[:space:]]+', ' ', 'g'), 2600);
end;
$function$;

-- ----- the video request with a start frame ------------------------------
-- With an approved keyframe the video model no longer has to be told
-- what everything looks like: the picture is the start frame, and the
-- words say only what moves. Without one the request is the old one.

create or replace function m417_internal.build_provider_request(p_attempt_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_base jsonb := m417_internal.build_provider_request_base(p_attempt_id)::jsonb;
    v_shot_id uuid;
    v_spec public.shot_specifications;
    v_key public.shot_keyframes;
    v_plan jsonb;
    v_meta jsonb;
    v_max integer;
    v_refs jsonb;
    v_names text;
    v_notes text;
    v_beats text;
    v_speaker text;
    v_fix text;
    v_window numeric;
    v_prompt text;
    v_tail text;
    v_images jsonb;
begin
    -- M417-LAYER-012
    if v_base ->> 'task_type' is distinct from 'omni_video_generation' then
        return v_base::text;
    end if;
    select a.shot_id, gm.capability_metadata into v_shot_id, v_meta
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    join public.generation_models gm on gm.id = grd.selected_model_id
    where a.id = p_attempt_id;
    select k.* into v_key
    from public.shot_keyframes k
    where k.shot_id = v_shot_id and k.status = 'APPROVED';
    if not found then
        return v_base::text;
    end if;
    select ss.* into v_spec
    from public.attempts a
    join public.generation_routing_decisions grd on grd.id = a.routing_decision_id
    join public.shot_specifications ss on ss.id = grd.shot_specification_id
    where a.id = p_attempt_id;
    v_plan := coalesce(m417_internal.shot_plan(v_shot_id), '{}'::jsonb);

    -- The start frame is image 1; the characters follow.
    v_max := greatest(coalesce(nullif(v_meta ->> 'max_reference_images', '')::integer, 4) - 1, 0);
    select coalesce(jsonb_agg(jsonb_build_object(
               'n', x.ord + 1, 'name', x.value ->> 'name', 'url', x.value ->> 'url', 'note', x.value ->> 'note')
               order by x.ord), '[]'::jsonb)
    into v_refs
    from (
        select r.value, row_number() over (order by (r.value ->> 'n')::integer) as ord
        from jsonb_array_elements(m417_internal.shot_reference_images(v_spec.id, 8)) r(value)
        where r.value ->> 'role' = 'CHARACTER'
    ) x
    where x.ord <= v_max;
    select string_agg('@image_' || (r.value ->> 'n') || ' is ' || (r.value ->> 'name'), ', '
                      order by (r.value ->> 'n')::integer),
           string_agg(r.value ->> 'note', ' ' order by (r.value ->> 'n')::integer)
               filter (where r.value ->> 'note' is not null)
    into v_names, v_notes
    from jsonb_array_elements(v_refs) r(value);

    select string_agg(
               'at ' || to_char(coalesce(m417_internal.safe_numeric(b.value ->> 'at'), 0), 'FM990.0') || ' s '
               || rtrim(left(btrim(coalesce(b.value ->> 'what', '')), 160), '. '),
               '; ' order by b.ord)
    into v_beats
    from jsonb_array_elements(
        case when jsonb_typeof(v_spec.beats) = 'array' then v_spec.beats else '[]'::jsonb end
    ) with ordinality as b(value, ord);
    v_window := ceil((coalesce(v_spec.edit_seconds, v_spec.duration_seconds)
                      + m417_internal.num('edit_trim_lead_seconds', 0.2)) * 2) / 2;

    select c.name into v_speaker
    from public.shot_audio_productions sap
    join public.characters c on c.id = sap.character_id
    where sap.shot_specification_id = v_spec.id
    order by sap.audio_order
    limit 1;

    select ' Correction: an earlier take of this shot was rejected because: '
           || rtrim(left(regexp_replace(btrim(go.qc_notes), '[[:space:]]+', ' ', 'g'), 260), '. ')
           || '. Do not repeat this.'
    into v_fix
    from public.generation_outputs go
    where go.shot_id = v_shot_id
      and go.qc_status = 'FAIL'
      and coalesce(btrim(go.qc_notes), '') <> ''
    order by go.created_at desc
    limit 1;

    v_tail := case when coalesce(btrim(v_spec.negative_prompt), '') <> ''
                   then ' Avoid: ' || left(btrim(v_spec.negative_prompt), 300) else '' end;
    v_prompt :=
        'Use @image_1 as the start frame: the video begins exactly with this picture. '
        || 'Keep its framing, where everyone stands, the outfits, the props, the place and the light; no new person and no new object appears.'
        || case when v_names is null then '' else
               ' ' || v_names || ': their faces, hair and body proportions stay exactly as in these reference images.'
               || case when v_notes is null then '' else ' ' || v_notes end end
        || ' ' || coalesce(nullif(m417_internal.camera_move_sentence(m417_internal.camera_move(v_plan ->> 'camera_move')), ''),
                           'Static camera, no camera movement.')
        || ' What happens: ' || rtrim(left(btrim(coalesce(v_spec.narrative_action, '')), 400), '. ') || '.'
        || case when v_beats is null then '' else
               format(' Timing: %s. The action starts immediately and all of it happens within the first %s seconds; after that everyone holds the final pose.',
                      v_beats, to_char(v_window, 'FM990.0')) end
        || ' ' || case
               when v_speaker is null then
                   'Nobody speaks in this shot: no talking mouth movements. Feelings show in the eyes, eyebrows and body, in a smile, a gasp or a laugh.'
               when v_spec.voice_staging = 'ON_CAMERA' then
                   v_speaker || ' is talking from the first moment of the shot, mouth moving naturally, with matching gestures. Nobody else talks.'
               when v_spec.voice_staging = 'BACK_TO_CAMERA' then
                   v_speaker || ' is talking but is seen only from behind. Nobody else talks.'
               else
                   'A voice is heard from off-screen. Nobody visible talks: their mouths stay closed while they listen and react.'
               end
        || case when coalesce(btrim(v_spec.emotion), '') = '' then '' else ' Acting: ' || left(btrim(v_spec.emotion), 180) || '.' end
        || ' One continuous shot, never a cut, a collage or a split screen. No on-screen text.'
        || coalesce(v_fix, '');
    v_prompt := left(regexp_replace(v_prompt, '[[:space:]]+', ' ', 'g'), 2500 - length(v_tail)) || v_tail;

    v_images := jsonb_build_array(m417_internal.keyframe_url(v_key.storage_path))
        || coalesce((select jsonb_agg(r.value ->> 'url' order by (r.value ->> 'n')::integer)
                     from jsonb_array_elements(v_refs) r(value)), '[]'::jsonb);
    return jsonb_set(
        v_base, '{input}',
        (v_base -> 'input') || jsonb_build_object('prompt', v_prompt, 'images', v_images))::text;
end;
$function$;

-- ----- the gate ---------------------------------------------------------
-- Hard stop, whatever calls it: no attempt row for a shot without an
-- approved keyframe while keyframes are required.
create or replace function public.require_keyframe_for_attempt()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
    if m417_internal.flag('keyframe_required', false)
       and m417_internal.approved_keyframe(new.shot_id) is null
    then
        raise exception 'KEYFRAME_APPROVAL_REQUIRED: the owner has not approved a first frame for this shot';
    end if;
    return new;
end;
$function$;

create or replace trigger trg_require_keyframe_for_attempt
    before insert on public.attempts
    for each row execute function public.require_keyframe_for_attempt();


create or replace function public.prepare_shot_attempt(p_shot_id uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
begin
    -- M417-LAYER-012
    if m417_internal.flag('keyframe_required', false)
       and m417_internal.approved_keyframe(p_shot_id) is null
    then
        return jsonb_build_object('decision', 'WAITING_FOR_KEYFRAME');
    end if;
    return m417_internal.prepare_shot_attempt_base(p_shot_id);
end;
$function$;

-- The driver's list, with three changes: a shot without an approved
-- first frame is not offered for generation; no more generations are
-- started than may run side by side; and the reviewer of a clip that
-- began from an approved picture is told what is no longer his to judge.
create or replace function m417_internal.video_scan(p_mutate boolean)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_scan jsonb := m417_internal.video_scan_base(p_mutate);
    v_items jsonb := '[]'::jsonb;
    v_item jsonb;
    v_waiting integer := coalesce((v_scan ->> 'waiting')::integer, 0);
    v_need boolean := m417_internal.flag('keyframe_required', false);
    v_limit integer := m417_internal.num('max_parallel_video_attempts', 3)::integer;
    v_flying integer;
    v_held integer := 0;
    v_no_frame integer := 0;
    v_idle integer := 0;
    v_ctx jsonb;
begin
    -- M417-LAYER-012
    -- Shots that wait behind a pilot shot which itself waits for its
    -- first frame are not work for the driver: nothing moves until the
    -- owner has decided.
    if v_need and m417_internal.flag('generation_enabled', false) then
        select coalesce(sum((
                   select count(*)
                   from public.production_manifest_shots pms
                   join public.shots s2 on s2.id = pms.shot_id
                   where pms.manifest_id = pm.id
                     and s2.id <> pm.pilot_shot_id
                     and s2.state in ('STORYBOARD_APPROVED', 'AUDIO_READY', 'RETRY_REQUIRED'))), 0)
        into v_idle
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        join public.production_manifests pm
          on pm.episode_id = j.episode_id and pm.production_version = e.production_version and pm.status = 'LOCKED'
        join public.shots ps on ps.id = pm.pilot_shot_id
        where j.current_step = 22 and j.state = 'READY'
          and ps.state in ('STORYBOARD_APPROVED', 'AUDIO_READY')
          and not exists (select 1 from public.attempts a where a.shot_id = ps.id)
          and m417_internal.approved_keyframe(ps.id) is null;
    end if;
    select count(*) into v_flying
    from public.attempts a
    where a.status in ('BUDGET_RESERVED', 'SUBMITTED', 'GENERATING');
    for v_item in select * from jsonb_array_elements(v_scan -> 'items')
    loop
        if v_item ->> 'action' = 'ACQUIRE' then
            if v_need and m417_internal.approved_keyframe((v_item ->> 'shot_id')::uuid) is null then
                v_no_frame := v_no_frame + 1;
                continue;
            end if;
            if v_limit > 0 and v_flying >= v_limit then
                v_held := v_held + 1;
                continue;
            end if;
            v_flying := v_flying + 1;
        elsif v_item ->> 'action' = 'PROCESS_OUTPUT'
              and m417_internal.approved_keyframe((v_item ->> 'shot_id')::uuid) is not null
        then
            begin
                v_ctx := (v_item ->> 'qc_context_text')::jsonb;
                v_item := v_item || jsonb_build_object('qc_context_text', (v_ctx || jsonb_build_object(
                    'approved_start_frame',
                    'This clip starts from a still picture the owner approved. The framing, the outfits, the heights of the characters, the props and the place come from that picture and are not defects. Judge what happens after the first frame. FAIL only for something a viewer would notice: the main event of the shot does not happen at all, a face or a body changes or deforms, a limb too many or too few, a person or an object appears from nowhere, garbled text, a clip that does not move. It is not a defect when another character than planned performs the action, when a secondary action is left out or added, or when the timing differs: write it in notes, set prompt_adherence to PASS and pass the clip. The owner watches the finished film.'))::text);
            exception when others then
                null;
            end;
        end if;
        v_items := v_items || v_item;
    end loop;
    return jsonb_build_object(
        'items', v_items,
        'waiting', greatest(v_waiting - v_idle, 0) + v_held,
        'held_for_parallel_limit', v_held,
        'waiting_for_keyframe', v_no_frame);
end;
$function$;

-- ----- instructions: what the short format adds --------------------------
create or replace function m417_internal.step_prompt(
    p_job_id uuid, p_step integer, p_request text, p_feedback text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_body text := m417_internal.step_prompt_base(p_job_id, p_step, p_request, p_feedback);
    v_recent text;
    v_moods text;
begin
    -- M417-LAYER-012
    if v_body is null or position('[[' in v_body) = 0 then
        return v_body;
    end if;
    select coalesce(jsonb_agg(x.item order by x.created_at desc), '[]'::jsonb)::text into v_recent
    from (
        select jsonb_build_object(
                   'title', a.content ->> 'title',
                   'pattern', a.content ->> 'pattern',
                   'characters', a.content -> 'characters',
                   'location', a.content ->> 'location') as item,
               j.created_at
        from public.production_jobs j
        join public.job_artifacts a
          on a.job_id = j.id and a.artifact_type = 'TOPIC_SELECTION' and a.is_current
        where j.id <> p_job_id and j.current_step >= 16 and j.state <> 'CANCELLED'
        order by j.created_at desc
        limit 8
    ) x;
    select string_agg(distinct lower(btrim(mt.mood)), ', ') into v_moods
    from public.music_tracks mt
    where mt.is_active = true and mt.license_status = 'VERIFIED' and mt.role = 'MUSIC'
      and coalesce(btrim(mt.mood), '') <> '';
    v_body := replace(v_body, '[[RECENT]]', coalesce(v_recent, '[]'));
    v_body := replace(v_body, '[[MUSIC_MOODS]]',
                      coalesce(v_moods, 'playful, sneaky, chase, triumphant, warm, mystery, dance'));
    v_body := replace(v_body, '[[LINE_WORDS]]', m417_internal.num('max_line_words', 6)::integer::text);
    v_body := replace(v_body, '[[BEATS_MAX]]', m417_internal.num('max_beats_per_shot', 3)::integer::text);
    return v_body;
end;
$function$;

-- ----- keyframes: what Make calls ----------------------------------------
-- The pictures to draw now. A shot gets a new take when it has none, or
-- when its last one was rejected or failed and takes are left.
create or replace function public.next_keyframe_work(p_job_id uuid default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_items jsonb := '[]'::jsonb;
    v_job record;
    v_shot record;
    v_last public.shot_keyframes;
    v_has boolean;
    v_take public.shot_keyframes;
    v_max integer := m417_internal.num('max_keyframe_takes', 3)::integer;
    v_stale interval := make_interval(secs => m417_internal.num('keyframe_handout_seconds', 300));
    v_waiting integer := 0;
    v_review integer := 0;
    v_approved integer := 0;
    v_exhausted integer := 0;
    v_total integer := 0;
    v_refs jsonb;
    v_prompt text;
begin
    if not (m417_internal.flag('pipeline_enabled', false) and m417_internal.flag('keyframe_required', false)) then
        return jsonb_build_object('items', v_items, 'count', 0, 'reason', 'KEYFRAMES_OFF');
    end if;
    if m417_internal.txt('storage_base_url', '') = '' then
        raise exception 'STORAGE_BASE_URL_NOT_SET';
    end if;
    for v_job in
        select j.id, j.episode_id, e.content_id, e.production_version, s.series_code
        from public.production_jobs j
        join public.episodes e on e.id = j.episode_id
        join public.series s on s.id = j.series_id
        where j.current_step = 22 and j.state = 'READY'
          and (p_job_id is null or j.id = p_job_id)
        order by j.created_at
        for update of j
    loop
        for v_shot in
            select s.id, s.shot_code, ss.id as spec_id
            from public.production_manifests pm
            join public.production_manifest_shots pms on pms.manifest_id = pm.id
            join public.shots s on s.id = pms.shot_id
            join public.shot_specifications ss on ss.id = pms.shot_specification_id
            where pm.episode_id = v_job.episode_id
              and pm.production_version = v_job.production_version
              and pm.status = 'LOCKED'
              and s.state not in ('LOCKED', 'CANCELLED')
            order by pms.manifest_order
        loop
            v_total := v_total + 1;
            select k.* into v_last
            from public.shot_keyframes k
            where k.shot_id = v_shot.id
            order by k.take_no desc
            limit 1;
            v_has := found;
            if exists (select 1 from public.shot_keyframes k where k.shot_id = v_shot.id and k.status = 'APPROVED') then
                v_approved := v_approved + 1;
                continue;
            end if;
            if v_has and v_last.status = 'GENERATED' then
                if v_last.check_result is not null
                   or coalesce(v_last.handed_out_at, v_last.created_at) > now() - v_stale then
                    v_review := v_review + 1;
                    continue;
                end if;
                -- Drawn, but the check never came back: the take is closed and drawn again.
                update public.shot_keyframes
                set status = 'FAILED', note = 'The automatic check never arrived.', decided_by = 'SYSTEM', decided_at = now()
                where id = v_last.id
                returning * into v_last;
            end if;
            if v_has and v_last.status = 'PENDING' then
                if v_last.handed_out_at is not null and v_last.handed_out_at > now() - v_stale then
                    v_waiting := v_waiting + 1;
                    continue;
                end if;
                update public.shot_keyframes set handed_out_at = now() where id = v_last.id
                returning * into v_take;
            else
                if v_has and v_last.take_no >= v_max and coalesce(v_last.decided_by, '') <> 'OWNER' then
                    v_exhausted := v_exhausted + 1;
                    continue;
                end if;
                v_refs := m417_internal.shot_reference_images(v_shot.spec_id, 4);
                v_prompt := m417_internal.keyframe_prompt(
                    v_shot.id, case when v_has and v_last.status = 'REJECTED' then v_last.note end);
                insert into public.shot_keyframes (job_id, shot_id, take_no, status, prompt, reference_images, handed_out_at)
                values (v_job.id, v_shot.id, coalesce(v_last.take_no, 0) + 1, 'PENDING', v_prompt, v_refs, now())
                returning * into v_take;
            end if;
            v_items := v_items || jsonb_build_object(
                'keyframe_id', v_take.id,
                'job_id', v_job.id,
                'shot_id', v_shot.id,
                'shot_code', v_shot.shot_code,
                'take_no', v_take.take_no,
                'model', m417_internal.txt('keyframe_model', 'gemini-3.1-flash-image'),
                'aspect_ratio', '9:16',
                'image_size', m417_internal.txt('keyframe_image_size', '1K'),
                'prompt', v_take.prompt,
                'images', coalesce((
                    select jsonb_agg(jsonb_build_object(
                               'upload_format', 'url', 'uri', r.value ->> 'url',
                               'mimeType', case when lower(r.value ->> 'url') ~ '\.jpe?g$' then 'image/jpeg'
                                                when lower(r.value ->> 'url') ~ '\.webp$' then 'image/webp'
                                                else 'image/png' end)
                               order by (r.value ->> 'n')::integer)
                    from jsonb_array_elements(v_take.reference_images) r(value)), '[]'::jsonb),
                'bucket', m417_internal.txt('keyframe_bucket', 'public-refs'),
                'storage_path', format('keyframes/%s/%s/%s_K%s_%s.jpg',
                    v_job.series_code, v_job.content_id, v_shot.shot_code, v_take.take_no,
                    m417_internal.rand_suffix()),
                'storage_base_url', m417_internal.txt('storage_base_url', ''),
                'notify_chat_id', m417_internal.txt('notify_chat_id', ''),
                'caption', format('%s / %s - kare %s', v_job.content_id, v_shot.shot_code, v_take.take_no));
        end loop;
    end loop;
    return jsonb_build_object(
        'items', v_items,
        'count', jsonb_array_length(v_items),
        'waiting', v_waiting,
        'awaiting_review', v_review,
        'approved', v_approved,
        'exhausted', v_exhausted,
        'shots', v_total);
end;
$function$;

-- The picture is in storage. Hands back what the checker needs to look at it.
create or replace function public.register_keyframe(p_keyframe_id uuid, p_storage_path text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_key public.shot_keyframes;
    v_size bigint;
    v_names text;
    v_looks text;
begin
    select k.* into v_key from public.shot_keyframes k where k.id = p_keyframe_id for update;
    if not found then
        raise exception 'KEYFRAME_NOT_FOUND';
    end if;
    if v_key.status not in ('PENDING', 'GENERATED') then
        return jsonb_build_object('keyframe_id', v_key.id, 'status', v_key.status, 'registered', false);
    end if;
    select (o.metadata ->> 'size')::bigint into v_size
    from storage.objects o
    where o.bucket_id = m417_internal.txt('keyframe_bucket', 'public-refs')
      and o.name = btrim(p_storage_path)
    limit 1;
    if v_size is null or v_size < m417_internal.num('min_keyframe_bytes', 5000) then
        raise exception 'KEYFRAME_FILE_NOT_FOUND_IN_STORAGE: %', p_storage_path;
    end if;
    update public.shot_keyframes
    set status = 'GENERATED', storage_path = btrim(p_storage_path)
    where id = v_key.id;
    select string_agg(r.value ->> 'name', ', ' order by (r.value ->> 'n')::integer) into v_names
    from jsonb_array_elements(v_key.reference_images) r(value)
    where r.value ->> 'role' = 'CHARACTER';
    select string_agg(c.name || ': ' || left(coalesce(c.canonical_description, ''), 260), ' | ' order by c.character_code)
    into v_looks
    from public.production_jobs j
    join public.characters c on c.series_id = j.series_id
    where j.id = v_key.job_id
      and exists (select 1 from jsonb_array_elements(v_key.reference_images) r(value)
                  where r.value ->> 'role' = 'CHARACTER' and r.value ->> 'name' = c.name);
    return jsonb_build_object(
        'keyframe_id', v_key.id,
        'status', 'GENERATED',
        'registered', true,
        'image_url', m417_internal.keyframe_url(btrim(p_storage_path)),
        'check_text',
            'You check one still picture that will become the first frame of an animated shot for children. '
            || 'It was drawn from this description: ' || v_key.prompt
            || ' The characters that must be in it: ' || coalesce(v_names, 'none') || '.'
            || case when v_looks is null then '' else ' How they look: ' || v_looks || '.' end
            || ' Look only for what a viewer would notice: a named character missing or drawn twice; an extra person; '
            || 'a character whose hair, skin tone or age clearly does not fit the description; children of clearly different heights; '
            || 'an outfit that is clearly not the one described; a main prop missing or duplicated; deformed hands, faces or limbs; '
            || 'any text, letters or watermark; anything unsuitable for children. '
            || 'Small differences of shade, pose, background or framing are fine: the owner looks at every picture himself. '
            || 'Return one raw JSON object: {"verdict": "PASS or FAIL", "score": 0-100, "notes": "one sentence saying exactly what is wrong, empty when nothing is", "findings": [""]}');
end;
$function$;

create or replace function public.apply_keyframe_check(p_keyframe_id uuid, p_result jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_key public.shot_keyframes;
    v_score numeric := m417_internal.score100(m417_internal.safe_numeric(p_result ->> 'score'));
    v_verdict text := upper(btrim(coalesce(p_result ->> 'verdict', '')));
    v_fail boolean;
begin
    select k.* into v_key from public.shot_keyframes k where k.id = p_keyframe_id for update;
    if not found then
        raise exception 'KEYFRAME_NOT_FOUND';
    end if;
    if v_key.status <> 'GENERATED' then
        return jsonb_build_object('keyframe_id', v_key.id, 'status', v_key.status, 'applied', false);
    end if;
    v_fail := v_verdict = 'FAIL'
              or (v_score is not null and v_score < m417_internal.num('keyframe_min_score', 70));
    update public.shot_keyframes
    set check_score = v_score,
        check_result = p_result,
        status = case when v_fail then 'REJECTED' else 'GENERATED' end,
        note = case when v_fail then left(coalesce(nullif(btrim(p_result ->> 'notes'), ''), 'The automatic check failed the picture.'), 400) end,
        decided_by = case when v_fail then 'AUTO_CHECK' end,
        decided_at = case when v_fail then now() end
    where id = v_key.id;
    -- A failed picture is drawn again without waiting for anybody.
    if v_fail then
        perform m417_internal.kick_keyframes(v_key.job_id, 'check_failed');
    end if;
    return jsonb_build_object(
        'keyframe_id', v_key.id,
        'status', case when v_fail then 'REJECTED' else 'GENERATED' end,
        'applied', true,
        'score', v_score,
        'show_owner', not v_fail,
        'owner_text', m417_internal.keyframe_owner_text(v_key.job_id));
end;
$function$;

-- The picture model refused or failed; the take is closed and the next
-- call of next_keyframe_work opens another one while takes are left.
create or replace function public.fail_keyframe(p_keyframe_id uuid, p_reason text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_key public.shot_keyframes;
begin
    select k.* into v_key from public.shot_keyframes k where k.id = p_keyframe_id for update;
    if not found then
        raise exception 'KEYFRAME_NOT_FOUND';
    end if;
    if v_key.status <> 'PENDING' then
        return jsonb_build_object('keyframe_id', v_key.id, 'status', v_key.status, 'applied', false);
    end if;
    update public.shot_keyframes
    set status = 'FAILED', note = left(coalesce(p_reason, ''), 400), decided_by = 'PROVIDER', decided_at = now()
    where id = v_key.id;
    perform m417_internal.kick_keyframes(v_key.job_id, 'provider_failed');
    return jsonb_build_object('keyframe_id', v_key.id, 'status', 'FAILED', 'applied', true,
                              'owner_text', m417_internal.keyframe_owner_text(v_key.job_id));
end;
$function$;

-- ----- keyframes: what the owner sees and decides -------------------------
create or replace function public.keyframe_overview(p_job_id uuid)
 returns jsonb language sql stable security definer set search_path to ''
as $function$
    select jsonb_build_object(
        'job_id', p_job_id,
        'keyframe_required', m417_internal.flag('keyframe_required', false),
        'shots', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'shot_code', s.shot_code,
                       'shot_state', s.state,
                       'takes', (select count(*) from public.shot_keyframes k where k.shot_id = s.id),
                       'status', k.status,
                       'take_no', k.take_no,
                       'check_score', k.check_score,
                       'note', k.note,
                       'image_url', case when k.storage_path is not null then m417_internal.keyframe_url(k.storage_path) end,
                       'first_frame', m417_internal.shot_plan(s.id) ->> 'first_frame')
                   order by s.shot_order)
            from public.production_jobs j
            join public.shots s on s.episode_id = j.episode_id
            left join lateral (
                select kk.* from public.shot_keyframes kk
                where kk.shot_id = s.id
                order by (kk.status = 'APPROVED') desc, kk.take_no desc
                limit 1) k on true
            where j.id = p_job_id), '[]'::jsonb));
$function$;

-- The owner's decision. APPROVE takes the newest picture of every shot
-- (or of the shots named); REJECT sends the named shots back with the
-- reason, and a new picture is drawn. For a shot named by its code the
-- owner's word also reaches a picture the automatic check turned down:
-- he may take it anyway, or send it back with his own reason.
create or replace function public.decide_keyframes(
    p_job_id uuid, p_decision text, p_actor text,
    p_shot_codes jsonb default null, p_note text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_decision text := upper(btrim(coalesce(p_decision, '')));
    v_job public.production_jobs;
    v_row record;
    v_done integer := 0;
    v_open integer;
    v_codes text[];
begin
    if v_decision not in ('APPROVE', 'REJECT') then
        raise exception 'KEYFRAME_DECISION_INVALID: %', p_decision;
    end if;
    if coalesce(btrim(p_actor), '') = '' then
        raise exception 'KEYFRAME_DECISION_NEEDS_AN_ACTOR';
    end if;
    if p_shot_codes is not null and jsonb_typeof(p_shot_codes) = 'array' then
        select array_agg(upper(btrim(x))) into v_codes from jsonb_array_elements_text(p_shot_codes) x;
    end if;
    if v_decision = 'REJECT' and (v_codes is null or coalesce(btrim(p_note), '') = '') then
        raise exception 'KEYFRAME_REJECT_NEEDS_SHOTS_AND_A_REASON';
    end if;
    v_job := m417_internal.lock_job(p_job_id);

    for v_row in
        select k.id, s.shot_code, s.id as shot_id
        from public.shots s
        join lateral (
            select kk.* from public.shot_keyframes kk
            where kk.shot_id = s.id
            order by kk.take_no desc
            limit 1) k on true
        where s.episode_id = v_job.episode_id
          and (v_codes is null or s.shot_code = any (v_codes))
          and (k.status = 'GENERATED'
               or (v_codes is not null and k.status in ('REJECTED', 'FAILED')
                   and coalesce(k.decided_by, '') <> 'OWNER'
                   and (v_decision = 'REJECT' or k.storage_path is not null)))
        order by s.shot_order
    loop
        if v_decision = 'APPROVE' then
            update public.shot_keyframes
            set status = 'APPROVED', decided_by = 'OWNER', decided_at = now(),
                note = nullif(btrim(coalesce(p_note, '')), '')
            where id = v_row.id;
        else
            update public.shot_keyframes
            set status = 'REJECTED', decided_by = 'OWNER', decided_at = now(), note = left(btrim(p_note), 400)
            where id = v_row.id;
        end if;
        v_done := v_done + 1;
    end loop;

    select count(*) into v_open
    from public.shots s
    where s.episode_id = v_job.episode_id
      and s.state not in ('LOCKED', 'CANCELLED')
      and m417_internal.approved_keyframe(s.id) is null;
    perform m417_internal.event(
        case when v_decision = 'APPROVE' then 'KEYFRAMES_APPROVED' else 'KEYFRAMES_REJECTED' end,
        'INFO',
        format('%s: %s keyframe(s) by %s.', v_decision, v_done, btrim(p_actor)),
        jsonb_build_object('job_id', p_job_id, 'shots', to_jsonb(v_codes), 'note', p_note,
                           'actor', btrim(p_actor), 'still_open', v_open),
        v_job.episode_id);
    update public.production_jobs
    set last_activity_at = now(), watchdog_resumes = 0, watchdog_step = null
    where id = p_job_id;
    -- Rejected pictures are drawn again; with every frame approved the
    -- video driver starts.
    if v_decision = 'REJECT' and v_done > 0 then
        perform m417_internal.kick_keyframes(p_job_id, 'owner_rejected');
    elsif v_decision = 'APPROVE' and v_open = 0 and v_job.current_step = 22 and v_job.state = 'READY' then
        perform m417_internal.kick(m417_internal.resume_url_base(p_job_id, 22),
                                   jsonb_build_object('job_id', p_job_id, 'source', 'keyframes_approved'));
    end if;
    return jsonb_build_object(
        'job_id', p_job_id, 'decision', v_decision, 'changed', v_done,
        'shots_without_approved_frame', v_open,
        'ready_for_video', v_open = 0);
end;
$function$;

-- A job that reaches the video stage has its first frames drawn at once.
create or replace function public.keyframes_on_video_stage()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
    if m417_internal.flag('keyframe_required', false) and m417_internal.flag('pipeline_enabled', false) then
        perform m417_internal.kick_keyframes(new.id, 'video_stage_reached');
    end if;
    return new;
end;
$function$;

create or replace trigger trg_keyframes_on_video_stage
    after update of current_step on public.production_jobs
    for each row
    when (new.current_step = 22 and old.current_step is distinct from 22 and new.state = 'READY')
    execute function public.keyframes_on_video_stage();

-- ----- the instructions for the looping short ----------------------------
-- New versions are written as changes to version 1, so the two cannot
-- drift apart unnoticed: a sentence that is no longer found stops the
-- migration instead of being skipped.
create or replace function m417_internal.swap_text(p_body text, p_old text, p_new text)
 returns text language plpgsql immutable set search_path to ''
as $function$
begin
    if position(p_old in p_body) = 0 then
        raise exception 'M417_012_PROMPT_SENTENCE_NOT_FOUND: %', left(p_old, 80);
    end if;
    return replace(p_body, p_old, p_new);
end;
$function$;

do $$
declare
    v text;
    v_converge constant text := $a$Converge. Every revision round costs time, and the package has to be good enough to film well, not perfect. Ask for REVISE_SHOTS only for a defect a viewer would notice in the finished film, or one that would make the video model show the wrong thing. A wording improvement is not a reason to revise: put it in director_notes and APPROVE. If the package was already revised at your request and those changes were made, APPROVE unless a new and serious defect has appeared.

$a$;
begin
    -- TOPIC 2 ----------------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'TOPIC' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: TOPIC';
    end if;
    v := m417_internal.swap_text(v,
        $a$- One character wants something concrete; something gets in the way; it escalates in two or three steps; it ends on a surprise that is funny or warm.$a$,
        $a$- One character wants something concrete; something gets in the way or builds up once; it ends on a surprise that is funny or warm. There is no room for more: the whole short is [[SHOTS_MIN]] to [[SHOTS_MAX]] shots.$a$);
    v := m417_internal.swap_text(v,
        $a$If the production request contains a brief, follow it.$a$,
        $a$THIS FORMAT: A LOOPING SHORT
- One idea, one place, one main object. Two characters carry it; a third may appear only as the surprise at the end.
- It follows one of these patterns; name it in pattern:
  DONT_OPEN_IT - a warning, a slow opening, a harmless funny surprise.
  CAN_HE_DO_IT - a countdown, an attempt, an unexpected result.
  EXPECTATION_FLIP - something built with care, a threat approaches, a different thing happens.
  KINDNESS - someone lacks something, a friend notices, a small warm reward.
  WHO_DID_IT - the evidence, the faces one by one, the least expected culprit.
  COPY_ME - one clear move, the others copy it, the last one adds a funny twist.
  COUNT_AND_JUMP - a rhythm of three, one action on every count, back to one.
  BIG_BUILD_UP - a huge promise, shaking and lights, a tiny result.
  HIDE_AND_PEEK - an empty place, hiding spots found one by one, the last one hides in plain sight.
- The last image leads back to the first, so the short can be watched again and again: the lid falls shut and the box wobbles again, the runner is back at the start line, someone turns to the viewer ("Again!", "Your turn!"). Say how in loop.
- It ends warm. Nobody is humiliated, nobody is hurt.
- Never: strings, ropes, cords, kites or anything tied; more than three of the same object; anything poured, splashed or swum in; mirrors; fine finger work.
- Vary. Do not use the pattern, the lead character or the location of the most recent shorts back to back.

Recent shorts, newest first: [[RECENT]]

If the production request contains a brief, follow it.$a$);
    v := m417_internal.swap_text(v,
        $a$"emotional_beat": "", "hook": "",$a$,
        $a$"emotional_beat": "", "pattern": "", "hook": "", "loop": "",$a$);
    v := m417_internal.swap_text(v,
        $a$premise tells the whole story in three to five sentences: the want, the obstacle, each escalation, the payoff.$a$,
        $a$premise tells the whole story in two or three sentences: the hook, the build-up, the payoff. pattern is one of the pattern names above. loop says how the last image leads back to the first.$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('TOPIC', 2, false, 'Step 7: as version 1, for the looping short - patterns, loop, variety.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- SCRIPT 2 ---------------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SCRIPT' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: SCRIPT';
    end if;
    v := m417_internal.swap_text(v,
        $a$- At most [[LINES_MAX]] spoken lines. Every line is one short sentence of at most [[LINE_CHARS]] characters, spaces included.$a$,
        $a$- At most [[LINES_MAX]] spoken lines, each of at most [[LINE_WORDS]] words and [[LINE_CHARS]] characters, spaces included. A line is something a child would shout in the playground: a warning, a dare, a count, a cheer.$a$);
    v := m417_internal.swap_text(v,
        $a$- Then a clear want, an obstacle, two or three escalations each bigger than the last, a turn nobody expected, and a payoff that answers the hook. End on a short button: one last look, line or gag.$a$,
        $a$- Then one build-up and a payoff that answers the hook. Three movements and nothing more: hook, build-up, payoff. The payoff is a surprise, harmless and warm; nobody is humiliated or hurt.
- loop: the last image leads back to the first, so the short can be watched again and again: the lid falls shut and the box wobbles again, the runner is back at the start line, someone turns to the viewer ("Again!", "Your turn!"). Say how in loop.
- One place, one main object. Two characters carry it; a third may appear only as the surprise at the end.$a$);
    v := m417_internal.swap_text(v,
        $a$- Tell it in pictures. Dialogue is real conversation between the characters: short, quick, back and forth, each line answering the one before; one character never explains the plot.$a$,
        $a$- Tell it in pictures: with the sound off the story is still clear. When two lines are spoken they answer each other; nobody explains the plot.$a$);
    v := m417_internal.swap_text(v,
        $a$WRITE IT SO IT CANNOT BE FILMED WRONG$a$,
        $a$SOUND
- music_mood: the mood of the music that runs from the first frame, one of: [[MUSIC_MOODS]].
- sfx: up to three sound effects, each with the moment it lands on, for example {"at": "the lid pops open", "sound": "pop"}.

WRITE IT SO IT CANNOT BE FILMED WRONG$a$);
    v := m417_internal.swap_text(v,
        $a$tiny hand work such as tying knots.$a$,
        $a$tiny hand work such as tying knots. Never: strings, ropes, cords, kites or anything tied; more than three of the same object; anything poured, splashed or swum in.$a$);
    v := m417_internal.swap_text(v,
        $a${"title": "", "logline": "", "hook": "", "payoff": "", "look": "",$a$,
        $a${"title": "", "logline": "", "pattern": "", "hook": "", "payoff": "", "loop": "", "music_mood": "", "sfx": [{"at": "", "sound": ""}], "look": "",$a$);
    v := m417_internal.swap_text(v,
        $a$Before answering, check: the total is inside the range;$a$,
        $a$Before answering, check: the total is inside the range; loop and music_mood are filled; no line has more than [[LINE_WORDS]] words;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SCRIPT', 2, false, 'Step 10: as version 1, for the looping short - three movements, loop, music, few words.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- SHOT_PACKAGE 2 -----------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$- story: want, obstacle, escalation, a real turn, a payoff that lands?$a$,
        $a$- story: one idea, one build-up, a payoff that answers the hook and surprises - and does the last image lead back to the first?$a$);
    v := m417_internal.swap_text(v,
        $a$- dialogue: short, natural, back and forth, each line worth its seconds?$a$,
        $a$- dialogue: a few words per line, the kind of thing a child shouts - is every line needed?$a$);
    v := m417_internal.swap_text(v,
        $a$How the film is made: every shot is generated separately by an AI video model as a clip of [[GEN_SECONDS]] seconds, and the edit uses the first edit_seconds of it. The model sees one shot at a time and remembers nothing.$a$,
        $a$How the film is made: every shot is produced in two steps. First one still picture of its first instant is drawn and the owner approves it. Then an AI video model animates that exact picture into a clip of [[GEN_SECONDS]] seconds, and the edit uses the first edit_seconds of it. The model sees one shot at a time and remembers nothing.$a$);
    v := m417_internal.swap_text(v,
        $a$DIALOGUE
- At most one spoken line per shot.$a$,
        $a$CAMERA
- camera_angle is one of EYE_LEVEL, LOW_ANGLE, HIGH_ANGLE, TOP_DOWN, PROFILE, THREE_QUARTER, DRONE. EYE_LEVEL (the children's eye level) is the default. LOW_ANGLE for a daring or heroic moment. HIGH_ANGLE for a small "uh-oh". TOP_DOWN for something on a table or on the ground. PROFILE (seen exactly from the side) for running, jumping and walking. THREE_QUARTER gives depth to two children side by side. DRONE (high above the place) only in the first or the last shot, with shot_size WIDE or EXTREME_WIDE.
- camera_move is exactly one of STATIC, PUSH_IN, PULL_BACK, TRACK, PAN, RISE, DRONE_DESCEND, HANDHELD. STATIC is the safe choice and the right one for dancing and for a surprise. PUSH_IN builds tension. PULL_BACK reveals the surprise. TRACK follows a run or a jump. PAN travels across faces. RISE opens up the place at the end. DRONE_DESCEND only with camera_angle DRONE. A shot in which a line is spoken ON_CAMERA is STATIC or PUSH_IN.
- A short of three shots: the hook MEDIUM or MEDIUM_CLOSE at EYE_LEVEL, face and problem in one picture; the build-up WIDE or PROFILE with one move; the payoff a CLOSE_UP reaction or a PULL_BACK that reveals the surprise.

FIRST FRAME
- first_frame describes the still picture of the first instant of the shot in 80 to 500 characters: who is where in the frame (left, right, foreground, background), each pose, each expression, where each prop is. A frozen moment: no movement, nothing that happens later. This picture is drawn first and shown to the owner, so it must be exact.
- The last shot ends close to the first_frame of shot 1, as the script's loop says, so the short loops.

DIALOGUE
- At most one spoken line per shot.$a$);
    v := m417_internal.swap_text(v,
        $a$- camera: angle and movement (static, slow push-in, pan, low angle ...).$a$,
        $a$- camera: the angle and the move once more in a few plain words.$a$);
    v := m417_internal.swap_text(v,
        $a$"purpose": "", "shot_size": "", "camera": "",$a$,
        $a$"purpose": "", "shot_size": "", "camera_angle": "", "camera_move": "", "camera": "", "first_frame": "",$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has beats starting at 0;$a$,
        $a$every shot has beats starting at 0; every shot has camera_angle, camera_move and a first_frame that is a frozen picture;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 2, false, 'Step 11: as version 1, plus the camera vocabulary and the first frame of every shot.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- DIRECTOR 2 and 3 ---------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'DIRECTOR' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: DIRECTOR';
    end if;
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('DIRECTOR', 2, false, 'Step 14: as v1, plus a rule to converge instead of polishing without end.',
            m417_internal.swap_text(v, $a$APPROVE requires a pre-QC verdict of PASS$a$,
                                    v_converge || $a$APPROVE requires a pre-QC verdict of PASS$a$))
    on conflict (prompt_code, version) do nothing;
    v := m417_internal.swap_text(v,
        $a$APPROVE requires a pre-QC verdict of PASS$a$,
        v_converge || $a$This is a looping short of a few shots. What decides it: the first picture raises a question, the payoff answers it with a surprise, the last image leads back to the first, and every first_frame can be drawn exactly as written. The owner sees and approves the first frame of every shot before any video is paid for, so do not hold the package back over details a picture will settle.

APPROVE requires a pre-QC verdict of PASS$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('DIRECTOR', 3, false, 'Step 14: as v2, for the looping short with approved first frames.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- The short-format versions are the ones in force.
    update public.step_prompts set is_active = false
    where prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE', 'DIRECTOR') and is_active
      and not ((prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE') and version = 2)
               or (prompt_code = 'DIRECTOR' and version = 3));
    update public.step_prompts set is_active = true
    where (prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE') and version = 2)
       or (prompt_code = 'DIRECTOR' and version = 3);
end $$;

-- ----- SHOT_PACKAGE 3: one event per shot ---------------------------------
-- Version 2 with one rule added. Built from version 2 as it stands in
-- the table, so the two cannot drift apart unnoticed.
do $$
declare
    v text;
begin
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 2;
    if v is null then
        raise exception 'M417_013_PROMPT_V2_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$Each beat is one visible action or change of expression. The action must start at once: the cut is short.$a$,
        $a$Each beat is one visible action or change of expression. The action must start at once: the cut is short. At most [[BEATS_MAX]] beats: one event and the reaction to it. The video model performs one event per shot and drops a second one, so what does not fit is left out, never squeezed in.$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has beats starting at 0;$a$,
        $a$every shot has at most [[BEATS_MAX]] beats, the first at 0;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 3, false, 'Step 11: as version 2, plus one event per shot (at most max_beats_per_shot beats).', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;
    update public.step_prompts set is_active = (version = 3) where prompt_code = 'SHOT_PACKAGE';
end $$;

-- ---------------------------------------------------------------------
-- 11. Permissions: only service_role (Make) may call the RPCs.
-- ---------------------------------------------------------------------
do $$
declare
    r record;
    v_names text[] := array[
        'start_production_job', 'job_next_step', 'get_job_context', 'evaluate_budget_gate',
        'save_artifact', 'record_policy_check', 'get_series_bible', 'route_revision',
        'record_final_director_decision', 'commit_production_package',
        'list_voice_work', 'register_voice_take', 'apply_voice_qc', 'check_music_licenses',
        'video_work_pending', 'next_video_actions', 'prepare_shot_attempt',
        'record_attempt_submission', 'record_provider_poll', 'register_generation_output',
        'apply_visual_qc', 'ack_video_advance',
        'select_final_audio_track', 'begin_assembly', 'create_render', 'mark_render_submitted',
        'record_render_poll', 'complete_render', 'apply_final_qc', 'approve_release',
        'resolve_thumbnail', 'save_publication_package', 'request_publish_approval',
        'handle_approval_link', 'claim_publication', 'record_publication',
        'list_publications_for_analytics', 'record_analytics_snapshot', 'episode_cost_summary',
        'weekly_learning_input', 'save_learning_report', 'daily_maintenance', 'pipeline_overview',
        'set_pipeline_enabled', 'set_text_setting', 'set_numeric_setting',
        'open_monthly_budget',
        'resume_production_job', 'cancel_production_job', 'reissue_shot_review',
        'reset_publication_claim', 'register_music_track',
        'next_keyframe_work', 'register_keyframe', 'apply_keyframe_check', 'fail_keyframe'];
    v_has_service boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
    for r in
        select p.oid::regprocedure as sig, n.nspname, p.proname
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where (n.nspname = 'public' and p.proname = any (v_names))
           or n.nspname = 'm417_internal'
    loop
        execute format('revoke all on function %s from public', r.sig);
        if exists (select 1 from pg_roles where rolname = 'anon') then
            execute format('revoke all on function %s from anon', r.sig);
        end if;
        if exists (select 1 from pg_roles where rolname = 'authenticated') then
            execute format('revoke all on function %s from authenticated', r.sig);
        end if;
        if v_has_service then
            if r.nspname = 'public' then
                execute format('grant execute on function %s to service_role', r.sig);
            else
                execute format('revoke all on function %s from service_role', r.sig);
            end if;
        end if;
    end loop;

    if (select count(distinct p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = any (v_names)) <> cardinality(v_names)
    then
        raise exception 'M417_002_INCOMPLETE: not every RPC was created';
    end if;
end $$;

-- Run by the database scheduler or by the owner in the SQL editor, not through the API.
do $$
declare
    r record;
    v_role text;
begin
    for r in
        select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname in ('watchdog_tick', 'watchdog_run', 'approve_model_pilot', 'revoke_model_pilot', 'set_video_reference', 'set_video_wardrobe',
                                                       'keyframe_overview', 'decide_keyframes', 'require_keyframe_for_attempt', 'keyframes_on_video_stage')
    loop
        execute format('revoke all on function %s from public', r.sig);
        foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
            if exists (select 1 from pg_roles where rolname = v_role) then
                execute format('revoke all on function %s from %I', r.sig, v_role);
            end if;
        end loop;
    end loop;
end $$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_002_APPLIED', 'INFO', 'CONTROL_PLANE', 'Pipeline layers (002) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
