-- =====================================================================
-- M417 / WIZZLEBURY  -  005 resilience
--
-- Run after 004. Safe to run more than once; one transaction.
--
-- 1. One run per paid step: a second run that asks for a step while the
--    first is still working is told IN_PROGRESS and does nothing.
-- 2. A voice line handed to a run is not handed out again meanwhile.
-- 3. Watchdog: a job without activity is started again (three times per
--    step, then it is blocked as STALLED); the owner is told on Telegram
--    about every stop; a job resumed by the owner starts by itself.
--    The watchdog itself is scheduled separately (needs pg_cron + pg_net).
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.speech_seconds(text)') is null
       or to_regprocedure('m417_internal.voice_retake_plan(uuid)') is null
    then
        raise exception 'M417_004_NOT_FOUND: apply 003 and 004 first';
    end if;
end $$;

alter table public.production_jobs
    add column if not exists step_claimed_at timestamptz,
    add column if not exists step_claimed_step integer,
    add column if not exists watchdog_step integer,
    add column if not exists watchdog_resumes integer not null default 0,
    add column if not exists watchdog_last_at timestamptz,
    add column if not exists kick_requested boolean not null default false,
    add column if not exists notified_key text;

create table if not exists public.voice_handouts (
    shot_specification_id uuid not null,
    audio_order integer not null,
    take_no integer not null,
    handed_out_at timestamptz not null default now(),
    primary key (shot_specification_id, audio_order)
);
alter table public.voice_handouts enable row level security;
do $$
declare
    v_role text;
begin
    execute 'revoke all on public.voice_handouts from public';
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on public.voice_handouts from %I', v_role);
        end if;
    end loop;
end $$;

insert into public.system_settings (key, value_numeric, description) values
    ('step_lease_seconds', 180, 'While a paid step is being worked on, a second run asking for the same step is told IN_PROGRESS.'),
    ('voice_handout_seconds', 240, 'A voice line handed to a run is not handed out again inside this window.'),
    ('watchdog_idle_minutes', 12, 'A READY job without activity for this long is started again by the watchdog.'),
    ('watchdog_max_resumes', 3, 'Automatic restarts per step before the job is blocked as STALLED.')
on conflict (key) do nothing;

insert into public.system_text_settings (key, value, description) values
    ('webhook_notify', '', 'Make webhook that forwards a text to Telegram (M417-Bildirim).')
on conflict (key) do nothing;

create or replace function m417_internal.step_has_lease(p_step integer)
 returns boolean language sql immutable set search_path to ''
as $function$
    -- The steps that are one paid model call followed by one save.
    select p_step = any (array[6, 7, 8, 10, 11, 12, 14, 19, 32, 33, 34, 36, 37]);
$function$;

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

do $$
declare
    r record;
    v_role text;
begin
    for r in
        select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where (n.nspname = 'm417_internal' and p.proname in ('step_has_lease', 'voice_batch_open', 'block_reason_tr'))
           or (n.nspname = 'public' and p.proname in ('watchdog_tick', 'watchdog_run'))
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
values ('SCHEMA_005_APPLIED', 'INFO', 'CONTROL_PLANE', 'Resilience (005) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
