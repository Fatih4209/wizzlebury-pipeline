
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
