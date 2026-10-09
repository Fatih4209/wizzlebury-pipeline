"""The live path: no benchmark seed, Kling registered by 007 and approved by the owner for a pilot."""
from flow import *
import subprocess
S = '/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad'
def apply007():
    r = subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', S + '/mig/007_kling_setup.sql'], capture_output=True, text=True)
    return r.returncode, r.stderr
sql("update public.system_settings set value_numeric = 50 where key = 'max_active_jobs'; update public.system_settings set value_numeric = 0 where key in ('video_driver_min_interval_seconds', 'video_poll_min_interval_seconds')")
rpc('set_text_setting', {"p_key": "storage_base_url", "p_value": "https://proj.supabase.co/storage/v1"})
rpc('set_text_setting', {"p_key": "notify_chat_id", "p_value": "123456"})

# before 007: the live situation
job0 = start('k-0'); plan(job0); g = voice(job0)
check('without a video model the job stops at gate 2', g['blocked_reason'] == 'VIDEO_PREREQUISITES_MISSING', str(g)[:200])
rpc('cancel_production_job', {"p_job_id": job0, "p_actor": "OWNER", "p_reason": "test"})

rc, err = apply007(); check('007 applies', rc == 0, err[:300])
check('writers are now told the durations Kling can make', json.loads(rpc('get_job_context', {"p_job_id": job0})['series_bible_text'])['format']['allowed_shot_durations_seconds'] == [5, 10])
check('pilot approval on record, no benchmark rows', one("select (select count(*) from public.generation_model_pilot_approvals where revoked_at is null)||'/'||(select count(*) from public.generation_model_benchmarks where benchmark_status = 'HUMAN_APPROVED')") == '1/0')
rc, out = subprocess.run(['psql', '-X', '-q', '-At', '-d', DB, '-c', "set role service_role; select public.approve_model_pilot('kling-2.6-std', 'X', 'x')"], capture_output=True, text=True).returncode, ''
check('the pilot approval cannot be given through the API role', rc != 0)

