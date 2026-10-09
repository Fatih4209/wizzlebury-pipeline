from flow import *
import copy

sql(open('seed_video.sql').read())
sql("update public.system_settings set value_numeric = 50 where key = 'max_active_jobs'")
sql("insert into public.budgets (budget_type, hard_limit, is_active) values ('MONTHLY', 500, true)")
rpc('set_generation_enabled', {"p_enabled": True})
rpc('set_text_setting', {"p_key": "storage_base_url", "p_value": "https://proj.supabase.co/storage/v1"})
rpc('set_text_setting', {"p_key": "notify_chat_id", "p_value": "123456"})
N = [0]
def new_job(shot_pkg=None, req=None):
    N[0] += 1
    job = start(f'p-{N[0]}', req); plan(job, shot_pkg); g = voice(job)
    ep = one(f"select episode_id from public.production_jobs where id='{job}'")
    ids = one(f"select string_agg(id::text, ',' order by shot_order) from public.shots where episode_id='{ep}'").split(',')
    return job, ep, ids, g
def mine(job, kind=None):
    return [a for a in actions() if a['job_id'] == job and (kind is None or a['action'] == kind)]
def park(job):
    """Take a finished test job out of the video queue."""
    sql(f"update public.production_jobs set state='CANCELLED' where id='{job}'")
def shot_state(sid): return one(f"select state from public.shots where id='{sid}'")
def reserved(): return one("select coalesce(sum(reserved_amount),0)::float from public.budgets")

# 1. both attempts fail QC -> owner accepts ---------------------------------
job, ep, (s1, s2), g = new_job()
run_shot(s1, VISUAL_FAIL); _, (_, out2, q) = run_shot(s1, VISUAL_FAIL)
check('two QC failures escalate', q['decision'] == 'ESCALATED' and shot_state(s1) == 'ESCALATED', str(q))
a = mine(job); check('only HUMAN_REVIEW is offered (no third attempt, shot 2 held behind pilot)', [x['action'] for x in a] == ['HUMAN_REVIEW'], str([x['action'] for x in a]))
hr = a[0]; check('review item carries clip path, chat id, base url, text', hr['storage_path'] == out2['storage_path'] and hr['notify_chat_id'] == '123456' and hr['storage_base_url'].startswith('https://') and 'SH01' in hr['review_text'] and 'extra arm' in hr['review_text'], str(hr)[:300])
p = rpc('prepare_shot_attempt', {"p_shot_id": s1}); check('no third paid attempt', p['decision'] == 'SHOT_NOT_READY', str(p))
ar = rpc('request_human_approval', {"p_scope_type": "SHOT_ESCALATION", "p_scope_id": s1, "p_requested_by": "MAKE_S4", "p_summary": {"job_id": job}}, obj=True)
check('with a pending review nothing is offered and nothing is pending', mine(job) == [] and rpc('video_work_pending')['pending'] is False)
h = rpc('handle_approval_link', {"p_token": ar['token'], "p_decision": "YES", "p_decided_by": "OWNER", "p_channel": "TELEGRAM_LINK"})
check('owner accepts the clip', h['outcome'] == 'APPROVED' and h['scope_type'] == 'SHOT_ESCALATION' and h['job_id'] == job and shot_state(s1) == 'LOCKED', str(h))
check('accepted clip is canonical with override recorded', one(f"select is_canonical||'/'||(qc_details ? 'human_override') from public.generation_outputs where shot_id='{s1}' and is_canonical") == 'true/true')
check('production continues with shot 2', [x['action'] for x in mine(job)] == ['ACQUIRE'] and mine(job)[0]['shot_id'] == s2)
park(job)

# 2. owner cancels the pilot -> job stops -----------------------------------
job, ep, (s1, s2), g = new_job()
run_shot(s1, VISUAL_FAIL); run_shot(s1, VISUAL_FAIL)
mine(job)
ar = rpc('request_human_approval', {"p_scope_type": "SHOT_ESCALATION", "p_scope_id": s1, "p_requested_by": "MAKE_S4", "p_summary": {}}, obj=True)
h = rpc('handle_approval_link', {"p_token": ar['token'], "p_decision": "NO", "p_decided_by": "OWNER", "p_channel": "TELEGRAM_LINK"})
check('owner cancels the shot', h['outcome'] == 'REJECTED' and shot_state(s1) == 'CANCELLED', str(h))
mine(job); st = rpc('job_next_step', {"p_job_id": job}); check('cancelled pilot blocks the job', st['state'] == 'BLOCKED' and st['blocked_reason'] == 'PILOT_SHOT_CANCELLED', str(st))
r = rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"}); check('job cancelled, episode cancelled', r['state'] == 'CANCELLED' and one(f"select state from public.episodes where id='{ep}'") == 'CANCELLED')

