"""012: looping short - camera plan, first frames approved by the owner, start-frame video requests."""
from flow import *
import copy, subprocess
S = '/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad'
def apply(f):
    r = subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', S + '/mig/' + f], capture_output=True, text=True)
    return r.returncode, r.stderr
def owner(q):
    r = subprocess.run(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', q], capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()
def putpub(path, size=180000):
    sql(f"insert into storage.objects (bucket_id, name, metadata) values ('public-refs', $p${path}$p$, jsonb_build_object('size', {size}, 'mimetype', 'image/jpeg')) on conflict (bucket_id, name) do update set metadata = excluded.metadata")
BASE = 'https://proj.supabase.co/storage/v1'
sql("update public.system_settings set value_numeric = 50 where key = 'max_active_jobs'; update public.system_settings set value_numeric = 0 where key in ('video_driver_min_interval_seconds', 'video_poll_min_interval_seconds')")
rpc('set_text_setting', {"p_key": "storage_base_url", "p_value": BASE})
rpc('set_text_setting', {"p_key": "notify_chat_id", "p_value": "123456"})
owner("create schema if not exists net; create table if not exists net.sent (id bigserial primary key, url text, body jsonb); "
      "create or replace function net.http_post(url text, body jsonb) returns bigint language sql as $f$ insert into net.sent (url, body) values (url, body) returning id $f$; "
      "grant usage on schema net to public; grant all on net.sent to public; grant usage on sequence net.sent_id_seq to public")
def sent(source=None):
    w = f" where body ->> 'source' = '{source}'" if source else ''
    return one(f"select coalesce(string_agg(url, ',' order by id), '') from net.sent{w}")
def resume(job_):
    return one(f"select coalesce(m417_internal.resume_url('{job_}', 22), 'NULL')")
subprocess.run(['bash', S + '/mig/build_012.sh'], capture_output=True, check=True)
subprocess.run(['bash', S + '/mig/build_013.sh'], capture_output=True, check=True)
rc, err = apply('007_kling_setup.sql'); assert rc == 0, err
rc, err = apply('008_kling_omni_refs.sql'); assert rc == 0, err
# the live order: 010 again (it puts the old functions back), then 012 twice
rc, err = apply('010_film_grammar.sql'); assert rc == 0, err
check('010 took five of the six 012 layers away', one("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','m417_internal') and p.prosrc like '%M417-LAYER-012%' and p.proname in ('validate_shot_package','validate_script','build_provider_request','video_scan','step_prompt','prepare_shot_attempt','resume_url')") == '2')
rc, err = apply('012_short_format.sql'); check('012 applies', rc == 0, err[:400])
rc, err = apply('012_short_format.sql'); check('012 applies a second time', rc == 0, err[:400])
rc, err = apply('013_one_event.sql'); check('013 applies', rc == 0, err[:400])
rc, err = apply('013_one_event.sql'); check('013 applies a second time', rc == 0, err[:400])
sql("update public.system_text_settings set value = 'https://hook.example/kare' where key = 'webhook_keyframes'; update public.system_text_settings set value = 'https://hook.example/s4' where key = 'webhook_s4_driver'")
check('seven layers in place', one("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','m417_internal') and p.prosrc like '%M417-LAYER-012%' and p.proname in ('validate_shot_package','validate_script','build_provider_request','video_scan','step_prompt','prepare_shot_attempt','resume_url')") == '7')
check('seven bases kept', one("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname = 'm417_internal' and p.proname in ('validate_shot_package_film','validate_script_film','build_provider_request_base','video_scan_base','step_prompt_base','prepare_shot_attempt_base','resume_url_base')") == '7')
check('new flags start off', one("select string_agg(value::text, ',' order by key) from public.system_flags where key in ('keyframe_required','camera_plan_enforced','short_format_enforced')") == 'false,false,false')
check('short prompts in force', one("select string_agg(prompt_code||version, ',' order by prompt_code) from public.step_prompts where is_active") == 'DIRECTOR3,FINAL_QC1,PREQC1,SCRIPT2,SHOT_PACKAGE4,TOPIC2')
expect_error('the API may not decide keyframes', 'decide_keyframes', {"p_job_id": "00000000-0000-0000-0000-000000000000", "p_decision": "APPROVE", "p_actor": "x"}, 'permission denied')
expect_error('the API may not read the overview', 'keyframe_overview', {"p_job_id": "00000000-0000-0000-0000-000000000000"}, 'permission denied')

sql("update public.system_flags set value = true where key in ('film_grammar_enforced', 'assistant_vote_required', 'camera_plan_enforced', 'short_format_enforced', 'keyframe_required')")
for k, v in (('episode_min_seconds', 10), ('episode_max_seconds', 15), ('min_shots', 3), ('max_shots', 4), ('max_shot_edit_seconds', 4.8), ('max_dialogue_lines', 2)):
    rpc('set_numeric_setting', {"p_key": k, "p_value": v, "p_actor": "TEST"}) if False else sql(f"update public.system_settings set value_numeric = {v} where key = '{k}'")

FRAME1 = ("Tombik is not here. Fatih kneels on the left of the frame on the green lawn, both hands stretched toward a big red gift box in the middle; "
          "Mia stands behind him on the right, both palms raised, eyes wide.")
LONG = ("Fatih kneels on the left on the green lawn and reaches with both hands for the big red box, which wobbles in the middle of the frame. "
        "Mia stands on the right behind him, lifts both palms and shakes her head, eyes wide, mouth open in alarm.")
SHORT_SCRIPT = {
    "title": "The Red Box", "logline": "Do not open the red box.", "pattern": "DONT_OPEN_IT",
    "hook": "A big red gift box wobbles on the lawn while Fatih reaches for it and Mia throws her hands up.",
    "payoff": "Confetti and balloons burst out, both laugh, the lid drops shut and the box wobbles again.",
    "loop": "The lid falls shut and the box wobbles exactly as in the first image.",
    "music_mood": "sneaky", "sfx": [{"at": "the lid pops open", "sound": "pop"}],
    "look": "Sunny afternoon in the park, soft warm light, bright saturated colours.",
    "wardrobe": [{"character": "CHR_FATIH", "outfit": "red bomber jacket over a white t-shirt, dark jeans, plain red-and-white sneakers"},
                 {"character": "CHR_MIA", "outfit": "loose turquoise t-shirt, knee-length pink shorts, white sneakers"}],
    "props": [{"name": "red box", "description": "one big red gift box with a yellow ribbon and a loose lid, knee-high, exactly one"}],
    "scenes": [
        {"scene_no": 1, "location": "LOC_NEIGHBORHOOD_PARK", "characters": ["CHR_FATIH", "CHR_MIA"], "duration_seconds": 12,
         "action": "Fatih on the left reaches for the wobbling red box; Mia on the right warns him. He lifts the lid a little; confetti and balloons burst out; both laugh; the lid drops shut.",
         "dialogue": [{"line_no": 1, "character": "CHR_MIA", "text": "Don't open it!", "emotion": "alarmed"},
                      {"line_no": 2, "character": "CHR_FATIH", "text": "Just a peek!", "emotion": "cheeky"}], "sound_notes": "sneaky pizzicato"}],
    "total_duration_seconds": 12, "revision_notes": ""}

def sshot(no, size, angle, move, edit, chars, lines=None, staging="", frame=FRAME1, what="The red box wobbles on the lawn"):
    return {"shot_no": no, "scene_no": 1, "purpose": "ACTION", "shot_size": size, "camera_angle": angle, "camera_move": move,
            "camera": "static", "first_frame": frame, "duration_seconds": 5, "edit_seconds": edit, "aspect_ratio": "9:16",
            "characters": chars, "location": "LOC_NEIGHBORHOOD_PARK", "props": ["red box"],
            "beats": [{"at": 0.0, "what": what}, {"at": 0.8, "what": "Eyes go wide and the eyebrows shoot up"}],
            "dialogue_line_nos": lines or [], "voice_staging": staging, "action": "Fatih reaches for the wobbling red box while Mia warns him",
            "acting": "wide-eyed alarm", "video_prompt": LONG, "negative_prompt": "blur, text", "continuity_notes": "Fatih left, Mia right"}
YES = {"decision": "YES", "scores": {"hook": 8, "story": 8, "humor": 7, "dialogue": 8, "filmability": 9},
       "strengths": ["clear hook"], "problems": [], "required_changes": []}
def short_shots():
    return {"script_vote": YES, "shots": [
        sshot(1, "MEDIUM", "EYE_LEVEL", "STATIC", 2.5, ["CHR_FATIH", "CHR_MIA"], [1], "ON_CAMERA"),
        sshot(2, "INSERT", "HIGH_ANGLE", "PUSH_IN", 4.0, [], [2], "OFF_SCREEN",
              frame="The big red box fills the frame from slightly above; two small hands hold the edge of its lid, which is lifted a finger's width; a thin line of golden light escapes.",
              what="The lid rises a little more and light spills out"),
        sshot(3, "WIDE", "EYE_LEVEL", "PULL_BACK", 4.5, ["CHR_FATIH", "CHR_MIA"],
              frame="Fatih on the left and Mia on the right stand a step behind the red box in the middle of the lawn, both leaning back with arms half raised, mouths open; the lid is in the air above the box.",
              what="Confetti and balloons burst out of the box")],
        "total_edit_seconds": 11.0, "continuity_risks": []}
def upto_script(key, script=None):
    job = start(key)
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
    ctx = rpc('get_job_context', {"p_job_id": job})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": dict(TOPIC, title="The Red Box", pattern="DONT_OPEN_IT")})
    rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS})
    rpc('get_series_bible', {"p_job_id": job})
    ctx10 = rpc('get_job_context', {"p_job_id": job})
    r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": script or SHORT_SCRIPT})
    return job, r, ctx, ctx10
