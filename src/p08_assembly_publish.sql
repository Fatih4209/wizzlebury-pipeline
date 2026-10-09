
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