# 3. provider fails both generations -> no clip to review -> block ------------
job, ep, (s1, s2), g = new_job()
for n in (1, 2):
    a = mine(job, 'ACQUIRE')[0]; p = rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = mine(job, 'SUBMIT')[0]
    submit_and_finish(s, None, fail_generation=True)
check('failed generations are not charged', one(f"select string_agg(entry_type||':'||n, ',' order by entry_type) from (select entry_type, count(*) n from public.cost_ledger where episode_id='{ep}' group by 1) x") == 'RELEASE:2,RESERVE:2' and reserved() == '0')
check('shot escalated after two technical failures', shot_state(s1) == 'ESCALATED')
mine(job); st = rpc('job_next_step', {"p_job_id": job}); check('no clip -> job blocked for the owner', st['blocked_reason'] == 'SHOT_FAILED_WITHOUT_OUTPUT', str(st))
park(job)

# 4. submission rejected by the provider -------------------------------------
job, ep, (s1, s2), g = new_job()
mine(job); rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = mine(job, 'SUBMIT')[0]
rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
c2 = rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True); check('second claim is refused', c2['decision'] == 'ALREADY_CLAIMED')
r = rpc('record_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_provider_response": {"code": 400, "data": None, "message": "insufficient credits"}})
check('rejected submission releases the reservation', r['status'] == 'FAILED' and reserved() == '0' and shot_state(s1) == 'RETRY_REQUIRED', str(r))
check('model marked degraded from real traffic', one("select h.availability_status from public.generation_model_health h join public.generation_models m on m.id=h.model_id where m.model_code='kling-std'") == 'DEGRADED')
# attempt 2 goes to the fallback; then the stale-claim path
mine(job); p = rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = mine(job, 'SUBMIT')[0]; check('retry routed to fallback', s['provider'] == 'VEO')
rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
check('fresh claim: nothing to do but wait', mine(job) == [] and rpc('video_work_pending')['pending'] is True)
for i in range(2):
    sql(f"update public.attempts set submission_claimed_at = now() - interval '10 minutes' where id = '{s['attempt_id']}'")
    a = mine(job); check(f'stale claim {i+1} -> RECONCILE', [x['action'] for x in a] == ['RECONCILE'], str(a)[:200])
    rpc('reset_attempt_submission_claim', {"p_attempt_id": s['attempt_id'], "p_actor": "MAKE_S4", "p_reason": "stale claim without provider job id"})
    check('after reset the submission is offered again', [x['action'] for x in mine(job)] == ['SUBMIT'])
    rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
sql(f"update public.attempts set submission_claimed_at = now() - interval '10 minutes' where id = '{s['attempt_id']}'")
check('third stale claim: attempt given up, reservation released', mine(job) == [] and one(f"select status||'/'||error_code from public.attempts where id='{s['attempt_id']}'") == 'FAILED/SUBMISSION_FAILED_REPEATEDLY' and reserved() == '0')
park(job)
sql("set session_replication_role = replica; update public.generation_model_health set availability_status='AVAILABLE', last_checked_at=now(); set session_replication_role = origin;")

# 5. provider timeout ---------------------------------------------------------
job, ep, (s1, s2), g = new_job()
mine(job); rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = mine(job, 'SUBMIT')[0]
rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
rpc('record_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_provider_response": {"code": 200, "data": {"task_id": "slow-1"}}})
sql(f"update public.attempts set started_at = now() - interval '2 hours' where id = '{s['attempt_id']}'")
check('timeout is visible as pending work', rpc('video_work_pending')['pending'] is True)
mine(job)
check('timed out attempt failed with a CRITICAL event', one(f"select status||'/'||error_code from public.attempts where id='{s['attempt_id']}'") == 'FAILED/PROVIDER_TIMEOUT' and one(f"select count(*) from public.events where attempt_id='{s['attempt_id']}' and event_type='VIDEO_PROVIDER_TIMEOUT' and severity='CRITICAL'") == '1')
park(job)
sql("set session_replication_role = replica; update public.generation_model_health set availability_status='AVAILABLE', last_checked_at=now(); set session_replication_role = origin;")

# 6. technical QC: tiny file ---------------------------------------------------
job, ep, (s1, s2), g = new_job()
mine(job); rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = mine(job, 'SUBMIT')[0]
rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
rpc('record_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_provider_response": {"code": 200, "data": {"task_id": "tq-1"}}})
rpc('record_provider_poll', {"p_attempt_id": s['attempt_id'], "p_provider_response": {"code": 200, "data": {"status": "Completed", "output": {"video_url": "https://cdn.example/v.mp4"}}}})
o = mine(job, 'PROCESS_OUTPUT')[0]
expect_error('output must be in storage before it is registered', 'register_generation_output', {"p_attempt_id": s['attempt_id'], "p_storage_path": o['storage_path']}, 'OUTPUT_FILE_NOT_FOUND_IN_STORAGE')
put(o['storage_path'], 500, 'video/mp4')
r = rpc('register_generation_output', {"p_attempt_id": s['attempt_id'], "p_storage_path": o['storage_path']})
check('tiny file fails technical QC without calling Gemini', r['technical_qc'] == 'FAIL' and shot_state(s1) == 'RETRY_REQUIRED', str(r))
r = rpc('register_generation_output', {"p_attempt_id": s['attempt_id'], "p_storage_path": o['storage_path']}); check('repeat is harmless', r['technical_qc'] == 'ALREADY_REVIEWED')
park(job)

# 7. Make dies between upload and QC: PROCESS_OUTPUT is offered again with a new path
job, ep, (s1, s2), g = new_job()
mine(job); rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = mine(job, 'SUBMIT')[0]
rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
rpc('record_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_provider_response": {"code": 200, "data": {"task_id": "rp-1"}}})
rpc('record_provider_poll', {"p_attempt_id": s['attempt_id'], "p_provider_response": {"code": 200, "data": {"status": "completed", "output": {"video_url": "https://cdn.example/v.mp4"}}}})
o1 = mine(job, 'PROCESS_OUTPUT')[0]; put(o1['storage_path'], 3_000_000, 'video/mp4')
g1 = rpc('register_generation_output', {"p_attempt_id": s['attempt_id'], "p_storage_path": o1['storage_path']})
o2 = mine(job, 'PROCESS_OUTPUT')[0]; check('offered again with a different path', o2['storage_path'] != o1['storage_path'])
put(o2['storage_path'], 3_000_000, 'video/mp4')
g2 = rpc('register_generation_output', {"p_attempt_id": s['attempt_id'], "p_storage_path": o2['storage_path']})
check('same output row, new path', g2['output_id'] == g1['output_id'] and g2['technical_qc'] == 'PASS' and one(f"select storage_path from public.generation_outputs where id='{g1['output_id']}'") == o2['storage_path'])
q = rpc('apply_visual_qc', {"p_output_id": g2['output_id'], "p_result": VISUAL_PASS}); check('then locked', q['shot_state'] == 'LOCKED')
park(job)

# 8. revision limit, resume -----------------------------------------------------
N[0] += 1; job = start(f'p-{N[0]}')
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
for i in range(3):
    r = rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_FAIL})
    if i < 2: rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
check('third unsafe topic blocks the job', r['state'] == 'BLOCKED' and r['blocked_reason'] == 'POLICY_GATE_1_FAILED', str(r))
r = rpc('resume_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "new brief"}); check('resume returns the link to continue', r['decision'] == 'RESUMED' and r['state'] == 'READY' and r['resume_url'].startswith('https://hook.eu1.make.com/oxy1') and r['resume_url'].endswith('?job_id=' + job), str(r))
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS}); rpc('get_series_bible', {"p_job_id": job})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shots()})
for i in range(3):
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_SCRIPT})
    r = rpc('route_revision', {"p_job_id": job})
    if r['state'] != 'READY': break
    check(f'script revision {i+1} goes back to step 10', r['next_step'] == 10)
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shots()})
check('third revision request blocks the job', r['state'] == 'BLOCKED' and r['blocked_reason'] == 'REVISION_LIMIT_REACHED', str(r))
m = rpc('daily_maintenance'); check('maintenance reports the blocked job', m['has_issues'] and 'REVISION_LIMIT_REACHED' in m['message_text'] and m['notify_chat_id'] == '123456', m['message_text'][:300])
rpc('resume_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "one more round"})
r = rpc('route_revision', {"p_job_id": job}); check('resumed job re-reads the report and reopens the script', r['next_step'] == 10 and r['state'] == 'READY', str(r))
# director rejects
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shots()})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS}); rpc('route_revision', {"p_job_id": job})
expect_error('director cannot approve over a failed pre-QC', 'record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": {"decision": "MAYBE"}}, 'DIRECTOR_DECISION_INVALID')
r = rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": {"decision": "REJECT", "director_notes": "topic cannot work", "required_changes": [], "child_safety_status": "PASS", "production_ready": False}})
ep = one(f"select episode_id from public.production_jobs where id='{job}'")
check('director reject cancels job and episode', r['state'] == 'CANCELLED' and one(f"select state from public.episodes where id='{ep}'") == 'CANCELLED', str(r))
expect_error('decision record cannot be edited', 'set_text_setting', {"p_key": "nope", "p_value": "x"}, 'UNKNOWN_TEXT_SETTING')
try:
    sql("update public.director_decisions set decision = 'APPROVE'"); check('director decisions are append-only', False)
except RpcError as e: check('director decisions are append-only', 'APPEND_ONLY' in str(e), str(e))

# 9. voice take limit --------------------------------------------------------------
def sh01_line(job): return [x for x in rpc('list_voice_work', {"p_job_id": job})['items'] if '_L1_' in x['storage_path'] and 'SH01' in x['storage_path']][0]
def take(job, size, verdict='PASS'):
    it = sh01_line(job); put(it['storage_path'], size)
    t = rpc('register_voice_take', {"p_line_id": it['line_id'], "p_action": it['action'], "p_storage_path": it['storage_path'], "p_mp3_bitrate_kbps": 128})
    return it, rpc('apply_voice_qc', {"p_take_id": t['take_id'], "p_verdict": verdict, "p_score": None})
N[0] += 1; job = start(f'p-{N[0]}'); plan(job)
for i in range(3):
    it, q = take(job, 40000, 'FAIL')
check('third take rejected by the reviewer blocks the job', q['state'] == 'BLOCKED' and q['blocked_reason'] == 'VOICE_TAKE_LIMIT_REACHED' and '_T3_S100_' in it['storage_path'], str(q))
check('blocked job offers no voice work', rpc('list_voice_work', {"p_job_id": job})['items'] == [])
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 9b. a line far too long for its shot: no retake is paid for -----------------------
N[0] += 1; job = start(f'p-{N[0]}'); plan(job)
it, q = take(job, 200000)      # 12.5 s in a 5 s shot
check('hopeless line blocks after ONE take', q['state'] == 'BLOCKED' and q['blocked_reason'] == 'DIALOGUE_DOES_NOT_FIT_SHOT' and 'faster than 1.3x' in q['blocked_detail'] and one(f"select count(*) from public.shot_audio_productions sap join public.shot_specifications ss on ss.id = sap.shot_specification_id join public.shots s on s.id = ss.shot_id join public.production_jobs j on j.episode_id = s.episode_id where j.id='{job}' and s.shot_code='SH01' and sap.status = 'REJECTED'") == '1', str(q))
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 9c. the faster retake still does not fit (speed ignored by the caller) -------------
N[0] += 1; job = start(f'p-{N[0]}'); plan(job)
it, q = take(job, 104000)      # 6.5 s -> retake at 1.23x
check('first long take leaves the job open', q['state'] == 'READY' and q['verdict'] == 'FAIL', str(q))
it, q = take(job, 104000)      # the retake comes back just as long
check('a retake that did not get shorter stops the line (2 takes, not 3)', '_T2_S123_' in it['storage_path'] and q['state'] == 'BLOCKED' and q['blocked_reason'] == 'DIALOGUE_DOES_NOT_FIT_SHOT' and 'still 6.50 s after a retake at 1.23x; 5.50 s are available' in q['blocked_detail'], str(q))
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 9d. lines are measured before any voice is paid for --------------------------------
N[0] += 1; job = start(f'p-{N[0]}')
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS})
b = rpc('get_series_bible', {"p_job_id": job})
rule = json.loads(b['series_bible_text'])['format']['dialogue_timing_rule']
check('writers are told the speech-time rule with real numbers', '13 characters' in rule and '2 s holds 20 characters' in rule and '5 s holds 59' in rule and 'plus 0.5 s for every sentence break' in rule, rule)
LONG = copy.deepcopy(SCRIPT); LONG['scenes'][0]['dialogue'][0]['text'] = 'This kite has completely made up its own mind and it is never ever coming back down to us!'
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": LONG})
check('script with a line too long for its scene is sent back', r['accepted'] is False and r['step_no'] == 10 and any('takes about 7.32 s to say, but the scene lasts 5 s' in i['detail'] and 'at most 59 characters' in i['fix'] for i in r['issues']), str(r)[:500])
OK2 = copy.deepcopy(SCRIPT); OK2['total_duration_seconds'] = 15; OK2['scenes'][0]['duration_seconds'] = 10
OK2['scenes'][0]['dialogue'] = [{"line_no": 1, "character": "CHR_FATIH", "text": "It is alive, Mia! Quick, catch it before it lands!!", "emotion": "excited", "estimated_seconds": 2}, {"line_no": 2, "character": "CHR_MIA", "text": "I am trying, Fatih, but it keeps diving at my head!", "emotion": "excited", "estimated_seconds": 2}]
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": OK2}); check('script whose lines fit their scene is accepted', r['accepted'] is True and r['step_no'] == 11, str(r)[:300])
def sh(i, **kw):
    x = copy.deepcopy(shots()['shots'][i])
    for bt in x['beats']: bt['dialogue_line_nos'] = []
    x.update(kw); return x