def save_shots(job, pkg):
    return rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": pkg})
def details(r):
    return ' | '.join(i['detail'] for i in r.get('issues', []))
def jstep(job):
    return int(one(f"select current_step from public.production_jobs where id='{job}'"))

# ---- 1. instructions and script rules -----------------------------------
bad = copy.deepcopy(SHORT_SCRIPT); del bad['loop']; bad['music_mood'] = ''
bad['scenes'][0]['dialogue'][0]['text'] = "Fatih, please do not open that box now!"
job, r, ctx7, ctx10 = upto_script('short-bad', bad); d = details(r)
p = ctx7['prompt_text']
check('topic prompt: looping short', 'THIS FORMAT: A LOOPING SHORT' in p and 'DONT_OPEN_IT' in p and '[[' not in p, p[p.find('[['):][:80] if '[[' in p else p[:200])
check('topic prompt: recent shorts are listed', 'Recent shorts, newest first: []' in p, p[p.find('Recent shorts'):][:120])
p = ctx10['prompt_text']
check('script prompt: words, loop, music', 'at most 6 words' in p and 'loop: the last image leads back' in p and 'music_mood: the mood of the music' in p and 'playful, sneaky' in p and '[[' not in p, p[:300])
check('script without loop refused', r['accepted'] is False and 'loop is missing' in d, d[:300])
check('script without music mood refused', 'music_mood is missing' in d, d[:300])
check('long line refused by word count', 'has 8 words' in d, d[:300])
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "TEST", "p_reason": "x"})