job = start('k-1'); plan(job); g = voice(job)
ep = one(f"select episode_id from public.production_jobs where id='{job}'")
ids = one(f"select string_agg(id::text, ',' order by shot_order) from public.shots where episode_id='{ep}'").split(',')
check('gate 2 passes with the pilot approval', g['passed'] is True and g['step_no'] == 22, str(g)[:300])
check('no video work while generation is off', actions() == [])
rpc('set_generation_enabled', {"p_enabled": True})
a = actions(); check('pilot shot first', [x['action'] for x in a] == ['ACQUIRE'] and a[0]['shot_id'] == ids[0], str(a)[:300])
total = 0.0
for n, sid in enumerate(ids):
    p = rpc('prepare_shot_attempt', {"p_shot_id": sid}); check(f'shot {n+1}: attempt authorised at Kling price', p['decision'] == 'AUTHORIZED' and abs(float(p['reserved_cost']) - 0.20) < 1e-9, str(p))
    s = [x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == sid][0]
    body = json.loads(s['provider_request_text'])
    if n == 0:
        check('request goes to PiAPI in its documented shape', s['provider'] == 'KLING' and s['submit_url'] == 'https://api.piapi.ai/api/v1/task' and body['model'] == 'kling' and body['task_type'] == 'video_generation' and body['input']['duration'] == 5 and body['input']['aspect_ratio'] == '9:16' and body['input']['version'] == '2.6' and body['input']['mode'] == 'std' and body['input']['enable_audio'] is False and 'prefer_multi_shots' not in body['input'] and len(body['input']['prompt']) > 40, json.dumps(body)[:400])
    c = rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True); assert c['decision'] == 'CLAIMED', c
    tid = f"6e269e8c-2091-46c4-b4a5-40a4704a76{n:02d}"
    resp = {"code": 200, "data": {"task_id": tid, "model": "kling", "task_type": "video_generation", "status": "pending", "config": {"service_mode": "public"}, "input": {}, "output": {"video_url": ""}, "meta": {}, "detail": None, "logs": [], "error": {"code": 0, "raw_message": "", "message": "", "detail": None}}, "message": "success"}
    r = rpc('record_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_provider_response": resp}); assert r['status'] == 'SUBMITTED' and r['provider_job_id'] == tid, r
    poll = [x for x in actions() if x['action'] == 'POLL' and x['attempt_id'] == s['attempt_id']][0]
    if n == 0: check('poll address', poll['poll_url'] == 'https://api.piapi.ai/api/v1/task/' + tid, poll['poll_url'])
    run = dict(resp); run['data'] = dict(resp['data'], status='processing')
    assert rpc('record_provider_poll', {"p_attempt_id": s['attempt_id'], "p_provider_response": run})['status'] == 'RUNNING'
    done = dict(resp); done['data'] = dict(resp['data'], status='completed', output={"video_url": f"https://storage.theapi.app/videos/{tid}.mp4"})
    r = rpc('record_provider_poll', {"p_attempt_id": s['attempt_id'], "p_provider_response": done}); assert r['status'] == 'SUCCEEDED', r
    out = [x for x in actions() if x['action'] == 'PROCESS_OUTPUT' and x['attempt_id'] == s['attempt_id']][0]
    if n == 0: check('download address is the video_url of the task', out['download_url'] == f"https://storage.theapi.app/videos/{tid}.mp4", out['download_url'])
    put(out['storage_path'], 3_000_000, 'video/mp4')
    gq = rpc('register_generation_output', {"p_attempt_id": s['attempt_id'], "p_storage_path": out['storage_path']})
    q = rpc('apply_visual_qc', {"p_output_id": gq['output_id'], "p_result": VISUAL_PASS}); check(f'shot {n+1} locked', q['shot_state'] == 'LOCKED', str(q))
acts = actions(); check('both shots done -> assembly', [x['action'] for x in acts] == ['ADVANCE'], str(acts)[:200]); rpc('ack_video_advance', {"p_job_id": job})
check('0.40 USD charged for two 5 s clips', abs(float(one("select settled_amount from public.budgets where budget_type='MONTHLY' and is_active")) - 0.40) < 1e-9, one("select settled_amount from public.budgets where budget_type='MONTHLY' and is_active"))
r = assemble(job); check('assembly, final QC and release pass on the Kling clips', r['step_no'] == 35, str(r)[:200])
pk = package(job); check('publish approval requested', pk['state'] == 'WAITING_HUMAN' and len(pk['token']) > 20, str(pk)[:200])

# a failed first attempt is retried with the same model (no fallback in the pilot policy)
job2 = start('k-2'); plan(job2); voice(job2)
ep2 = one(f"select episode_id from public.production_jobs where id='{job2}'"); s1 = one(f"select id from public.shots where episode_id='{ep2}' order by shot_order limit 1")
p = rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = [x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == s1][0]
rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
bad = {"code": 500, "data": None, "message": "insufficient credits"}
r = rpc('record_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_provider_response": bad}); check('refused submission costs nothing', r['status'] == 'FAILED' and float(one("select reserved_amount from public.budgets where budget_type='MONTHLY' and is_active")) == 0.0, str(r))
p2 = rpc('prepare_shot_attempt', {"p_shot_id": s1}); check('after a failure the model rests; the shot waits instead of blocking', p2['decision'] == 'WAITING_FOR_MODEL_HEALTH' and rpc('job_next_step', {"p_job_id": job2})['state'] == 'READY', str(p2))
sql("set session_replication_role = replica; update public.generation_model_health set last_checked_at = now() - interval '31 minutes'")
p3 = rpc('prepare_shot_attempt', {"p_shot_id": s1}); check('second attempt goes to Kling again', p3['decision'] == 'AUTHORIZED' and p3['attempt_no'] == 2, str(p3))
sql(f"update public.production_jobs set state = 'CANCELLED' where id = '{job2}'")

# revoking the pilot approval closes the door again
rv = json.loads(one("select public.revoke_model_pilot('kling-2.6-std', 'FATIH', 'test')")); check('revoked', rv['decision'] == 'REVOKED')
job3 = start('k-3'); plan(job3); g = voice(job3); check('without the approval a new job stops at gate 2', g['passed'] is False and g['blocked_reason'] == 'VIDEO_PREREQUISITES_MISSING', str(g)[:200])
summary()