pkg = {"shots": [sh(0, dialogue_line_nos=[1, 2], characters=["CHR_FATIH", "CHR_MIA"]),
                 sh(0, shot_no=2, dialogue_line_nos=[], characters=["CHR_FATIH", "CHR_MIA"]),
                 dict(shots()['shots'][1], shot_no=3)], "hook": "A red kite dives straight at the camera.", "total_duration_seconds": 15, "continuity_risks": []}
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": pkg})
check('shot too short for the lines spoken in it is sent back', r['accepted'] is False and r['step_no'] == 11 and len(r['issues']) == 1 and r['issues'][0]['ref'] == 'shot 1' and 'take about 9.14 s to say, but the shot lasts 5 s' in r['issues'][0]['detail'] and 'at least 9 s' in r['issues'][0]['fix'], str(r)[:500])
pkg['shots'][0]['dialogue_line_nos'] = [1]; pkg['shots'][1]['dialogue_line_nos'] = [2]
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": pkg})
check('one line per shot fits and is accepted', r['accepted'] is True and r['step_no'] == 12, str(r)[:400])
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 10. take registered but QC call never arrived -------------------------------------
N[0] += 1; job = start(f'p-{N[0]}'); plan(job)
items = rpc('list_voice_work', {"p_job_id": job})['items']
for it in items:
    put(it['storage_path'], 24000)
    rpc('register_voice_take', {"p_line_id": it['line_id'], "p_action": it['action'], "p_storage_path": it['storage_path'], "p_mp3_bitrate_kbps": 128})