# ---- 2. camera plan -------------------------------------------------------
job, r, _, _ = upto_script('short-1')
check('short script accepted', r['accepted'] is True and jstep(job) == 11, str(r)[:300])
p = rpc('get_job_context', {"p_job_id": job})['prompt_text']
check('shots prompt: camera and first frame', 'camera_angle is one of EYE_LEVEL' in p and 'first_frame describes the still picture' in p and '3 to 4 shots' in p and '"first_frame": ""' in p and '[[' not in p, p[:200])
check('shots prompt: everybody in shot 1, frames continue', 'Shot 1 shows every character who takes part in the scene' in p and 'exactly in the state in which the shot before ended' in p and 'shot 1 shows everyone in the scene;' in p, p[p.find('Nobody pops'):][:300])
check('shots prompt: one event per shot', 'At most 3 beats: one event and the reaction to it.' in p and 'every shot has at most 3 beats, the first at 0;' in p, p[p.find('- beats:'):][:400])
def broken(fn):
    pkg = short_shots(); fn(pkg['shots']); return pkg
cases = [
    ('angle missing', lambda s: s[0].pop('camera_angle'), 'camera_angle is missing or unknown'),
    ('move unknown', lambda s: s[2].update(camera_move='SPIN'), 'camera_move is missing or unknown: SPIN'),
    ('drone in the middle', lambda s: s[1].update(camera_angle='DRONE'), 'DRONE angle is used in the middle'),
    ('drone close', lambda s: s[0].update(camera_angle='DRONE'), 'DRONE angle is combined with shot_size MEDIUM'),
    ('talking while tracking', lambda s: s[0].update(camera_move='TRACK'), 'spoken ON_CAMERA while the camera does a TRACK'),
    ('descend without drone', lambda s: s[2].update(camera_move='DRONE_DESCEND'), 'DRONE_DESCEND needs camera_angle DRONE'),
    ('thin first frame', lambda s: s[1].update(first_frame='The box.'), 'first_frame is missing or too thin'),
    ('film rules still apply', lambda s: s[2].update(shot_size='INSERT'), 'same shot_size (INSERT)'),
    ('two events in one shot', lambda s: s[1]['beats'].extend([{"at": 1.6, "what": "Both children lean in over the box"}, {"at": 2.4, "what": "The lid drops shut with a bang"}]), 'The shot has 4 beats; a shot of a short has at most 3.'),
]
for name, fn_, needle in cases:
    r = save_shots(job, broken(fn_)); d = details(r)
    check(f'camera: {name}', r['accepted'] is False and needle in d, d[:300])
    sql(f"update public.production_jobs set validation_retry_count = 0, current_step = 11, state = 'READY' where id='{job}'")
alias = short_shots(); alias['shots'][0]['camera_angle'] = 'eye level'; alias['shots'][2]['camera_move'] = 'pull-back'
alias['shots'][2]['beats'].append({"at": 2.0, "what": "Both children burst out laughing"})
r = save_shots(job, alias)
check('camera plan accepted, spelling forgiven, three beats allowed', r['accepted'] is True, details(r)[:300])
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
rpc('route_revision', {"p_job_id": job})
p = rpc('get_job_context', {"p_job_id": job})['prompt_text']
check('director prompt: converge and first frames', 'Converge.' in p and 'The owner sees and approves the first frame of every shot' in p and '[[' not in p, p[:200])
rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
c = rpc('commit_production_package', {"p_job_id": job})
check('commit: 3 shots, 2 lines', c.get('shots') == 3 and c.get('dialogue_lines') == 2, str(c)[:300])
g = voice(job)
check('budget gate 2', g.get('passed') is True and jstep(job) == 22, str(g)[:300])
check('reaching the video stage starts the drawing', sent('video_stage_reached') == f'https://hook.example/kare?job_id={job}', sent())
check('restart address: the keyframe scenario', resume(job) == f'https://hook.example/kare?job_id={job}', resume(job))
ep = one(f"select episode_id from public.production_jobs where id='{job}'")
ids = one(f"select string_agg(id::text, ',' order by shot_order) from public.shots where episode_id='{ep}'").split(',')

