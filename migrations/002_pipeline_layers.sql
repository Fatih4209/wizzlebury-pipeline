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
        'video_driver_state']
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
    ('max_voice_takes', 3, 'Voice takes allowed per dialogue line.'),
    ('max_renders', 2, 'Renders allowed per job.'),
    ('publish_approval_ttl_hours', 72, 'Lifetime of a publish / escalation approval link.'),
    ('voice_duration_tolerance_seconds', 0.5, 'How far the dialogue of a shot may run past the shot duration.'),
    ('min_audio_bytes', 2000, 'A voice file smaller than this fails QC.'),
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
    ('job_idle_alert_minutes', 30, 'A READY job without activity for this long is reported by daily maintenance.')
on conflict (key) do nothing;

insert into public.system_text_settings (key, value, description) values
    ('notify_chat_id', '', 'Telegram chat id that receives approval links and reports.'),
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
            'code_rule', 'Use the exact character and location codes listed here. Do not invent characters, locations or assets.',
            'dialogue_rule', 'Only characters with has_voice = true may speak.',
            'creative_rules', v_profile.creative_rules,
            'quality_rules', v_profile.quality_rules),
        'style', coalesce(v_style, '{}'::jsonb),
        'characters', v_characters,
        'locations', v_locations);
end;
$function$;

-- ----- script / shot package validation ------------------------------
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
        if jsonb_typeof(v_scene -> 'dialogue') = 'array' then
            for v_line in select * from jsonb_array_elements(v_scene -> 'dialogue')
            loop
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
        if coalesce(btrim(v_shot ->> 'video_prompt'), '') = '' then
            v_issues := v_issues || m417_internal.issue(
                'SHOTS', v_ref, 'video_prompt is empty.', 'Write the video prompt for this shot.');
        end if;
        if jsonb_typeof(v_shot -> 'characters') = 'array' then
            for v_char in select * from jsonb_array_elements_text(v_shot -> 'characters')
            loop
                if m417_internal.resolve_character(v_job.series_id, v_char) is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref, 'Unknown character: ' || v_char,
                        'Use character codes from the series bible.');
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
        if jsonb_typeof(v_shot -> 'dialogue_line_nos') = 'array' then
            for v_line_no in select * from jsonb_array_elements_text(v_shot -> 'dialogue_line_nos')
            loop
                v_line := m417_internal.script_line(v_script, v_shot ->> 'scene_no', v_line_no);
                if v_line is null then
                    v_issues := v_issues || m417_internal.issue(
                        'SHOTS', v_ref,
                        'dialogue_line_nos refers to line ' || v_line_no || ', which is not in scene ' || coalesce(v_shot ->> 'scene_no', '?') || ' of the script.',
                        'Reference only line numbers that exist in the script scene of this shot.');
                else
                    v_assigned := v_assigned || ((v_line ->> 'scene_no') || ':' || (v_line ->> 'line_no'));
                end if;
            end loop;
        end if;
    end loop;
    if v_total < 6 or v_total > 15 then
        v_issues := v_issues || m417_internal.issue(
            'SHOTS', 'total duration',
            'Shot durations add up to ' || v_total || ' seconds; the episode must be 6 to 15 seconds.',
            'Change the number of shots or their durations so the total is between 6 and 15 seconds.');
    end if;
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
    v_status jsonb;