r = rpc('list_voice_work', {"p_job_id": job}); check('pending QC is settled on the next pass and the stage closes', r['items'] == [] and r['step_no'] == 19, str(r))
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 11. budgets ------------------------------------------------------------------------
job, ep, ids, g = new_job(req={**REQUEST, "shot_budget_usd": 0.1})
check('gate 2 blocks when a shot cannot be afforded', g['passed'] is False and g['blocked_reason'] == 'BUDGET_GATE_2_FAILED' and 'SHOT_BUDGET_TOO_LOW' in g['blocked_detail'], str(g)[:300])
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})
job, ep, (s1, s2), g = new_job()
sql("update public.budgets set hard_limit = settled_amount + 0.10 where budget_type = 'MONTHLY'")
mine(job); p = rpc('prepare_shot_attempt', {"p_shot_id": s1})
check('acquisition refused when the month is spent; job blocked, nothing reserved', p['decision'] == 'BLOCKED' and p['reason'] == 'MONTHLY_BUDGET_EXCEEDED' and reserved() == '0' and rpc('job_next_step', {"p_job_id": job})['blocked_reason'] == 'VIDEO_ATTEMPT_REFUSED', str(p))
sql("update public.budgets set hard_limit = 500 where budget_type = 'MONTHLY'")
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 12. render failures and owner rejection ---------------------------------------------
job, ep, ids, g = new_job(); video_all_pass(job)
rpc('select_final_audio_track', {"p_job_id": job})
for n in (1, 2):
    b = rpc('begin_assembly', {"p_job_id": job}); c = rpc('create_render', {"p_job_id": job, "p_signed_urls": sign(b['sign_request_text'])})
    rpc('mark_render_submitted', {"p_render_id": c['render_id'], "p_shotstack_render_id": f"f-{n}-{job[:6]}"})
    d = rpc('record_render_poll', {"p_render_id": c['render_id'], "p_status": "failed", "p_output_url": ""}); check(f'render {n} failed', d['status'] == 'FAILED')