# ---- 3. the gate ------------------------------------------------------------
rpc('set_generation_enabled', {"p_enabled": True})
check('nothing is offered for generation without a first frame', actions() == [], str(actions())[:300])
check('driver has nothing to wait for', rpc('video_work_pending')['pending'] is False, str(rpc('video_work_pending')))
p = rpc('prepare_shot_attempt', {"p_shot_id": ids[0]})
check('a direct call waits for the keyframe', p == {'decision': 'WAITING_FOR_KEYFRAME'}, str(p))
rc, o = owner(f"begin; select m417_internal.prepare_shot_attempt_base('{ids[0]}'); rollback;")
check('the table itself refuses an attempt', 'KEYFRAME_APPROVAL_REQUIRED' in o and 'BLOCKED' in o, o[:300])
check('no attempt row exists', one(f"select count(*) from public.attempts a join public.shots s on s.id=a.shot_id where s.episode_id='{ep}'") == '0')

# ---- 4. drawing the first frames ----------------------------------------------
w = rpc('next_keyframe_work', {"p_job_id": job})
check('three pictures to draw', w['count'] == 3 and w['shots'] == 3 and [i['shot_code'] for i in w['items']] == ['SH01', 'SH02', 'SH03'], str(w)[:300])
it = w['items'][0]; pr = it['prompt']
for needle in ('One still frame from a 3D animated family film, vertical 9:16', 'Medium shot: framed from the waist up.', "Camera at the children's eye level.",
               'frozen: Tombik is not here. Fatih kneels on the left', 'Reference images, in the order given: image 1 is Fatih, image 2 is Mia',
               'Outfits: Fatih wears red bomber jacket', 'Mia wears loose turquoise t-shirt', 'Props, exactly as described and no extra copies: one big red gift box',
               'Look: Sunny afternoon', 'All the children are the same age and the same height', 'Exactly one of each named character and nobody else'):
    check(f'picture prompt: {needle[:34]}', needle in pr, pr[:900])
check('picture prompt inside the limit', all(len(i['prompt']) <= 2600 for i in w['items']), '')
check('picture request: model, ratio, references', it['model'] == 'gemini-3.1-flash-image' and it['aspect_ratio'] == '9:16' and it['bucket'] == 'public-refs'
      and [x['uri'] for x in it['images']][:2] == [BASE + '/object/public/public-refs/FATIH_REF_V1.png', BASE + '/object/public/public-refs/MIA_REF_V1.png']
      and it['images'][0]['mimeType'] == 'image/png' and it['images'][0]['upload_format'] == 'url', str(it)[:500])
check('picture path', it['storage_path'].startswith('keyframes/M417/') and '/SH01_K1_' in it['storage_path'] and it['storage_path'].endswith('.jpg'), it['storage_path'])
check('an insert shot has no character references', w['items'][1]['images'] == [] or all('REF' not in x['uri'] or 'LOC' in x['uri'] for x in w['items'][1]['images']), str(w['items'][1]['images']))
w2 = rpc('next_keyframe_work', {"p_job_id": job})
check('handed out pictures are not handed out twice', w2['count'] == 0 and w2['waiting'] == 3, str(w2)[:200])
expect_error('a picture that is not in storage is refused', 'register_keyframe', {"p_keyframe_id": it['keyframe_id'], "p_storage_path": it['storage_path']}, 'KEYFRAME_FILE_NOT_FOUND_IN_STORAGE')
regs = []
for i in w['items']:
    putpub(i['storage_path'])
    regs.append(rpc('register_keyframe', {"p_keyframe_id": i['keyframe_id'], "p_storage_path": i['storage_path']}))
check('registered', all(x['status'] == 'GENERATED' and x['registered'] for x in regs) and regs[0]['image_url'] == BASE + '/object/public/public-refs/' + w['items'][0]['storage_path'], str(regs[0])[:300])
check('the checker is told what to look for', 'a named character missing or drawn twice' in regs[0]['check_text'] and 'Fatih, Mia' in regs[0]['check_text'] and 'Return one raw JSON object' in regs[0]['check_text'], regs[0]['check_text'][-400:])
a1 = rpc('apply_keyframe_check', {"p_keyframe_id": w['items'][0]['keyframe_id'], "p_result": {"verdict": "PASS", "score": 0.9, "notes": "", "findings": []}})
a2 = rpc('apply_keyframe_check', {"p_keyframe_id": w['items'][1]['keyframe_id'], "p_result": {"verdict": "FAIL", "score": 40, "notes": "There are two red boxes.", "findings": ["two boxes"]}})
a3 = rpc('apply_keyframe_check', {"p_keyframe_id": w['items'][2]['keyframe_id'], "p_result": {"verdict": "PASS", "score": 65, "notes": "Mia is clearly taller than Fatih.", "findings": []}})
check('check: pass goes to the owner', a1['status'] == 'GENERATED' and a1['show_owner'] is True and float(a1['score']) == 90, str(a1))
check('check: fail is drawn again', a2['status'] == 'REJECTED' and a2['show_owner'] is False, str(a2))
check('check: a low score fails too', a3['status'] == 'REJECTED', str(a3))
check('the checker knows how the characters look', 'How they look: Fatih: ' in regs[0]['check_text'] and ' | Mia: ' in regs[0]['check_text'], regs[0]['check_text'][-900:-500])
check('nothing is said to the owner while pictures are still being drawn', a1['owner_text'] == '' and a3['owner_text'] == '', str(a3))
check('a failed check starts the next drawing', sent('check_failed') == ','.join([f'https://hook.example/kare?job_id={job}'] * 2), sent('check_failed'))
w = rpc('next_keyframe_work', {"p_job_id": job})
check('two new takes with the reason', w['count'] == 2 and [i['take_no'] for i in w['items']] == [2, 2] and w['awaiting_review'] == 1
      and 'Correction: an earlier picture of this shot was rejected because: There are two red boxes. Do not repeat this.' in w['items'][0]['prompt']
      and 'Mia is clearly taller than Fatih' in w['items'][1]['prompt'], str(w)[:600])
