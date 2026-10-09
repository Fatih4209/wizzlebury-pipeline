
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