b = rpc('begin_assembly', {"p_job_id": job}); check('after two failed renders the job is blocked', b['phase'] == 'BLOCKED' and rpc('job_next_step', {"p_job_id": job})['blocked_reason'] == 'RENDER_LIMIT_REACHED', str(b))
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

job, ep, ids, g = new_job(); video_all_pass(job); assemble(job); ap = package(job)
sql(f"update public.production_jobs set last_activity_at = now() - interval '30 hours' where id = '{job}'")
m = rpc('daily_maintenance'); check('maintenance reminds about a waiting approval', 'yayın onayını bekliyor' in m['message_text'], m['message_text'][:300])
h = rpc('handle_approval_link', {"p_token": ap['token'], "p_decision": "NO", "p_decided_by": "OWNER", "p_channel": "TELEGRAM_LINK"})
check('owner rejects publication', h['outcome'] == 'REJECTED' and h['scope_type'] == 'PUBLICATION' and rpc('job_next_step', {"p_job_id": job})['blocked_reason'] == 'PUBLISH_REJECTED_BY_OWNER', str(h))
expect_error('nothing can be published after a rejection', 'claim_publication', {"p_job_id": job}, 'JOB_NOT_READY')
check('episode stays unpublished', one(f"select state from public.episodes where id='{ep}'") == 'READY_TO_PUBLISH')
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 13. expired approval link -> new link ------------------------------------------------
job, ep, ids, g = new_job(); video_all_pass(job); assemble(job); ap = package(job)
sql("set session_replication_role = replica; update public.approval_requests set expires_at = now() - interval '1 hour' where status = 'PENDING'; set session_replication_role = origin;")
h = rpc('handle_approval_link', {"p_token": ap['token'], "p_decision": "YES", "p_decided_by": "OWNER", "p_channel": "TELEGRAM_LINK"}); check('expired link does not approve', h['outcome'] == 'EXPIRED', str(h))
m = rpc('daily_maintenance'); check('maintenance closes the link and says so', 'süresi doldu' in m['message_text'] and 'geçerli bir onay bağlantısı kalmadı' in m['message_text'], m['message_text'][:400])
r = rpc('resume_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "resend approval"}); check('resume points at S7', '/tlxyim3' in r['resume_url'])
ap2 = rpc('request_publish_approval', {"p_job_id": job}); h = rpc('handle_approval_link', {"p_token": ap2['token'], "p_decision": "YES", "p_decided_by": "OWNER", "p_channel": "TELEGRAM_LINK"})
check('new link approves', h['outcome'] == 'APPROVED')
c = rpc('claim_publication', {"p_job_id": job})
r = rpc('reset_publication_claim', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "upload failed"}); c2 = rpc('claim_publication', {"p_job_id": job})
check('a failed upload can be retried after an explicit reset', r['decision'] == 'CLAIM_RESET' and c2['decision'] == 'CLAIMED' and c2['publication_id'] != c['publication_id'])
rpc('record_publication', {"p_publication_id": c2['publication_id'], "p_video_id": "vid-" + job[:6], "p_url": "", "p_status": "PUBLISHED"})
check('url defaults from the video id', one(f"select url from public.publications where job_id='{job}'") == 'https://www.youtube.com/watch?v=vid-' + job[:6])
expect_error('published job cannot be cancelled into a lie', 'reset_publication_claim', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "x"}, 'PUBLICATION_ALREADY_PUBLISHED')