f = rpc('fail_keyframe', {"p_keyframe_id": w['items'][1]['keyframe_id'], "p_reason": "blocked by the image model"})
check('a provider failure closes the take', f['status'] == 'FAILED', str(f))
check('a provider failure starts the next drawing', sent('provider_failed') == f'https://hook.example/kare?job_id={job}', sent('provider_failed'))
putpub(w['items'][0]['storage_path']); rpc('register_keyframe', {"p_keyframe_id": w['items'][0]['keyframe_id'], "p_storage_path": w['items'][0]['storage_path']})
rpc('apply_keyframe_check', {"p_keyframe_id": w['items'][0]['keyframe_id'], "p_result": {"verdict": "PASS", "score": 88, "notes": ""}})
w = rpc('next_keyframe_work', {"p_job_id": job})
check('third take for the failed one', w['count'] == 1 and w['items'][0]['take_no'] == 3 and w['items'][0]['shot_code'] == 'SH03' and 'Correction:' not in w['items'][0]['prompt'], str(w)[:300])
f3 = rpc('fail_keyframe', {"p_keyframe_id": w['items'][0]['keyframe_id'], "p_reason": "again"})
check('the owner hears that a shot is out of takes', '3 çekimden 1 tanesinin karesi 3 denemede otomatik kontrolden geçmedi' in f3['owner_text'] and 'The Red Box' in f3['owner_text'] and 'SH03: again' in f3['owner_text'], f3['owner_text'])
w = rpc('next_keyframe_work', {"p_job_id": job})
check('takes used up: a person has to look', w['count'] == 0 and w['exhausted'] == 1, str(w)[:300])
check('waiting for the owner: nothing to restart', resume(job) == 'NULL', resume(job))
sql(f"update public.production_jobs set last_activity_at = now() - interval '3 hours', watchdog_last_at = null where id = '{job}'")
rc, o = owner("select public.watchdog_tick()")
check('the watchdog leaves a job alone that waits for the owner', job not in o and one(f"select state from public.production_jobs where id='{job}'") == 'READY', o[:300])

# ---- 5. the owner decides ---------------------------------------------------------
rc, o = owner(f"select public.keyframe_overview('{job}')"); ov = json.loads(o)
check('overview', [s['status'] for s in ov['shots']] == ['GENERATED', 'GENERATED', 'FAILED'] and ov['shots'][0]['image_url'].startswith(BASE) and ov['shots'][2]['takes'] == 3 and ov['shots'][0]['first_frame'].startswith('Tombik is not here'), o[:500])
rc, o = owner(f"select public.decide_keyframes('{job}', 'REJECT', 'OWNER')")
check('a rejection needs shots and a reason', rc != 0 and 'KEYFRAME_REJECT_NEEDS_SHOTS_AND_A_REASON' in o, o[:200])
rc, o = owner(f"select public.decide_keyframes('{job}', 'APPROVE', 'OWNER', '[\"SH01\"]'::jsonb)"); d1 = json.loads(o)
check('owner approves one', d1['changed'] == 1 and d1['shots_without_approved_frame'] == 2 and d1['ready_for_video'] is False, o[:300])
acts = actions()
check('only the approved shot is offered', [(a['action'], a['shot_id']) for a in acts] == [('ACQUIRE', ids[0])], str(acts)[:300])
rc, o = owner(f"select public.decide_keyframes('{job}', 'REJECT', 'OWNER', '[\"sh02\"]'::jsonb, 'The lid must be closed.')"); d2 = json.loads(o)
check('owner rejects one', d2['changed'] == 1, o[:300])
check('a rejection starts the next drawing', sent('owner_rejected') == f'https://hook.example/kare?job_id={job}', sent('owner_rejected'))
check('restart address is the keyframe scenario again', resume(job) == f'https://hook.example/kare?job_id={job}', resume(job))
# the owner's word reopens a shot whose takes were used up: SH03 gets one after the owner looked
rc, o = owner(f"update public.shot_keyframes k set decided_by = 'OWNER' from public.shots s where s.id = k.shot_id and s.shot_code = 'SH03' and k.take_no = 3 and s.episode_id = '{ep}'")
w = rpc('next_keyframe_work', {"p_job_id": job})
check('new takes after the owner spoke', [(i['shot_code'], i['take_no']) for i in w['items']] == [('SH02', 3), ('SH03', 4)] and 'The lid must be closed.' in w['items'][0]['prompt'], str(w)[:400])
last = []
for i in w['items']:
    putpub(i['storage_path']); rpc('register_keyframe', {"p_keyframe_id": i['keyframe_id'], "p_storage_path": i['storage_path']})
    last.append(rpc('apply_keyframe_check', {"p_keyframe_id": i['keyframe_id'], "p_result": {"verdict": "PASS", "score": 92, "notes": ""}}))
