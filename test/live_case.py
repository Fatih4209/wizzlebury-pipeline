from flow import *
import subprocess, sys
S='/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad'
job = start('live-1'); plan(job)
for i in range(3):
    it = [x for x in rpc('list_voice_work', {"p_job_id": job})['items'] if 'SH01' in x['storage_path']][0]
    put(it['storage_path'], 120000)
    t = rpc('register_voice_take', {"p_line_id": it['line_id'], "p_action": it['action'], "p_storage_path": it['storage_path'], "p_mp3_bitrate_kbps": 128})
    q = rpc('apply_voice_qc', {"p_take_id": t['take_id'], "p_verdict": "PASS", "p_score": None})
check('old code: blocked after three identical takes', q['blocked_reason'] == 'VOICE_TAKE_LIMIT_REACHED', str(q))
r = subprocess.run(['psql','-X','-q','-v','ON_ERROR_STOP=1','-d','m417','-f',S+'/mig/003_dialogue_timing.sql'], capture_output=True, text=True)
check('003 applies with a blocked job present', r.returncode == 0, r.stderr[:300])
o = rpc('pipeline_overview'); check('job still blocked, untouched', o['jobs'][0]['state'] == 'BLOCKED' and o['jobs'][0]['step_no'] == 16, str(o)[:300])
expect_error('second job refused while the first is open', 'start_production_job', {"p_idempotency_key": "live-2", "p_series_code": "M417", "p_request": REQUEST}, 'ACTIVE_JOB_LIMIT_REACHED')
c = rpc('cancel_production_job', {"p_job_id": job, "p_actor": "FATIH", "p_reason": "line too long for its shot"}); check('blocked job cancels cleanly', c['state'] == 'CANCELLED', str(c))
j2 = rpc('start_production_job', {"p_idempotency_key": "live-2", "p_series_code": "M417", "p_request": REQUEST}); check('a fresh job starts', j2['decision'] == 'CREATED', str(j2))
rpc('evaluate_budget_gate', {"p_job_id": j2['job_id'], "p_gate_no": 1})
check('fresh job plans and commits under the new checks', plan(j2['job_id'])['step_no'] == 16)
g = voice(j2['job_id']); check('voices, music, gate 2 -> stops for missing video prerequisites', g['blocked_reason'] == 'VIDEO_PREREQUISITES_MISSING', str(g)[:300])
summary()