begin
    v_status := m417_internal.job_status(p_job_id);
    if v_status is null then
        raise exception 'JOB_NOT_FOUND';
    end if;
    -- With the pipeline switched off no scenario may act on a job.
    if m417_internal.flag('pipeline_enabled', false) is not true
       and v_status ->> 'state' = 'READY'
    then
        v_status := v_status || jsonb_build_object(
            'state', 'BLOCKED', 'blocked_reason', 'PIPELINE_DISABLED');
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
                -- approved benchmark. Live health is checked at acquisition.
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
                  and exists (
                      select 1 from public.generation_model_benchmarks b
                      where b.model_id = gpm.model_id
                        and b.benchmark_status = 'HUMAN_APPROVED'
                        and b.approved_at is not null);
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

    -- A clean script or shot package closes the feedback that asked for it.
    if v_type in ('SCRIPT', 'SHOT_PACKAGE') then
        update public.production_jobs
        set revision_feedback = null
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
begin
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
    select string_agg(c.name || ': ' || left(coalesce(c.canonical_description, ''), 230), ' ' order by c.character_code)
    into v_text
    from public.characters c
    where c.id = any (coalesce(p_character_ids, array[]::uuid[]));
    if v_text is not null then
        v_parts := v_parts || ('Characters. ' || v_text);
    end if;
    select l.name || ': ' || left(coalesce(l.canonical_description, ''), 200) into v_text
    from public.locations l where l.id = p_location_id;
    if v_text is not null then
        v_parts := v_parts || ('Location. ' || v_text);
    end if;
    select left(coalesce(sb.visual_style, ''), 260) into v_text
    from public.style_bibles sb
    where sb.series_id = p_series_id and sb.status <> 'ARCHIVED'
    order by sb.version desc
    limit 1;
    if coalesce(v_text, '') <> '' then
        v_parts := v_parts || ('Style. ' || v_text);
    end if;
    v_parts := v_parts || 'Vertical 9:16 framing. No on-screen text, subtitles, logos or watermarks.'::text;
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
               s.shot_code, vi.provider_voice_id
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
            v_items := v_items || jsonb_build_object(
                'line_id', v_line.id,
                'action', case v_line.status when 'PLANNED' then 'GENERATE' else 'RETAKE' end,
                'text', m417_internal.clean(v_line.dialogue_text),
                'voice_reference_id', v_line.provider_voice_id,
                'storage_path', format('%s/%s/audio/%s_L%s_T%s_%s.mp3',
                    v_series_code, v_content_id, v_line.shot_code, v_line.audio_order,
                    case v_line.status when 'PLANNED' then v_line.take_no else v_line.take_no + 1 end,
                    m417_internal.rand_suffix()));
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
        || jsonb_build_object('items', v_items, 'count', jsonb_array_length(v_items));
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
                || jsonb_build_object('file_size_bytes', v_size, 'bitrate_kbps', v_kbps)
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
            (v_line.timing_metadata - 'file_size_bytes' - 'bitrate_kbps')
                || jsonb_build_object('file_size_bytes', v_size, 'bitrate_kbps', v_kbps),
            'QC_PENDING', v_take_no)
        returning id into v_take_id;
    end if;

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

-- The complete request body for the provider. Make forwards it as is.
create or replace function m417_internal.build_provider_request(p_attempt_id uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_row record;
    v_route text;
    v_defaults jsonb;
    v_params jsonb;
begin
    select a.provider, a.model, gm.model_version, gm.capability_metadata,
           ss.generation_prompt, ss.negative_prompt, ss.aspect_ratio,
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

    if v_route = 'KLING' then
        return jsonb_build_object(
            'model', coalesce(v_row.capability_metadata ->> 'api_model', 'kling'),
            'task_type', coalesce(v_row.capability_metadata ->> 'task_type', 'video_generation'),
            'input', jsonb_build_object(
                'prompt', v_row.generation_prompt,
                'negative_prompt', coalesce(v_row.negative_prompt, ''),
                'aspect_ratio', v_row.aspect_ratio,
                'duration', v_row.duration_seconds::integer,
                'version', coalesce(v_row.model_version, '2.6'),
                'mode', 'std',
                'enable_audio', false,
                'prefer_multi_shots', false) || v_defaults)::text;
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
        topic_retry_count = case when v_job.blocked_reason = 'POLICY_GATE_1_FAILED' then 0 else topic_retry_count end
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
        'reset_publication_claim', 'register_music_track'];
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

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_002_APPLIED', 'INFO', 'CONTROL_PLANE', 'Pipeline layers (002) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