check('the owner is told once, with the last picture', last[0]['owner_text'] == '' and 'ilk kareleri hazır' in last[1]['owner_text'] and 'Onay vermeden video üretilmez' in last[1]['owner_text'], str(last)[:400])
rc, o = owner(f"select public.decide_keyframes('{job}', 'APPROVE', 'OWNER')"); d3 = json.loads(o)
check('owner approves the rest', d3['changed'] == 2 and d3['ready_for_video'] is True, o[:300])
check('the last approval starts the video driver', sent('keyframes_approved') == 'https://hook.example/s4?source=manual', sent('keyframes_approved'))
check('restart address is the video driver', resume(job) == 'https://hook.example/s4?source=manual', resume(job))
check('one approved picture per shot', one(f"select count(*)||'/'||count(distinct shot_id) from public.shot_keyframes where job_id='{job}' and status='APPROVED'") == '3/3')
check('the decisions are on record', one(f"select string_agg(event_type, ',' order by created_at) from public.events where episode_id='{ep}' and event_type like 'KEYFRAMES_%'") == 'KEYFRAMES_APPROVED,KEYFRAMES_REJECTED,KEYFRAMES_APPROVED')
w = rpc('next_keyframe_work', {"p_job_id": job})
check('nothing left to draw', w['count'] == 0 and w['approved'] == 3, str(w)[:200])

# ---- 6. video from the approved frame ------------------------------------------------
key1 = one(f"select storage_path from public.shot_keyframes where shot_id='{ids[0]}' and status='APPROVED'")
s, (poll, outp, q) = run_shot(ids[0])
inp = json.loads(s['provider_request_text'])['input']
pr = inp['prompt']
check('request: the start frame is image 1', inp['images'] == [BASE + '/object/public/public-refs/' + key1, BASE + '/object/public/public-refs/FATIH_REF_V1.png', BASE + '/object/public/public-refs/MIA_REF_V1.png'], str(inp['images']))
att1 = one(f"select id from public.attempts where shot_id='{ids[0]}' order by attempt_no limit 1")
sql("update public.system_settings set value_numeric = 0 where key = 'start_frame_reference_images'")
alone = json.loads(one(f"select m417_internal.build_provider_request('{att1}')"))['input']
check('request: the start frame alone when no references are wanted', alone['images'] == [BASE + '/object/public/public-refs/' + key1] and '@image_2' not in alone['prompt'] and alone['prompt'].startswith('Use @image_1 as the start frame') and 'Static camera, no camera movement.' in alone['prompt'], str(alone)[:400])
sql("update public.system_settings set value_numeric = 3 where key = 'start_frame_reference_images'")
for needle in ('Use @image_1 as the start frame: the video begins exactly with this picture.', '@image_2 is Fatih, @image_3 is Mia: their faces',
               'Static camera, no camera movement.', 'What happens: Fatih reaches for the wobbling red box while Mia warns him.',
               'Timing: at 0.0 s The red box wobbles on the lawn; at 0.8 s Eyes go wide', 'within the first 3.0 seconds',
               'Mia is talking from the first moment of the shot', 'Acting: wide-eyed alarm.', 'Avoid: blur, text'):
    check(f'request: {needle[:36]}', needle in pr, pr[:1200])
