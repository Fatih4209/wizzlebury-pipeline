"""008: Kling 3.0 Omni with the characters' reference images."""
from flow import *
import subprocess
S = '/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad'
def apply(f):
    r = subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', S + '/mig/' + f], capture_output=True, text=True)
    return r.returncode, r.stderr
def owner(q):
    r = subprocess.run(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', q], capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()
BASE = 'https://proj.supabase.co/storage/v1'
PUB = BASE + '/object/public/public-refs/'
sql("update public.system_settings set value_numeric = 50 where key = 'max_active_jobs'; update public.system_settings set value_numeric = 0 where key in ('video_driver_min_interval_seconds', 'video_poll_min_interval_seconds')")
rpc('set_text_setting', {"p_key": "storage_base_url", "p_value": BASE})
rpc('set_text_setting', {"p_key": "notify_chat_id", "p_value": "123456"})

rc, err = apply('008_kling_omni_refs.sql'); check('008 refuses to run before 007', rc != 0 and 'M417_007_NOT_FOUND' in err, err[:200])
rc, err = apply('007_kling_setup.sql'); assert rc == 0, err

# an episode already in the video stage when 008 arrives
old = start('o-0'); plan(old); g = voice(old); assert g['passed'], g
rpc('set_generation_enabled', {"p_enabled": True})
ep0 = one(f"select episode_id from public.production_jobs where id='{old}'")
ids0 = one(f"select string_agg(id::text, ',' order by shot_order) from public.shots where episode_id='{ep0}'").split(',')
p = rpc('prepare_shot_attempt', {"p_shot_id": ids0[0]}); assert p['decision'] == 'AUTHORIZED' and abs(float(p['reserved_cost']) - 0.20) < 1e-9, p

rc, err = apply('008_kling_omni_refs.sql'); check('008 applies', rc == 0, err[:300])
rc, err = apply('008_kling_omni_refs.sql'); check('008 applies a second time', rc == 0, err[:300])
check('five public references on record, one event each', one("select (select count(*) from public.video_reference_images where is_active)||'/'||(select count(*) from public.events where event_type='VIDEO_REFERENCE_SET')") == '5/5')
check('Fatih file name as uploaded', one("select v.object_path from public.video_reference_images v join public.asset_registry ar on ar.id=v.asset_id where ar.asset_code='FATIH_CANONICAL_V1'") == 'FATIH_REF_V1.png')
check('the newest approved policy is the Omni one', one("select policy_code from public.generation_routing_policies where status='ACTIVE' order by approved_at desc limit 1") == 'M417_KLING_OMNI')
check('writers keep the 5 and 10 s durations', json.loads(rpc('get_job_context', {"p_job_id": old})['series_bible_text'])['format']['allowed_shot_durations_seconds'] == [5, 10])

s = [x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == ids0[0]][0]
b = json.loads(s['provider_request_text'])
check('an attempt authorised before 008 keeps its model and request', b['task_type'] == 'video_generation' and b['input']['version'] == '2.6' and 'images' not in b['input'] and 'negative_prompt' in b['input'], json.dumps(b)[:300])
submit_and_finish(s, VISUAL_PASS)
p = rpc('prepare_shot_attempt', {"p_shot_id": ids0[1]}); check('its next shot is made with Omni at 0.50 USD', p['decision'] == 'AUTHORIZED' and abs(float(p['reserved_cost']) - 0.50) < 1e-9, str(p))
sql(f"update public.production_jobs set state = 'CANCELLED' where id = '{old}'")

# a new episode, start to finish
job = start('o-1'); plan(job); g = voice(job)
check('gate 2 passes and estimates 1.00 USD for two 5 s shots', g['passed'] is True and g['step_no'] == 22 and abs(float(g['estimated_video_cost']) - 1.00) < 1e-9, str(g)[:300])
ep = one(f"select episode_id from public.production_jobs where id='{job}'")
ids = one(f"select string_agg(id::text, ',' order by shot_order) from public.shots where episode_id='{ep}'").split(',')
bodies = []
for n, sid in enumerate(ids):
    p = rpc('prepare_shot_attempt', {"p_shot_id": sid}); check(f'shot {n+1}: authorised at the Omni price', p['decision'] == 'AUTHORIZED' and abs(float(p['reserved_cost']) - 0.50) < 1e-9, str(p))
    s = [x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == sid][0]
    body = json.loads(s['provider_request_text']); bodies.append(body); i = body['input']
    if n == 0:
        check('Omni request shape', s['provider'] == 'KLING' and s['submit_url'] == 'https://api.piapi.ai/api/v1/task' and body['model'] == 'kling' and body['task_type'] == 'omni_video_generation' and i['version'] == '3.0' and i['resolution'] == '720p' and i['duration'] == 5 and i['aspect_ratio'] == '9:16' and i['enable_audio'] is False and set(i) == {'prompt', 'version', 'resolution', 'duration', 'aspect_ratio', 'enable_audio', 'images'}, json.dumps(body)[:500])
        check('one character -> one image', i['images'] == [PUB + 'FATIH_REF_V1.png'], str(i['images']))
        check('the prompt names the image', i['prompt'].startswith('Reference images: @image_1 is Fatih. ') and '@image_2' not in i['prompt'], i['prompt'][:200])
        check('scene text and the avoid list are in the prompt', 'A boy runs across a sunny park' in i['prompt'] and ' Avoid: blur' in i['prompt'], i['prompt'][-400:])
    else:
        check('two characters -> two images in name order', i['images'] == [PUB + 'FATIH_REF_V1.png', PUB + 'MIA_REF_V1.png'], str(i['images']))
        check('both are named in the prompt, in list order', i['prompt'].startswith('Reference images: @image_1 is Fatih, @image_2 is Mia. '), i['prompt'][:200])
    check(f'shot {n+1}: prompt inside 2500 characters', len(i['prompt']) <= 2500, str(len(i['prompt'])))
    c = rpc('claim_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_claimed_by": "MAKE_S4"}, obj=True); assert c['decision'] == 'CLAIMED', c
    tid = f"7e269e8c-2091-46c4-b4a5-40a4704a76{n:02d}"
    resp = {"code": 200, "data": {"task_id": tid, "model": "kling", "task_type": "omni_video_generation", "status": "pending", "input": {}, "output": None, "meta": {}, "error": {"code": 0, "message": ""}}, "message": "success"}
    r = rpc('record_attempt_submission', {"p_attempt_id": s['attempt_id'], "p_provider_response": resp}); assert r['status'] == 'SUBMITTED' and r['provider_job_id'] == tid, r
    done = dict(resp); done['data'] = dict(resp['data'], status='completed', output={"video": f"https://storage.theapi.app/videos/{tid}.mp4"})
    r = rpc('record_provider_poll', {"p_attempt_id": s['attempt_id'], "p_provider_response": done}); assert r['status'] == 'SUCCEEDED', r
    out = [x for x in actions() if x['action'] == 'PROCESS_OUTPUT' and x['attempt_id'] == s['attempt_id']][0]
    if n == 0: check('download address is output.video of the Omni task', out['download_url'] == f"https://storage.theapi.app/videos/{tid}.mp4", out['download_url'])
    put(out['storage_path'], 3_000_000, 'video/mp4')
    gq = rpc('register_generation_output', {"p_attempt_id": s['attempt_id'], "p_storage_path": out['storage_path']})
    q = rpc('apply_visual_qc', {"p_output_id": gq['output_id'], "p_result": VISUAL_PASS}); check(f'shot {n+1} locked', q['shot_state'] == 'LOCKED', str(q))
acts = actions(); check('both shots done -> assembly', [x['action'] for x in acts] == ['ADVANCE'], str(acts)[:200]); rpc('ack_video_advance', {"p_job_id": job})
r = assemble(job); check('assembly, final QC and release pass on the Omni clips', r['step_no'] == 35, str(r)[:200])
check('1.00 USD settled for the episode', abs(float(one(f"select settled_amount from public.budgets where budget_type='EPISODE' and reference_id='{ep}'")) - 1.00) < 1e-9, one(f"select settled_amount from public.budgets where budget_type='EPISODE' and reference_id='{ep}'"))

# a very long scene description still fits
job2 = start('o-2'); pk = shots(); pk['shots'][0]['video_prompt'] = ('The boy sprints through tall grass while the kite jerks overhead. ' * 20)[:1200]; pk['shots'][0]['negative_prompt'] = 'blurry faces, ' * 60
plan(job2, pk); voice(job2)
ep2 = one(f"select episode_id from public.production_jobs where id='{job2}'"); s1 = one(f"select id from public.shots where episode_id='{ep2}' order by shot_order limit 1")
rpc('prepare_shot_attempt', {"p_shot_id": s1}); s = [x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == s1][0]
pr = json.loads(s['provider_request_text'])['input']['prompt']
check('long prompt: capped at 2500 and still opens with the references', len(pr) <= 2500 and pr.startswith('Reference images: @image_1 is Fatih. '), str(len(pr)))
check('long prompt: avoid list capped', len(pr.split(' Avoid: ')[-1]) <= 300, str(len(pr.split(' Avoid: ')[-1])))

# the owner swaps or switches off a reference
rc, out = owner("select public.set_video_reference('FATIH_CANONICAL_V1', 'v3/FATIH_REF_V3.png', 'FATIH')")
check('owner can point a character at a new file', rc == 0 and json.loads(out)['url'] == PUB + 'v3/FATIH_REF_V3.png', out[:200])
check('the pending request follows the new file', json.loads([x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == s1][0]['provider_request_text'])['input']['images'] == [PUB + 'v3/FATIH_REF_V3.png'])
rc, out = owner("select public.set_video_reference('NO_SUCH_ASSET', 'x.png', 'FATIH')"); check('unknown asset refused', rc != 0 and 'LOCKED_ASSET_NOT_FOUND' in out, out[:120])
for bad in ("/x.png", "a b.png", "x.png?download=1", ""):
    rc, out = owner(f"select public.set_video_reference('MIA_CANONICAL_V1', '{bad}', 'FATIH')"); check(f'bad path refused: "{bad}"', rc != 0 and 'REFERENCE_PATH_INVALID' in out, out[:120])
rc, out = owner("set role service_role; select public.set_video_reference('MIA_CANONICAL_V1', 'x.png', 'X')"); check('not callable through the API role', rc != 0)
rc, out = owner("set role service_role; select count(*) from public.video_reference_images"); check('table not readable through the API role', rc != 0)
sql("update public.video_reference_images v set is_active = false from public.asset_registry ar where ar.id = v.asset_id and ar.asset_code = 'FATIH_CANONICAL_V1'")
b = json.loads([x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == s1][0]['provider_request_text'])['input']
check('a switched-off reference is left out; the request is still valid text-to-video', 'images' not in b and not b['prompt'].startswith('Reference images') and 'The boy sprints' in b['prompt'], json.dumps(b)[:200])
sql("update public.video_reference_images set is_active = true")
rpc('set_text_setting', {"p_key": "storage_base_url", "p_value": ""})
try:
    b = json.loads([x for x in actions() if x['action'] == 'SUBMIT' and x['shot_id'] == s1][0]['provider_request_text'])['input']
    check('without a storage address no broken image links are sent', 'images' not in b, json.dumps(b)[:200])
except Exception as e:
    check('without a storage address no broken image links are sent', False, str(e)[:200])
summary()
