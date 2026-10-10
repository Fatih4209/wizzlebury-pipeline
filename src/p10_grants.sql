
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