# 14. episode without dialogue ----------------------------------------------------------
silent = copy.deepcopy(SCRIPT)
for sc in silent['scenes']: sc['dialogue'] = []
N[0] += 1; job = start(f'p-{N[0]}')
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS}); rpc('get_series_bible', {"p_job_id": job})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": silent})
sp = shots(10, 5); sp['shots'][0]['dialogue_line_nos'] = []; sp['shots'][1]['dialogue_line_nos'] = []
for _s in sp['shots']:
    for _b in _s['beats']: _b['dialogue_line_nos'] = []
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": sp})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS}); rpc('route_revision', {"p_job_id": job})
rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
r = rpc('commit_production_package', {"p_job_id": job}); check('silent episode skips the voice stage', r['step_no'] == 19 and r['dialogue_lines'] == 0, str(r))
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "MUSIC_SFX_PLAN", "p_producer": "CLAUDE", "p_content": MUSIC_EMPTY}); rpc('check_music_licenses', {"p_job_id": job})
g = rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 2}); check('silent 15 s episode passes gate 2', g['passed'] and g['estimated_video_cost'] == 0.75, str(g))
ep = one(f"select episode_id from public.production_jobs where id='{job}'"); sid = one(f"select id from public.shots where episode_id='{ep}' and shot_order=1")
_, (_, _, q) = run_shot(sid); check('shot without dialogue generates from STORYBOARD_APPROVED', q['shot_state'] == 'LOCKED')
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 15. licensed music reaches the edit ----------------------------------------------------
put('M417/music/happy.mp3', 900000)
expect_error('track file must exist', 'register_music_track', {"p_track_code": "HAPPY_1", "p_title": "Happy", "p_role": "MUSIC", "p_storage_path": "M417/music/missing.mp3", "p_license_type": "YouTube Audio Library", "p_verified_by": "OWNER"}, 'TRACK_FILE_NOT_FOUND_IN_STORAGE')
rpc('register_music_track', {"p_track_code": "HAPPY_1", "p_title": "Happy", "p_role": "MUSIC", "p_storage_path": "M417/music/happy.mp3", "p_license_type": "YouTube Audio Library", "p_verified_by": "OWNER"})
N[0] += 1; job = start(f'p-{N[0]}'); plan(job)
check('library visible to the music planner', 'HAPPY_1' in rpc('get_job_context', {"p_job_id": job})['music_library_text'])
while True:
    batch = rpc('list_voice_work', {"p_job_id": job})['items']
    if not batch: break
    for it in batch:
        put(it['storage_path'], 24000); t = rpc('register_voice_take', {"p_line_id": it['line_id'], "p_action": it['action'], "p_storage_path": it['storage_path'], "p_mp3_bitrate_kbps": 128}); rpc('apply_voice_qc', {"p_take_id": t['take_id'], "p_verdict": "PASS", "p_score": None})
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "MUSIC_SFX_PLAN", "p_producer": "CLAUDE", "p_content": {"tracks": [{"track_code": "happy_1", "role": "MUSIC", "start_seconds": 0, "end_seconds": 10, "volume": 0.2, "reason": ""}, {"track_code": "STOLEN", "role": "MUSIC", "start_seconds": 0, "end_seconds": 10, "volume": 0.2, "reason": ""}], "notes": ""}})
r = rpc('check_music_licenses', {"p_job_id": job}); check('licensed track accepted, unknown track dropped', r['accepted'] == ['HAPPY_1'] and len(r['rejected']) == 1, str(r))
rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 2}); video_all_pass(job); rpc('select_final_audio_track', {"p_job_id": job})
b = rpc('begin_assembly', {"p_job_id": job}); c = rpc('create_render', {"p_job_id": job, "p_signed_urls": sign(b['sign_request_text'])}); tl = json.loads(c['shotstack_request_text'])
check('soundtrack in the timeline at the planned volume', tl['timeline']['soundtrack']['volume'] == 0.2 and 'M417/music/happy.mp3' in tl['timeline']['soundtrack']['src'] and len(json.loads(b['sign_request_text'])['paths']) == 5, str(tl['timeline'].get('soundtrack')))
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 16. kill switches ------------------------------------------------------------------------
job, ep, (s1, s2), g = new_job()
rpc('set_pipeline_enabled', {"p_enabled": False})
st = rpc('job_next_step', {"p_job_id": job}); check('pipeline off: scenarios see BLOCKED', st['state'] == 'BLOCKED' and st['blocked_reason'] == 'PIPELINE_DISABLED')
check('pipeline off: no video work', actions() == [] and rpc('video_work_pending')['pending'] is False)
expect_error('pipeline off: steps refuse', 'select_final_audio_track', {"p_job_id": job}, 'PIPELINE_DISABLED')
rpc('set_pipeline_enabled', {"p_enabled": True})
check('pipeline on again: job unchanged', rpc('job_next_step', {"p_job_id": job})['state'] == 'READY')
sql("update public.system_settings set value_numeric = 90 where key = 'video_driver_min_interval_seconds'; update public.video_driver_state set last_tick_at = null")
a = rpc('video_work_pending'); b = rpc('video_work_pending'); check('a second driver loop stops itself', a['pending'] is True and b['pending'] is False and b['reason'] == 'ANOTHER_DRIVER_ACTIVE', str(b))
sql("update public.system_settings set value_numeric = 0 where key = 'video_driver_min_interval_seconds'")
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 17. lip-sync is not generated, so it does not fail a clip or an edit ------------------------
LIP_ONLY = copy.deepcopy(VISUAL_PASS); LIP_ONLY['verdict'] = 'FAIL'; LIP_ONLY['details']['lip_sync'] = 'FAIL'; LIP_ONLY['notes'] = 'mouth does not match'
job, ep, (s1, s2), g = new_job()
s, (_, out, q) = run_shot(s1, LIP_ONLY)
check('clip failing on lip-sync alone is accepted', shot_state(s1) == 'LOCKED' and q['qc_status'] == 'PASS', str(q))
check('the reviewer is not given dialogue to lip-read', json.loads(out['qc_context_text']).get('dialogue') is None, out['qc_context_text'][:200])
check('the original verdict stays on record', 'lip-sync is not enforced' in one(f"select qc_notes from public.generation_outputs where shot_id='{s1}'"))
LIP_PLUS = copy.deepcopy(LIP_ONLY); LIP_PLUS['details']['anatomy'] = 'FAIL'
s, (_, out, q) = run_shot(s2, LIP_PLUS)
check('lip-sync plus a real defect still fails', shot_state(s2) == 'RETRY_REQUIRED', str(q))
run_shot(s2)
assert [a['action'] for a in mine(job)] == ['ADVANCE']; rpc('ack_video_advance', {"p_job_id": job})
FLIP = copy.deepcopy(FINAL_PASS); FLIP['verdict'] = 'FAIL'; FLIP['score'] = 0.55; FLIP['details']['lip_sync'] = 'FAIL'
r = assemble(job, FLIP)
check('edit failing on lip-sync alone goes on to the owner', r['step_no'] >= 35 and r['state'] == 'READY', str(r))
check('render keeps the reviewer verdict, score and a system note', one(f"select (qc_result->>'reviewer_verdict')||'/'||qc_verdict||'/'||qc_score||'/'||(qc_result ? 'system_note') from public.renders r join public.production_jobs j on j.id = r.job_id where j.id='{job}'") == 'FAIL/PASS/55.00/true')
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})
sql("update public.system_flags set value = true where key = 'lip_sync_enforced'")
job, ep, (s1, s2), g = new_job()
s, (_, out, q) = run_shot(s1, LIP_ONLY)
check('with lip-sync enforced the same clip fails', shot_state(s1) == 'RETRY_REQUIRED' and json.loads(out['qc_context_text']).get('dialogue') is not None, str(q))
sql("update public.system_flags set value = false where key = 'lip_sync_enforced'")
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# 18. every model failed a moment ago -> wait, do not block ---------------------------------
job, ep, (s1, s2), g = new_job()
sql("select public.record_generation_model_health(gpm.model_id, 'UNAVAILABLE', 'PROVIDER_RESPONSE', 'test outage') from public.generation_policy_models gpm join public.generation_routing_policies p on p.id = gpm.policy_id where p.status = 'ACTIVE'")
p1 = rpc('prepare_shot_attempt', {"p_shot_id": s1}); p2 = rpc('prepare_shot_attempt', {"p_shot_id": s1})
check('outage: the shot waits', p1['decision'] == 'WAITING_FOR_MODEL_HEALTH' and p2['decision'] == 'WAITING_FOR_MODEL_HEALTH', str(p1))
check('outage: job not blocked, nothing reserved, no attempt', rpc('job_next_step', {"p_job_id": job})['state'] == 'READY' and one(f"select count(*) from public.attempts where shot_id='{s1}'") == '0' and [x['action'] for x in mine(job)] == ['ACQUIRE'])
check('outage: no routing rows pile up while waiting', one(f"select count(*) from public.generation_routing_decisions where shot_id='{s1}'") == '0')
sql("set session_replication_role = replica; update public.generation_model_health set last_checked_at = now() - interval '31 minutes'")
p3 = rpc('prepare_shot_attempt', {"p_shot_id": s1})
check('after the cooldown the shot goes ahead', p3['decision'] == 'AUTHORIZED', str(p3))
expect_error('a job with a live paid attempt cannot be cancelled', 'cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"}, 'JOB_HAS_ACTIVE_VIDEO_ATTEMPTS')
rpc('release_generation_attempt_v2', {"p_attempt_id": p3['attempt_id'], "p_failure_status": "CANCELLED"}, obj=True) if False else park(job)

# 19. monthly budget -------------------------------------------------------------------------
expect_error('limit required', 'open_monthly_budget', {"p_hard_limit_usd": 0, "p_actor": "OWNER"}, 'HARD_LIMIT_REQUIRED')
spent = float(one("select coalesce(sum(amount),0) from public.cost_ledger where entry_type='SETTLE'"))
expect_error('a budget with money on hold is not replaced', 'open_monthly_budget', {"p_hard_limit_usd": 40, "p_actor": "OWNER"}, 'MONTHLY_BUDGET_HAS_OPEN_RESERVATIONS')
sql("update public.budgets set reserved_amount = 0 where budget_type = 'MONTHLY'")
expect_error('limit below what was already charged this month', 'open_monthly_budget', {"p_hard_limit_usd": 0.01, "p_actor": "OWNER"}, 'LIMIT_BELOW_SPEND_THIS_MONTH')
r = rpc('open_monthly_budget', {"p_hard_limit_usd": 40, "p_actor": "OWNER"})
check('one active monthly budget, this calendar month, carrying what was already charged',
      one("select count(*)||'/'||max(hard_limit)::float||'/'||(max(period_start) = date_trunc('month', now() at time zone 'UTC') at time zone 'UTC')||'/'||(max(period_end) > now()) from public.budgets where budget_type='MONTHLY' and is_active") == '1/40/true/true'
      and abs(float(r['already_charged_usd']) - spent) < 0.001 and spent > 0, str(r))
check('overview shows the new budget', abs(float(rpc('pipeline_overview')['monthly_budget']['available']) - (40 - spent)) < 0.001)
sql("update public.budgets set period_end = now() - interval '1 second', period_start = now() - interval '1 month' where budget_type='MONTHLY' and is_active")
check('month over: maintenance says so', 'aylık bütçe yok' in json.dumps(rpc('daily_maintenance'), ensure_ascii=False))
mj = rpc('start_production_job', {"p_idempotency_key": "p-month", "p_series_code": "M417", "p_request": REQUEST})['job_id']
mg = rpc('evaluate_budget_gate', {"p_job_id": mj, "p_gate_no": 1})
check('month over: a new episode stops at the budget gate before any paid call', mg['state'] == 'BLOCKED' and 'BUDGET' in str(mg.get('blocked_reason')), str(mg))
rpc('open_monthly_budget', {"p_hard_limit_usd": 40, "p_actor": "OWNER"})
summary()
