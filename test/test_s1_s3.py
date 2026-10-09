from lib import *
from fixtures import *
import json

# --- S1 --------------------------------------------------------------
expect_error('start refused while pipeline disabled', 'start_production_job',
             {"p_idempotency_key": "t-1", "p_series_code": "M417", "p_request": REQUEST}, 'PIPELINE_DISABLED')
sql("update public.system_flags set value = true where key = 'pipeline_enabled'")
expect_error('unknown series', 'start_production_job', {"p_idempotency_key": "t-x", "p_series_code": "NOPE", "p_request": REQUEST}, 'SERIES_NOT_FOUND')
expect_error('unknown profile', 'start_production_job', {"p_idempotency_key": "t-x", "p_series_code": "M417", "p_request": {**REQUEST, "creative_profile_code": "X"}}, 'LOCKED_CREATIVE_PROFILE_NOT_FOUND')
expect_error('missing budget', 'start_production_job', {"p_idempotency_key": "t-x", "p_series_code": "M417", "p_request": {"creative_profile_code": "MICRO_SHORT_PREMIUM_V1"}}, 'EPISODE_BUDGET_REQUIRED')
r = rpc('start_production_job', {"p_idempotency_key": "t-1", "p_series_code": "M417", "p_request": REQUEST})
job = r['job_id']
check('job created at step 5', r['decision'] == 'CREATED' and r['step_no'] == 5 and r['state'] == 'READY', str(r))
r2 = rpc('start_production_job', {"p_idempotency_key": "t-1", "p_series_code": "M417", "p_request": REQUEST})
check('same key returns same job', r2['job_id'] == job and r2['decision'] == 'EXISTING', str(r2))
expect_error('second job refused by active limit', 'start_production_job', {"p_idempotency_key": "t-2", "p_series_code": "M417", "p_request": REQUEST}, 'ACTIVE_JOB_LIMIT_REACHED')
check('episode in PREPRODUCTION', one(f"select state from public.episodes where id = '{r['episode_id']}'") == 'PREPRODUCTION')

r = rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 1})
check('gate 1 blocks without monthly budget', r['passed'] is False and r['state'] == 'BLOCKED' and r['blocked_reason'] == 'BUDGET_GATE_1_FAILED', str(r))
sql("insert into public.budgets (budget_type, hard_limit, is_active) values ('MONTHLY', 50, true)")
expect_error('blocked job cannot run gate', 'evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 1}, 'JOB_NOT_READY')
r = rpc('resume_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "budget added"}) if one("select to_regproc('public.resume_production_job') is not null") == 't' else None
if r is None:
    sql(f"update public.production_jobs set state='READY', blocked_reason=null where id='{job}'")
r = rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 1})
check('gate 1 passes', r['passed'] is True and r['step_no'] == 6, str(r))
r = rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 1})
check('gate 1 repeat is harmless', r['decision'] == 'ALREADY_PASSED' and r['step_no'] == 6, str(r))

# --- S2 --------------------------------------------------------------
r = rpc('job_next_step', {"p_job_id": job}); check('next step 6 READY', r['step_no'] == 6 and r['state'] == 'READY')
ctx = rpc('get_job_context', {"p_job_id": job})
bible = json.loads(ctx['series_bible_text'])
check('bible lists 5 characters', len(bible['characters']) == 5 and all(c['has_voice'] for c in bible['characters']))
check('bible lists 32 locations', len(bible['locations']) == 32)
check('context fields are text', all(isinstance(ctx[k], str) for k in ['series_bible_text', 'request_text', 'trend_report_text', 'topic_selection_text', 'script_text', 'shot_package_text', 'preqc_report_text', 'music_library_text', 'final_qc_report_text', 'policy_checks_text', 'metadata_candidates_text']))
check('empty artifacts are empty strings', ctx['trend_report_text'] == '' and ctx['music_library_text'] == '[]')

expect_error('wrong producer', 'save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "CLAUDE", "p_content": TREND}, 'PRODUCER_NOT_AUTHORIZED')
expect_error('out of order artifact', 'save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT}, 'STEP_MISMATCH')
expect_error('non-object content', 'save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": "text"}, 'MUST_BE_JSON_OBJECT')
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND}); check('trend saved -> 7', r['step_no'] == 7)
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC}); check('topic saved -> 8', r['step_no'] == 8)

r = rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_FAIL})
check('policy with HIGH finding fails despite PASS verdict', r['verdict'] == 'FAIL' and r['step_no'] == 7, str(r))
ctx = rpc('get_job_context', {"p_job_id": job}); check('rejected topic visible to topic selection', 'rejected_topics' in ctx['request_text'])
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
expect_error('wrong checker', 'record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "GROK", "p_result": POLICY_PASS}, 'NOT_AUTHORIZED')
r = rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS}); check('policy pass -> 9', r['step_no'] == 9)
r = rpc('get_series_bible', {"p_job_id": job}); check('bible -> 10', r['step_no'] == 10 and len(r['series_bible_text']) > 1000)

