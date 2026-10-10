-- =====================================================================
-- M417 / WIZZLEBURY  -  012 short format: keyframe first, camera plan
--
-- Run after 011. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- 1. Keyframe first. A still picture of the first instant of every shot
--    is drawn, checked and shown to the owner. Only an approved picture
--    becomes the start frame of a paid video generation; without one no
--    attempt row can be created while keyframe_required is on.
-- 2. With a start frame the video request no longer describes what
--    everything looks like; it says what moves and what the camera does.
-- 3. Camera plan. Every shot names an angle and a move from a fixed
--    vocabulary and describes its first frame.
-- 4. Looping short. A script states how it loops and its music mood and
--    keeps every line to a few words. New instructions for topic,
--    script, shots and final decision.
-- 5. At most max_parallel_video_attempts generations run side by side.
--
-- The three new flags are created switched off.
-- =====================================================================
begin;

do $$
begin
    if to_regclass('public.step_prompts') is null
       or to_regclass('public.script_votes') is null
       or not exists (select 1 from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 1)
    then
        raise exception 'M417_010_NOT_FOUND: apply 010_film_grammar.sql first';
    end if;
end $$;

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
    ('start_frame_reference_images', 3, 'Character reference images sent to the video model besides an approved start frame. 0 sends the start frame alone.'),
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
    v_max := least(greatest(coalesce(nullif(v_meta ->> 'max_reference_images', '')::integer, 4) - 1, 0),
                   greatest(m417_internal.num('start_frame_reference_images', 3)::integer, 0));
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
        || 'Keep its framing, where everyone stands, the outfits, the props, the place and the light; no new person and no new object appears. There is exactly one of each character: never a second copy of anybody, not in the background either.'
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
    update public.step_prompts set is_active = false where prompt_code = 'SHOT_PACKAGE' and version <> 3 and is_active;
    update public.step_prompts set is_active = true where prompt_code = 'SHOT_PACKAGE' and version = 3 and not is_active;
end $$;

-- ----- SHOT_PACKAGE 4: everybody is there from the first shot --------------
-- Version 3 with two rules added: nobody pops into a scene, and a first
-- frame shows props in the state the shot before left them.
do $$
declare
    v text;
begin
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 3;
    if v is null then
        raise exception 'M417_014_PROMPT_V3_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.$a$,
        $a$- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.
- Nobody pops into the scene. Shot 1 shows every character who takes part in the scene, all in one picture, so the viewer knows who is there before anything happens; a line in shot 1 is spoken by a character who is seen in it, never from off-screen. Only a character whose arrival is the surprise of the payoff may be missing from shot 1.
- The story runs on from picture to picture. The first_frame of a shot shows the place, the characters, their positions and every prop exactly in the state in which the shot before ended: what is closed stays closed until a shot shows it being opened, and what is inside something is not visible before it comes out.$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has camera_angle, camera_move and a first_frame that is a frozen picture;$a$,
        $a$every shot has camera_angle, camera_move and a first_frame that is a frozen picture; shot 1 shows everyone in the scene; every first_frame continues from the end of the shot before it;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 4, false, 'Step 11: as version 3, plus: everybody is in shot 1, and first frames continue from the shot before.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;
    update public.step_prompts set is_active = false where prompt_code = 'SHOT_PACKAGE' and version <> 4 and is_active;
    update public.step_prompts set is_active = true where prompt_code = 'SHOT_PACKAGE' and version = 4 and not is_active;
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
values ('SCHEMA_012_APPLIED', 'INFO', 'CONTROL_PLANE', 'Short format: keyframe first, camera plan (012) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
