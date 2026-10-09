
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
