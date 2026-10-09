"""Reusable walk through the Make calls, used by several tests."""
from lib import *
from fixtures import *
import json

def start(key='t-1', budget=None):
    sql("update public.system_flags set value = true where key = 'pipeline_enabled'")
    if one("select count(*) from public.budgets where budget_type='MONTHLY'") == '0':
        sql("insert into public.budgets (budget_type, hard_limit, is_active) values ('MONTHLY', 50, true)")
    r = rpc('start_production_job', {"p_idempotency_key": key, "p_series_code": "M417", "p_request": budget or REQUEST})
    rpc('evaluate_budget_gate', {"p_job_id": r['job_id'], "p_gate_no": 1})
    return r['job_id']

def plan(job, shot_pkg=None):
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
    rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS})
    rpc('get_series_bible', {"p_job_id": job})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT})
    r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": shot_pkg or shots()})
    assert r['accepted'], r
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
    rpc('route_revision', {"p_job_id": job})
    rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
    return rpc('commit_production_package', {"p_job_id": job})

def voice(job):
    while True:
        r = rpc('list_voice_work', {"p_job_id": job})
        if not r['items']: break
        for it in r['items']:
            put(it['storage_path'], 24000)
            t = rpc('register_voice_take', {"p_line_id": it['line_id'], "p_action": it['action'], "p_storage_path": it['storage_path'], "p_mp3_bitrate_kbps": 128})
            rpc('apply_voice_qc', {"p_take_id": t['take_id'], "p_verdict": "PASS", "p_score": None})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "MUSIC_SFX_PLAN", "p_producer": "CLAUDE", "p_content": MUSIC_EMPTY})
    rpc('check_music_licenses', {"p_job_id": job})
    return rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 2})

def actions():
    return rpc('next_video_actions')['items']

def submit_and_finish(item, visual, fail_generation=False):
    """SUBMIT -> POLL -> PROCESS_OUTPUT for one attempt, the way the Make branches do it."""
    c = rpc('claim_attempt_submission', {"p_attempt_id": item['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True)
    assert c['decision'] == 'CLAIMED', c
    body = json.loads(item['provider_request_text'])
    if item['provider'] == 'KLING':
        resp = {"code": 200, "data": {"task_id": "task-" + item['attempt_id'][:8], "status": "pending"}, "message": "success"}
    else:
        resp = {"name": "models/veo/operations/op-" + item['attempt_id'][:8]}
    s = rpc('record_attempt_submission', {"p_attempt_id": item['attempt_id'], "p_provider_response": resp})
    assert s['status'] == 'SUBMITTED', s
    poll = [a for a in actions() if a['action'] == 'POLL' and a['attempt_id'] == item['attempt_id']][0]
    if item['provider'] == 'KLING':
        running = {"code": 200, "data": {"task_id": "x", "status": "processing"}}
        done = {"code": 200, "data": {"task_id": "x", "status": "completed", "output": {"works": [{"video": {"resource_without_watermark": "https://cdn.example/k.mp4"}}]}}}
        failed = {"code": 200, "data": {"task_id": "x", "status": "failed", "error": {"message": "internal"}}}
    else:
        running = {"name": "op", "done": False}
        done = {"name": "op", "done": True, "response": {"generateVideoResponse": {"generatedSamples": [{"video": {"uri": "https://generativelanguage.googleapis.com/v1beta/files/abc:download?alt=media"}}]}}}
        failed = {"name": "op", "done": True, "error": {"code": 13, "message": "internal"}}
    p = rpc('record_provider_poll', {"p_attempt_id": item['attempt_id'], "p_provider_response": running}); assert p['status'] == 'RUNNING', p
    if fail_generation:
        p = rpc('record_provider_poll', {"p_attempt_id": item['attempt_id'], "p_provider_response": failed}); assert p['status'] == 'FAILED', p
        return poll, p, None
    p = rpc('record_provider_poll', {"p_attempt_id": item['attempt_id'], "p_provider_response": done}); assert p['status'] == 'SUCCEEDED', p
    out = [a for a in actions() if a['action'] == 'PROCESS_OUTPUT' and a['attempt_id'] == item['attempt_id']][0]
    put(out['storage_path'], 3_000_000, 'video/mp4')
    g = rpc('register_generation_output', {"p_attempt_id": item['attempt_id'], "p_storage_path": out['storage_path']})
    assert g['technical_qc'] == 'PASS', g
    q = rpc('apply_visual_qc', {"p_output_id": g['output_id'], "p_result": visual})
    return poll, out, q

def run_shot(shot_id, visual=None):
    """ACQUIRE + SUBMIT + finish for the next attempt of a shot."""
    a = [x for x in actions() if x['action'] == 'ACQUIRE' and x['shot_id'] == shot_id][0]
    p = rpc('prepare_shot_attempt', {"p_shot_id": shot_id}); assert p['decision'] == 'AUTHORIZED', p
    s = [x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == shot_id][0]
    return s, submit_and_finish(s, visual or VISUAL_PASS)

def video_all_pass(job):
    ep = one(f"select episode_id from public.production_jobs where id='{job}'")
    for sid in one(f"select string_agg(id::text, ',' order by shot_order) from public.shots where episode_id='{ep}'").split(','):
        run_shot(sid)
    acts = actions()
    assert [a['action'] for a in acts] == ['ADVANCE'], acts
    rpc('ack_video_advance', {"p_job_id": job})

def sign(text):
    """What POST /storage/v1/object/sign/<bucket> returns."""
    req = json.loads(text)
    return [{"error": None, "path": p, "signedURL": f"/object/sign/production-assets/{p}?token=tok"} for p in req['paths']]

def assemble(job, final=None):
    rpc('select_final_audio_track', {"p_job_id": job})
    b = rpc('begin_assembly', {"p_job_id": job}); assert b['phase'] == 'START', b
    c = rpc('create_render', {"p_job_id": job, "p_signed_urls": sign(b['sign_request_text'])})
    rpc('mark_render_submitted', {"p_render_id": c['render_id'], "p_shotstack_render_id": "ss-" + c['render_id'][:8]})
    d = rpc('record_render_poll', {"p_render_id": c['render_id'], "p_status": "done", "p_output_url": "https://cdn.shotstack.io/x.mp4"})
    put(d['storage_path'], 5_000_000, 'video/mp4')
    rpc('complete_render', {"p_render_id": c['render_id'], "p_storage_path": d['storage_path']})
    rpc('apply_final_qc', {"p_render_id": c['render_id'], "p_result": final or FINAL_PASS})
    rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 2, "p_checker": "CLAUDE", "p_result": POLICY_PASS})
    return rpc('approve_release', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": RELEASE_APPROVE})

def package(job):
    rpc('resolve_thumbnail', {"p_job_id": job})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "METADATA_CANDIDATES", "p_producer": "GROK", "p_content": METADATA})
    rpc('save_publication_package', {"p_job_id": job, "p_selected_by": "CLAUDE", "p_result": PACKAGE})
    return rpc('request_publish_approval', {"p_job_id": job})