check('request: looks are not described again', 'wears' not in pr and 'Wardrobe' not in pr and 'Style.' not in pr and len(pr) < 1500, str(len(pr)))
check('request: the rest is unchanged', inp['duration'] == 5 and inp['aspect_ratio'] == '9:16' and inp['version'] == '3.0' and inp['enable_audio'] is False, str({k: v for k, v in inp.items() if k != 'prompt'}))
brief = json.loads(outp['qc_context_text'])
check('reviewer: the approved frame is not his to judge', 'starts from a still picture the owner approved' in brief.get('approved_start_frame', '') and brief.get('film', {}).get('shot_size') == 'MEDIUM', str(brief)[:300])
sql("update public.system_settings set value_numeric = 1 where key = 'max_parallel_video_attempts'")
nv = rpc('next_video_actions')
check('one generation at a time', [a['action'] for a in nv['items']] == ['ACQUIRE'] and nv['waiting'] == 1, str(nv)[:300])
p = rpc('prepare_shot_attempt', {"p_shot_id": nv['items'][0]['shot_id']}); assert p['decision'] == 'AUTHORIZED', p
nv = rpc('next_video_actions')
check('the next one waits for the free place', [a['action'] for a in nv['items']] == ['SUBMIT'] and nv['waiting'] == 1, str(nv)[:300])
s2 = nv['items'][0]; inp2 = json.loads(s2['provider_request_text'])['input']
check('insert shot: start frame only, voice off-screen, push-in', len(inp2['images']) == 1 and 'A voice is heard from off-screen' in inp2['prompt'] and 'Slow push-in toward the face' in inp2['prompt'] and '@image_2' not in inp2['prompt'], inp2['prompt'][:600])
submit_and_finish(s2, VISUAL_FAIL)
sql("update public.system_settings set value_numeric = 3 where key = 'max_parallel_video_attempts'")
s2b, _ = run_shot(ids[1])
check('retry from the same frame carries the correction', 'Correction: an earlier take of this shot was rejected because: extra arm' in json.loads(s2b['provider_request_text'])['input']['prompt'], '')
s3, _ = run_shot(ids[2])
check('last shot pulls back', 'Slow pull-back that reveals more of the scene' in json.loads(s3['provider_request_text'])['input']['prompt'], '')
acts = actions()
check('video complete', [a['action'] for a in acts] == ['ADVANCE'], str(acts)[:200])
rpc('ack_video_advance', {"p_job_id": job})
rel = assemble(job)
check('the short is assembled and released', jstep(job) >= 35, str(jstep(job)) + ' ' + str(rel)[:200])

