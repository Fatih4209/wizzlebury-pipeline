-- =====================================================================
-- M417 / WIZZLEBURY  -  011 final QC after a resumed render
--
-- Run after 010. Safe to run more than once. Nothing is spent.
-- A job stopped at final QC and resumed by the owner renders again with
-- the job at step 32; the episode stayed in ASSEMBLY and the release
-- approval was then refused (INVALID_EPISODE_STATE_TRANSITION).
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.step_prompt(uuid,integer,text,text)') is null then
        raise exception 'M417_010_NOT_FOUND: apply 010_film_grammar.sql first';
    end if;
end $$;

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

notify pgrst, 'reload schema';

commit;