bad = json.loads(json.dumps(SCRIPT)); bad['scenes'][0]['dialogue'][0]['character'] = 'Jack'; bad['scenes'][1]['duration_seconds'] = 30
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": bad})
check('invalid script stays at 10 with issues', r['accepted'] is False and r['step_no'] == 10 and len(r['issues']) == 2, str(r)[:300])
ctx = rpc('get_job_context', {"p_job_id": job}); check('validation feedback reaches the writer', 'SYSTEM_VALIDATION' in ctx['preqc_report_text'] and 'Jack' in ctx['preqc_report_text'])
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT}); check('script saved -> 11', r['accepted'] and r['step_no'] == 11, str(r))
ctx = rpc('get_job_context', {"p_job_id": job}); check('feedback cleared after clean script', ctx['preqc_report_text'] == '' and ctx['shot_package_text'] == '')

badshots = shots(); badshots['shots'][1]['dialogue_line_nos'] = []; badshots['shots'][1]['beats'][0]['dialogue_line_nos'] = []; badshots['shots'][0]['characters'] = ['CHR_NOBODY', 'CHR_FATIH']
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": badshots})
check('invalid shots stay at 11', r['accepted'] is False and r['step_no'] == 11 and len(r['issues']) == 2, str(r)[:400])
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shots()}); check('shots saved -> 12', r['accepted'] and r['step_no'] == 12, str(r)[:300])
expect_error('bad preqc verdict', 'save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": {"verdict": "MAYBE"}}, 'PREQC_VERDICT_INVALID')
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_SHOTS}); check('preqc saved -> 13', r['step_no'] == 13)
r = rpc('route_revision', {"p_job_id": job}); check('revise shots -> 11', r['next_step'] == 11 and r['verdict'] == 'REVISE_SHOTS', str(r))
ctx = rpc('get_job_context', {"p_job_id": job}); check('preqc feedback reaches assistant director', 'framing unclear' in ctx['preqc_report_text'] and ctx['shot_package_text'] != '')
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shots()}); check('revised shots -> 12', r['step_no'] == 12)
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
r = rpc('route_revision', {"p_job_id": job}); check('pass -> 14', r['next_step'] == 14, str(r))

expect_error('director must be Claude', 'record_final_director_decision', {"p_job_id": job, "p_actor": "OPENAI", "p_result": DIRECTOR_APPROVE}, 'DIRECTOR_NOT_AUTHORIZED')
expect_error('approve contradicting own findings', 'record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": {**DIRECTOR_APPROVE, "child_safety_status": "FAIL"}}, 'CONTRADICTS')
r = rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": {"decision": "REVISE_SHOTS", "director_notes": "tighter", "required_changes": ["shot 2 closer"], "child_safety_status": "PASS", "production_ready": False}})
check('director revise -> 11 (2nd revision)', r['step_no'] == 11 and r['state'] == 'READY', str(r))
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shots()})
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
r = rpc('route_revision', {"p_job_id": job})
r = rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE}); check('director approve -> 15', r['step_no'] == 15, str(r))

r = rpc('commit_production_package', {"p_job_id": job})
check('commit -> 16 with 2 shots and 2 lines', r['step_no'] == 16 and r['shots'] == 2 and r['dialogue_lines'] == 2, str(r))
ep = one(f"select episode_id from public.production_jobs where id='{job}'")
check('episode in PRODUCTION, authorised by director, not by a human', one(f"select state||'/'||production_authorized||'/'||human_approved||'/'||(director_approval_id is not null) from public.episodes where id='{ep}'") == 'PRODUCTION/true/false/true')
check('manifest LOCKED without human flag', one(f"select status||'/'||human_approved||'/'||(director_approval_id is not null) from public.production_manifests where episode_id='{ep}'") == 'LOCKED/false/true')
check('specs LOCKED, 9:16, active', one(f"select count(*) from public.shot_specifications ss join public.shots s on s.id=ss.shot_id where s.episode_id='{ep}' and ss.status='LOCKED' and ss.is_active and ss.aspect_ratio='9:16' and ss.locked_at is not null") == '2')
check('shots STORYBOARD_APPROVED', one(f"select string_agg(state, ',' order by shot_order) from public.shots where episode_id='{ep}'") == 'STORYBOARD_APPROVED,STORYBOARD_APPROVED')
check('shot budgets created', one(f"select count(*) from public.budgets b join public.shots s on s.id=b.reference_id where b.budget_type='SHOT' and s.episode_id='{ep}' and b.hard_limit=3") == '2')
check('reference assets bound', one(f"select string_agg(n::text, ',' order by o) from (select s.shot_order o, count(*) n from public.shot_reference_assets sra join public.shot_specifications ss on ss.id=sra.shot_specification_id join public.shots s on s.id=ss.shot_id where s.episode_id='{ep}' group by 1) x") == '2,3')
check('prompt composed', 'Fatih' in one(f"select generation_prompt from public.shot_specifications ss join public.shots s on s.id=ss.shot_id where s.episode_id='{ep}' and s.shot_order=1"))
expect_error('commit twice', 'commit_production_package', {"p_job_id": job}, 'STEP_MISMATCH')