# ---- 6b. a picture whose check never came back --------------------------------------------
jobc, r, ctx7c, _ = upto_script('short-check')
check('the topic prompt lists the short made before', 'Recent shorts, newest first: [{' in ctx7c['prompt_text'] and '"pattern": "DONT_OPEN_IT"' in ctx7c['prompt_text'] and '"title": "The Red Box"' in ctx7c['prompt_text'], ctx7c['prompt_text'][ctx7c['prompt_text'].find('Recent shorts'):][:300])
r = save_shots(jobc, short_shots()); assert r['accepted'], r
rpc('save_artifact', {"p_job_id": jobc, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
rpc('route_revision', {"p_job_id": jobc})
rpc('record_final_director_decision', {"p_job_id": jobc, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
rpc('commit_production_package', {"p_job_id": jobc}); voice(jobc)
w = rpc('next_keyframe_work', {"p_job_id": jobc}); assert w['count'] == 3, w
putpub(w['items'][0]['storage_path']); rpc('register_keyframe', {"p_keyframe_id": w['items'][0]['keyframe_id'], "p_storage_path": w['items'][0]['storage_path']})
w1 = rpc('next_keyframe_work', {"p_job_id": jobc})
check('a fresh unchecked picture waits', w1['count'] == 0 and w1['awaiting_review'] == 1 and w1['waiting'] == 2, str(w1)[:200])
check('restart address while a check is open: the keyframe scenario', resume(jobc) == f'https://hook.example/kare?job_id={jobc}', resume(jobc))
sql(f"update public.shot_keyframes set handed_out_at = now() - interval '20 minutes' where job_id = '{jobc}'")
w2 = rpc('next_keyframe_work', {"p_job_id": jobc})
check('stale work is handed out again; the unchecked picture is redrawn', [(i['shot_code'], i['take_no']) for i in w2['items']] == [('SH01', 2), ('SH02', 1), ('SH03', 1)]
      and one(f"select status||'/'||note from public.shot_keyframes where id = '{w['items'][0]['keyframe_id']}'") == 'FAILED/The automatic check never arrived.', str(w2)[:300])
rpc('cancel_production_job', {"p_job_id": jobc, "p_actor": "TEST", "p_reason": "x"})
w3 = rpc('next_keyframe_work', {"p_job_id": jobc})
check('a cancelled job draws nothing', w3['count'] == 0 and w3['shots'] == 0, str(w3)[:200])

# ---- 6c. the owner overrules the automatic check ---------------------------------------------
jobo, r, _, _ = upto_script('short-owner')
r = save_shots(jobo, short_shots()); assert r['accepted'], r
rpc('save_artifact', {"p_job_id": jobo, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
rpc('route_revision', {"p_job_id": jobo})
rpc('record_final_director_decision', {"p_job_id": jobo, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
rpc('commit_production_package', {"p_job_id": jobo}); voice(jobo)
sql("update public.system_settings set value_numeric = 1 where key = 'max_keyframe_takes'")
w = rpc('next_keyframe_work', {"p_job_id": jobo}); assert w['count'] == 3, w
outs = []
for i, verdict in zip(w['items'], ('FAIL', 'FAIL', 'PASS')):
    putpub(i['storage_path']); rpc('register_keyframe', {"p_keyframe_id": i['keyframe_id'], "p_storage_path": i['storage_path']})
    outs.append(rpc('apply_keyframe_check', {"p_keyframe_id": i['keyframe_id'], "p_result": {"verdict": verdict, "score": 75, "notes": "A letter T on the jacket."}}))
t = outs[-1]['owner_text']
check('out of takes: the owner gets the reason and the picture', 'SH01: A letter T on the jacket.' in t and BASE + '/object/public/public-refs/' + w['items'][0]['storage_path'] in t and 'SH02: A letter T' in t and 'SH03:' not in t, t)
rc, o = owner(f"select public.decide_keyframes('{jobo}', 'APPROVE', 'OWNER')"); d = json.loads(o)
check('a general approval does not take what the check turned down', d['changed'] == 1 and d['shots_without_approved_frame'] == 2, o[:300])
rc, o = owner(f"select public.decide_keyframes('{jobo}', 'APPROVE', 'OWNER', '[\"SH01\"]'::jsonb)"); d = json.loads(o)
check('named by its code, the owner takes it anyway', d['changed'] == 1 and d['shots_without_approved_frame'] == 1, o[:300])
rc, o = owner(f"select public.decide_keyframes('{jobo}', 'REJECT', 'OWNER', '[\"SH02\"]'::jsonb, 'Plain jacket, no letter.')"); d = json.loads(o)
check('or sends it back with his own reason', d['changed'] == 1, o[:300])
w = rpc('next_keyframe_work', {"p_job_id": jobo})
check('and it is drawn again although the takes were used up', [(i['shot_code'], i['take_no']) for i in w['items']] == [('SH02', 2)] and 'Plain jacket, no letter.' in w['items'][0]['prompt'], str(w)[:300])
sql("update public.system_settings set value_numeric = 3 where key = 'max_keyframe_takes'")
jobr = start('short-recent')
rpc('save_artifact', {"p_job_id": jobr, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
def recent(): 
    p_ = rpc('get_job_context', {"p_job_id": jobr})['prompt_text']
    return p_[p_.find('Recent shorts, newest first:'):].split('\n')[0].count('"pattern"')
n1 = recent()
rpc('cancel_production_job', {"p_job_id": jobo, "p_actor": "TEST", "p_reason": "x"})
n2 = recent()
check('a cancelled short is not among the recent ones', n1 >= 2 and n2 == n1 - 1, f'{n1} -> {n2}')
rpc('cancel_production_job', {"p_job_id": jobr, "p_actor": "TEST", "p_reason": "x"})

many = short_shots(); many['shots'][1]['beats'].extend([{"at": 1.6, "what": "Both children lean in over the box"}, {"at": 2.4, "what": "The lid drops shut with a bang"}])
sql("update public.system_flags set value = false where key in ('keyframe_required', 'camera_plan_enforced', 'short_format_enforced')")
old = short_shots()
for s_ in old['shots']:
    for k in ('camera_angle', 'camera_move', 'first_frame'): s_.pop(k)
script_old = copy.deepcopy(SHORT_SCRIPT)
for k in ('loop', 'music_mood', 'pattern', 'sfx'): script_old.pop(k)
job2, r, _, _ = upto_script('short-off', script_old)
check('flags off: script without loop accepted', r['accepted'] is True, details(r)[:300])
for k in ('camera_angle', 'camera_move', 'first_frame'): many['shots'][1].pop(k, None)
old['shots'][1]['beats'] = many['shots'][1]['beats']
r = save_shots(job2, old)
check('flags off: shots without camera plan and with four beats accepted', r['accepted'] is True, details(r)[:300])
rpc('save_artifact', {"p_job_id": job2, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
rpc('route_revision', {"p_job_id": job2})
rpc('record_final_director_decision', {"p_job_id": job2, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
rpc('commit_production_package', {"p_job_id": job2}); voice(job2)
ep2 = one(f"select episode_id from public.production_jobs where id='{job2}'")
first = one(f"select id from public.shots where episode_id='{ep2}' order by shot_order limit 1")
check('flags off: nothing to draw', rpc('next_keyframe_work', {"p_job_id": job2})['reason'] == 'KEYFRAMES_OFF', '')
sx, _ = run_shot(first)
px = json.loads(sx['provider_request_text'])['input']
check('flags off: the old request', px['prompt'].startswith('Reference images: @image_1 is Fatih, @image_2 is Mia') and len(px['images']) == 2 and 'start frame' not in px['prompt'], px['prompt'][:200])

# ---- 8. the migration again on a database in use ----------------------------------------
before = one("select (select count(*) from public.shot_keyframes)||'/'||(select string_agg(prompt_code||version, ',' order by prompt_code) from public.step_prompts where is_active)||'/'||(select string_agg(value::text, ',' order by key) from public.system_flags where key in ('keyframe_required','camera_plan_enforced','short_format_enforced'))||'/'||(select value_numeric from public.system_settings where key='max_parallel_video_attempts')")
rc, err = apply('012_short_format.sql'); check('012 applies on a database in use', rc == 0, err[:400])
after = one("select (select count(*) from public.shot_keyframes)||'/'||(select string_agg(prompt_code||version, ',' order by prompt_code) from public.step_prompts where is_active)||'/'||(select string_agg(value::text, ',' order by key) from public.system_flags where key in ('keyframe_required','camera_plan_enforced','short_format_enforced'))||'/'||(select value_numeric from public.system_settings where key='max_parallel_video_attempts')")
check('data, prompts, flags and settings unchanged', before == after, before + ' -> ' + after)
check('service role may call the four keyframe functions', one("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('next_keyframe_work','register_keyframe','apply_keyframe_check','fail_keyframe','prepare_shot_attempt') and has_function_privilege('service_role', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')") == '5')
summary()
