from flow import *
import subprocess

def as_role(role, q):
    try:
        return ('ok', _psql_role(role, q))
    except RpcError as e:
        return ('err', str(e))
def _psql_role(role, q):
    r = subprocess.run(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', f"set role {role}; {q}"], capture_output=True, text=True)
    if r.returncode != 0: raise RpcError(r.stderr.strip().split('\n')[0])
    return r.stdout.strip()
def raises(name, q, needle):
    try:
        sql(q); check(name, False, 'no error')
    except RpcError as e:
        check(name, needle in str(e), str(e))

sql(open('seed_video.sql').read())
sql("update public.system_settings set value_numeric = 50 where key = 'max_active_jobs'")
rpc('set_text_setting', {"p_key": "storage_base_url", "p_value": "https://proj.supabase.co/storage/v1"})
rpc('set_text_setting', {"p_key": "notify_chat_id", "p_value": "123456"})

# --- who may call what ----------------------------------------------------
for role in ('anon', 'authenticated'):
    k, v = as_role(role, "select public.job_next_step(gen_random_uuid())"); check(f'{role} cannot call an RPC', k == 'err' and 'permission denied' in v, v)
    k, v = as_role(role, "select public.set_pipeline_enabled(true)"); check(f'{role} cannot flip the pipeline switch', k == 'err' and 'permission denied' in v, v)
    k, v = as_role(role, "select count(*) from public.production_jobs"); check(f'{role} cannot read job tables', k == 'err' and 'permission denied' in v, v)
k, v = as_role('service_role', "select count(*) from public.production_jobs"); check('service_role cannot read job tables directly', k == 'err' and 'permission denied' in v, v)
k, v = as_role('service_role', "insert into public.director_decisions (job_id, episode_id, production_version, stage, decision, actor) values (gen_random_uuid(), gen_random_uuid(), 1, 'PRODUCTION', 'APPROVE', 'CLAUDE')"); check('service_role cannot write a director decision directly', k == 'err' and 'permission denied' in v, v)
k, v = as_role('service_role', "select m417_internal.flag('pipeline_enabled', false)"); check('internal helpers are not callable from the API role', k == 'err' and 'permission denied' in v, v)
k, v = as_role('service_role', "select public.pipeline_overview() ->> 'pipeline_enabled'"); check('service_role can call the RPCs', k == 'ok' and v == 'false', v)
check('every new RPC is SECURITY DEFINER with an empty search_path', one("""
    select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public') and p.proname in ('start_production_job','job_next_step','get_job_context','evaluate_budget_gate','save_artifact','record_policy_check','get_series_bible','route_revision','record_final_director_decision','commit_production_package','list_voice_work','register_voice_take','apply_voice_qc','check_music_licenses','video_work_pending','next_video_actions','prepare_shot_attempt','record_attempt_submission','record_provider_poll','register_generation_output','apply_visual_qc','ack_video_advance','select_final_audio_track','begin_assembly','create_render','mark_render_submitted','record_render_poll','complete_render','apply_final_qc','approve_release','resolve_thumbnail','save_publication_package','request_publish_approval','handle_approval_link','claim_publication','record_publication','list_publications_for_analytics','record_analytics_snapshot','episode_cost_summary','weekly_learning_input','save_learning_report','daily_maintenance','pipeline_overview','set_pipeline_enabled','set_text_setting','set_numeric_setting','resume_production_job','cancel_production_job','reissue_shot_review','reset_publication_claim','register_music_track','open_monthly_budget')
      and (p.prosecdef is not true or not (p.proconfig @> array['search_path=""']))""") == '0')
check('all 17 new tables have RLS on and no API grants', one("""
    select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('system_text_settings','production_jobs','job_step_log','job_artifacts','policy_checks','director_decisions','music_tracks','job_music_tracks','renders','publication_packages','publications','analytics_snapshots','learning_reports','service_usage','service_rates','video_action_state','video_driver_state')
      and c.relrowsecurity
      and not exists (select 1 from information_schema.role_table_grants g where g.table_schema='public' and g.table_name = c.relname and g.grantee in ('anon','authenticated','service_role','PUBLIC'))""") == '17')

# --- the old rules still hold -------------------------------------------------
job = start('r-1'); ep = one(f"select episode_id from public.production_jobs where id='{job}'")
expect_error('production approvals by link are retired', 'request_human_approval', {"p_scope_type": "EPISODE_PRODUCTION", "p_scope_id": ep, "p_requested_by": "X"}, 'EPISODE_PRODUCTION_APPROVAL_RETIRED')
raises('human_approved cannot be switched on by hand', f"update public.episodes set human_approved = true where id = '{ep}'", 'EPISODE_HUMAN_APPROVAL_RECORD_REQUIRED')
raises('episode cannot be approved without a decision', f"update public.episodes set state = 'APPROVED' where id = '{ep}'", 'EPISODE_PRODUCTION_APPROVAL_REQUIRED')
raises('director_approval_id must be a real approval', f"update public.episodes set director_approval_id = gen_random_uuid() where id = '{ep}'", 'EPISODE_DIRECTOR_APPROVAL_INVALID')
plan(job)
dec = one(f"select director_decision_id from public.production_jobs where id='{job}'")
job2 = start('r-2'); ep2 = one(f"select episode_id from public.production_jobs where id='{job2}'")
raises("another episode's approval is not accepted", f"update public.episodes set director_approval_id = '{dec}' where id = '{ep2}'", 'EPISODE_DIRECTOR_APPROVAL_INVALID')
raises('locked spec is still immutable', f"update public.shot_specifications set generation_prompt = 'x' where shot_id in (select id from public.shots where episode_id = '{ep}')", 'LOCKED_SHOT_SPECIFICATION_IS_IMMUTABLE')
raises('locked manifest is still immutable', f"update public.production_manifests set human_approved = true where episode_id = '{ep}'", 'LOCKED_PRODUCTION_MANIFEST_IS_IMMUTABLE')
# a draft spec / manifest cannot be locked outside the commit path
sid = one(f"select id from public.shots where episode_id = '{ep}' and shot_order = 1")
sql("set session_replication_role = replica; "
    f"insert into public.shot_specifications (shot_id, version, is_active, narrative_action, shot_size, duration_seconds, generation_prompt, aspect_ratio, status) values ('{sid}', 2, false, 'a', 'MEDIUM', 5, 'p', '9:16', 'DRAFT'); "
    f"insert into public.production_manifests (episode_id, production_version, manifest_code, status, pilot_shot_id) values ('{ep}', 2, 'TEST-M2', 'DRAFT', '{sid}'); "
    "set session_replication_role = origin;")
raises('a draft spec cannot be locked by hand', f"update public.shot_specifications set status = 'LOCKED' where shot_id = '{sid}' and version = 2", 'SHOT_SPEC_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK')
raises('the marker alone does not lock a manifest without a decision', f"select set_config('m417.director_lock','on',false); update public.production_manifests set status = 'LOCKED' where manifest_code = 'TEST-M2'", 'MANIFEST_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK')
raises('attempts still cannot be inserted by hand', f"insert into public.attempts (shot_id, attempt_no, idempotency_key, provider, model, prompt_version, status, estimated_cost) values ('{sid}', 1, 'x', 'p', 'm', 1, 'BUDGET_RESERVED', 1)", 'ATTEMPT_INSERT_REQUIRES_ACQUIRE_FUNCTION')
raises('ledger still append-only', "update public.cost_ledger set amount = 0", 'COST_LEDGER_IS_APPEND_ONLY') if one("select count(*) from public.cost_ledger") != '0' else check('ledger still append-only (trigger present)', one("select count(*) from pg_trigger where tgname = 'trg_cost_ledger_no_update'") == '1')

# --- storyboard flag on = old behaviour -----------------------------------------
g = voice(job); rpc('set_generation_enabled', {"p_enabled": True})
sql("update public.system_flags set value = true where key = 'storyboard_required'")
actions(); p = rpc('prepare_shot_attempt', {"p_shot_id": sid})
check('with storyboard_required on, a shot without a storyboard is refused', p['decision'] == 'BLOCKED' and 'STORYBOARD' in p['reason'], str(p))
check('nothing was reserved', one("select coalesce(sum(reserved_amount),0)::float from public.budgets") == '0')
N = start('r-3')
rpc('save_artifact', {"p_job_id": N, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
rpc('save_artifact', {"p_job_id": N, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
rpc('record_policy_check', {"p_job_id": N, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS}); rpc('get_series_bible', {"p_job_id": N})
rpc('save_artifact', {"p_job_id": N, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT})
rpc('save_artifact', {"p_job_id": N, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shots()})
rpc('save_artifact', {"p_job_id": N, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS}); rpc('route_revision', {"p_job_id": N})
rpc('record_final_director_decision', {"p_job_id": N, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
r = rpc('commit_production_package', {"p_job_id": N}); check('with storyboard_required on, commit stops instead of skipping the stage', r['state'] == 'BLOCKED' and r['blocked_reason'] == 'STORYBOARD_REQUIRED', str(r))
sql("update public.system_flags set value = false where key = 'storyboard_required'")
rpc('resume_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "flag off"})

# --- retry with no compatible fallback model -> escalate ------------------------
sql("set session_replication_role = replica; update public.generation_models set min_duration_seconds = 8, max_duration_seconds = 8 where model_code = 'veo-3.1-fast-generate-preview'; set session_replication_role = origin;")
run_shot(sid, VISUAL_FAIL)
actions(); p = rpc('prepare_shot_attempt', {"p_shot_id": sid})
check('no model for the retry -> escalated, not blocked silently', p['decision'] == 'ESCALATED' and one(f"select state from public.shots where id='{sid}'") == 'ESCALATED', str(p))
check('the owner is asked about the clip that exists', [a['action'] for a in actions() if a['job_id'] == job] == ['HUMAN_REVIEW'])
check('reissue supersedes a lost review link', rpc('reissue_shot_review', {"p_shot_id": sid})['superseded'] == 0)

# --- health probe policy ------------------------------------------------------
check('probe recorded with an honest reason', one("select count(*) from public.generation_model_health_history where check_source = 'SYSTEM_RECOVERY' and reason like 'ON_DEMAND_PROBE%'") != '0')
check('accepted submissions recorded as provider responses', one("select count(*) from public.generation_model_health_history where check_source = 'PROVIDER_RESPONSE' and new_status = 'AVAILABLE'") != '0')
summary()