# --- S3 --------------------------------------------------------------
r = rpc('list_voice_work', {"p_job_id": job}); items = r['items']
check('2 voice items, GENERATE', len(items) == 2 and all(i['action'] == 'GENERATE' for i in items), str(r)[:400])
check('dialogue text is JSON-safe', all('"' not in i['text'] and '\n' not in i['text'] and '\\' not in i['text'] for i in items), str([i['text'] for i in items]))
check('fish voice ids present', all(len(i['voice_reference_id']) == 32 for i in items))
expect_error('register before upload', 'register_voice_take', {"p_line_id": items[0]['line_id'], "p_action": items[0]['action'], "p_storage_path": items[0]['storage_path'], "p_mp3_bitrate_kbps": 128}, 'VOICE_FILE_NOT_FOUND_IN_STORAGE')
check('first takes are asked for at normal speed', all(i['speed'] == 1 and '_T1_S100_' in i['storage_path'] for i in items), str([i['storage_path'] for i in items]))
# line 1: 6.5 seconds of audio in a 5 second shot -> fails, retake at a faster speed
put(items[0]['storage_path'], 104000)
t = rpc('register_voice_take', {"p_line_id": items[0]['line_id'], "p_action": "GENERATE", "p_storage_path": items[0]['storage_path'], "p_mp3_bitrate_kbps": 128})
check('duration from file size', abs(t['duration_seconds'] - 6.5) < 0.01, str(t))
q = rpc('apply_voice_qc', {"p_take_id": t['take_id'], "p_verdict": "PASS", "p_score": None})
check('too long take fails in the database', q['verdict'] == 'FAIL' and 'DIALOGUE_LONGER_THAN_SHOT' in q['reason'] and q['step_no'] == 16, str(q))
put(items[1]['storage_path'], 24000)
t2 = rpc('register_voice_take', {"p_line_id": items[1]['line_id'], "p_action": "GENERATE", "p_storage_path": items[1]['storage_path'], "p_mp3_bitrate_kbps": 128})
q = rpc('apply_voice_qc', {"p_take_id": t2['take_id'], "p_verdict": "PASS", "p_score": None}); check('good take passes, stage still open', q['verdict'] == 'PASS' and q['step_no'] == 16, str(q))
r = rpc('list_voice_work', {"p_job_id": job}); items = r['items']
check('one RETAKE item', len(items) == 1 and items[0]['action'] == 'RETAKE' and '_T2_' in items[0]['storage_path'], str(r)[:300])
check('the retake is asked to speak just fast enough to fit (6.5 s into 5.5 s)', items[0]['speed'] == 1.23 and '_T2_S123_' in items[0]['storage_path'], str(items[0]))
put(items[0]['storage_path'], 40000)
t = rpc('register_voice_take', {"p_line_id": items[0]['line_id'], "p_action": "RETAKE", "p_storage_path": items[0]['storage_path'], "p_mp3_bitrate_kbps": 128})
check('retake is take 2, speed on record', t['take_no'] == 2 and one(f"select timing_metadata->>'requested_speed' from public.shot_audio_productions where id='{t['take_id']}'") == '1.23')
q = rpc('apply_voice_qc', {"p_take_id": t['take_id'], "p_verdict": "PASS", "p_score": None}); check('all lines done -> 19', q['verdict'] == 'PASS' and q['step_no'] == 19, str(q))
check('shots AUDIO_READY', one(f"select string_agg(state, ',' order by shot_order) from public.shots where episode_id='{ep}'") == 'AUDIO_READY,AUDIO_READY')
r = rpc('list_voice_work', {"p_job_id": job}); check('no voice work after stage closed', r['items'] == [])
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "MUSIC_SFX_PLAN", "p_producer": "CLAUDE", "p_content": {"tracks": [{"track_code": "NOT_REAL", "role": "MUSIC", "start_seconds": 0, "end_seconds": 10, "volume": 0.2, "reason": ""}], "notes": ""}}); check('music plan -> 20', r['step_no'] == 20)
r = rpc('check_music_licenses', {"p_job_id": job}); check('unlicensed track dropped -> 21', r['step_no'] == 21 and r['accepted'] == [] and len(r['rejected']) == 1, str(r))
r = rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 2})
check('gate 2 blocks: video prerequisites missing', r['passed'] is False and r['blocked_reason'] == 'VIDEO_PREREQUISITES_MISSING', str(r))
print('job', job)
summary()
