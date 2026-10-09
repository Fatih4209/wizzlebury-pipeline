"""010: film rules, two-yes rule, prompts from the database, cuts in the edit."""
from flow import *
import copy

import subprocess
S = '/tmp/claude-0/-home-claude/d675ecd1-6c13-5e11-af28-9459ef5a739d/scratchpad'
def apply(f):
    r = subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', S + '/mig/' + f], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
def owner(q):
    r = subprocess.run(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', q], capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()
sql("update public.system_flags set value = true where key in ('film_grammar_enforced', 'assistant_vote_required')")
sql("update public.system_settings set value_numeric = 50 where key = 'max_active_jobs'; update public.system_settings set value_numeric = 0 where key in ('video_driver_min_interval_seconds', 'video_poll_min_interval_seconds')")
rpc('set_text_setting', {"p_key": "storage_base_url", "p_value": "https://proj.supabase.co/storage/v1"})
rpc('set_text_setting', {"p_key": "notify_chat_id", "p_value": "123456"})
apply('007_kling_setup.sql'); apply('008_kling_omni_refs.sql'); apply('010_film_grammar.sql'); apply('010_film_grammar.sql')
sql("update public.system_flags set value = true where key in ('film_grammar_enforced', 'assistant_vote_required')")
rc, o = owner("select public.set_video_wardrobe('FATIH_CANONICAL_V1', 'Fatih has bright green eyes.', 'TEST')")
check('owner sets a character note', rc == 0 and 'SET' in o, o[:200])
expect_error('the API may not set a character note', 'set_video_wardrobe', {"p_asset_code": "FATIH_CANONICAL_V1", "p_note": "x", "p_actor": "y"}, 'permission denied')

LONG = ("Fatih stands on the left of the frame on the green lawn, Mia on the right near the old oak. "
        "He leans back pulling the string with both hands, eyebrows shooting up, while she bounces on her toes "
        "pointing up at the sky, eyes wide with delight.")
FILM_SCRIPT = {
    "title": "The Kite That Would Not Land", "logline": "A kite refuses to come down.",
    "hook": "A red kite dives straight at the camera and fills the frame while a boy yelps somewhere behind it.",
    "payoff": "Mia holds the kite string in one hand, laughing, while Fatih flops onto the grass.",
    "look": "Late afternoon, clear sky, warm golden light, long soft shadows.",
    "wardrobe": [{"character": "CHR_FATIH", "outfit": "red bomber jacket over a white t-shirt, dark jeans, plain red-and-white sneakers"},
                 {"character": "CHR_MIA", "outfit": "loose turquoise t-shirt, knee-length pink shorts, white sneakers"}],
    "props": [{"name": "kite", "description": "one small red diamond kite with a yellow tail ribbon, exactly one"}],
    "scenes": [
        {"scene_no": 1, "location": "LOC_NEIGHBORHOOD_PARK", "characters": ["CHR_FATIH", "CHR_MIA"], "duration_seconds": 7,
         "action": "Fatih on the left runs across the lawn pulling the red kite; it dives at him and he ducks while Mia on the right points and laughs.",
         "dialogue": [{"line_no": 1, "character": "CHR_FATIH", "text": "It's alive! Catch it!", "emotion": "panicked"},
                      {"line_no": 2, "character": "CHR_MIA", "text": "Got it!", "emotion": "happy"}], "sound_notes": "wind"},
        {"scene_no": 2, "location": "LOC_NEIGHBORHOOD_PARK", "characters": ["CHR_FATIH", "CHR_MIA"], "duration_seconds": 6,
         "action": "Mia on the right calmly catches the string with one hand; Fatih on the left flops onto the grass, out of breath, and grins.",
         "dialogue": [{"line_no": 1, "character": "CHR_FATIH", "text": "Best kite ever.", "emotion": "exhausted"}], "sound_notes": ""}],
    "total_duration_seconds": 13, "revision_notes": ""}

def shot(no, scene, size, edit, chars, lines=None, staging="", props=None, what="The kite dives toward the camera"):
    return {"shot_no": no, "scene_no": scene, "purpose": "ACTION", "shot_size": size, "camera": "static", "duration_seconds": 5,
            "edit_seconds": edit, "aspect_ratio": "9:16", "characters": chars, "location": "LOC_NEIGHBORHOOD_PARK",
            "props": props if props is not None else ["kite"],
            "beats": [{"at": 0.0, "what": what}, {"at": 0.6, "what": "Eyes go wide and the eyebrows shoot up"}],
            "dialogue_line_nos": lines or [], "voice_staging": staging, "action": "one clear action", "acting": "wide-eyed",
            "video_prompt": LONG, "negative_prompt": "blur", "continuity_notes": "Fatih left, Mia right"}

YES = {"decision": "YES", "scores": {"hook": 8, "story": 8, "humor": 7, "dialogue": 8, "filmability": 9},
       "strengths": ["clear hook"], "problems": [], "required_changes": []}
NO = {"decision": "NO", "scores": {"hook": 4, "story": 6, "humor": 5, "dialogue": 6, "filmability": 8},
      "strengths": ["simple"], "problems": ["The hook is a boy running; nothing is at stake yet."],
      "required_changes": ["Open on the kite diving at the camera."]}

def film_shots(vote=None):
    return {"script_vote": vote or YES, "shots": [
        shot(1, 1, "INSERT", 1.5, []),
        shot(2, 1, "WIDE", 3.2, ["CHR_FATIH", "CHR_MIA"], [1], "ON_CAMERA"),
        shot(3, 1, "CLOSE_UP", 1.0, ["CHR_MIA"]),
        shot(4, 1, "OVER_SHOULDER", 1.6, ["CHR_MIA", "CHR_FATIH"], [2], "BACK_TO_CAMERA"),
        shot(5, 2, "MEDIUM", 2.2, ["CHR_MIA"]),
        shot(6, 2, "CLOSE_UP", 2.2, ["CHR_MIA"], [1], "OFF_SCREEN", props=[])],
        "total_edit_seconds": 11.7, "continuity_risks": []}

def upto_script(key, script=None):
    job = start(key, {"creative_profile_code": "MICRO_SHORT_PREMIUM_V1", "episode_budget_usd": 30, "shot_budget_usd": 2} if key.startswith("long") else None)
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
    rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS})
    rpc('get_series_bible', {"p_job_id": job})
    r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": script or FILM_SCRIPT})
    return job, r
def save_shots(job, pkg):
    return rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": pkg})
def details(r):
    return ' | '.join(i['detail'] for i in r.get('issues', []))
def jstep(job):
    return int(one(f"select current_step from public.production_jobs where id='{job}'"))

# ---- 1. script rules ---------------------------------------------------
job, r = upto_script('film-old', SCRIPT)
d = details(r)
check('old script refused', r['accepted'] is False, str(r)[:200])
for needle in ('look is missing', 'no wardrobe array', 'no props array', 'characters array', 'too thin to film'):
    check(f'old script: {needle}', needle in d, d[:400])
bad = copy.deepcopy(FILM_SCRIPT)
bad['scenes'][0]['dialogue'][0]['text'] = "It is alive and it is coming straight for my head right now, catch it please!"
bad['wardrobe'] = bad['wardrobe'][:1]
bad['props'][0]['description'] = 'a kite'
r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": bad}); d = details(r)
check('long line refused', 'spoken inside one cut' in d, d[:400])
check('undressed character refused', 'CHR_MIA appears in the episode but has no outfit' in d, d[:400])
check('vague prop refused', 'description is too vague' in d, d[:400])
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "TEST", "p_reason": "x"})

# ---- 2. prompts from the database --------------------------------------
job, r = upto_script('film-1')
check('film script accepted', r['accepted'] is True and jstep(job) == 11, str(r)[:300])
ctx = rpc('get_job_context', {"p_job_id": job})
p = ctx['prompt_text']
check('step 11 prompt present', 'PART 1 - YOUR VOTE' in p and 'The Kite That Would Not Land' in p, p[:200])
check('prompt has no open placeholder', '[[' not in p, p[p.find('[['):][:60] if '[[' in p else '')
check('prompt carries the limits', '5 to 7 shots' in p and 'at most 2.5 seconds' in p, '')
check('two_yes starts empty', '"assistant_director": false' in ctx['two_yes_text'] and '"head_director": false' in ctx['two_yes_text'], ctx['two_yes_text'])
bible = json.loads(ctx['series_bible_text'])['format']
check('bible carries the film format', bible.get('shots_max') == 7 and 'ON_CAMERA' in bible.get('voice_stagings', []) and 'total_duration_seconds_hard_max' not in bible, str(bible)[:300])

# ---- 3. two-yes: the Assistant Director's vote -------------------------
pkg = film_shots(); del pkg['script_vote']
r = save_shots(job, pkg)
check('missing vote refused', r['accepted'] is False and 'script_vote is missing' in details(r), str(r)[:300])
check('missing vote stays at step 11', jstep(job) == 11, str(jstep(job)))
r = save_shots(job, {"script_vote": NO, "shots": []})
check('NO sends the script back', r['accepted'] is False and r['script_vote'] == 'NO' and jstep(job) == 10, str(r)[:300])
ctx = rpc('get_job_context', {"p_job_id": job}); p = ctx['prompt_text']
check('writer sees the rejection', 'Open on the kite diving at the camera.' in p and 'ASSISTANT_DIRECTOR' in p, p[-900:])
check('NO is on record', one(f"select decision||'/'||voter_role from public.script_votes where job_id='{job}'") == 'NO/ASSISTANT_DIRECTOR', '')
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": FILM_SCRIPT})
ctx = rpc('get_job_context', {"p_job_id": job})
check('assistant sees the last rejection', 'Open on the kite diving at the camera.' in ctx['prompt_text'], '')
low = copy.deepcopy(YES); low['scores']['humor'] = 5
r = save_shots(job, film_shots(low))
check('YES with a low score counts as NO', r['script_vote'] == 'NO' and jstep(job) == 10, str(r)[:300])
fb = one(f"select revision_feedback::text from public.production_jobs where id='{job}'")
check('feedback says why', 'below the minimum' in fb, fb[:300])
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": FILM_SCRIPT})
r = save_shots(job, {"script_vote": NO, "shots": []})
check('third NO drops the topic', jstep(job) == 7 and r['state'] == 'READY', str(r)[:300])
check('script retired with the topic', one(f"select count(*) from public.job_artifacts where job_id='{job}' and artifact_type in ('SCRIPT','SCRIPT_REVIEW') and is_current") == '0', '')
ctx = rpc('get_job_context', {"p_job_id": job})
check('topic prompt names the dropped topic', 'could not agree on a script' in ctx['prompt_text'] and 'Choose the single best story idea' in ctx['prompt_text'], ctx['prompt_text'][-600:])
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "TEST", "p_reason": "x"})

# topic retries used up -> blocked
job, r = upto_script('film-2')
sql("update public.system_settings set value_numeric = 0 where key in ('max_script_rejections', 'max_topic_retries')")
r = save_shots(job, {"script_vote": NO, "shots": []})
check('no agreement blocks the job', r['state'] == 'BLOCKED' and r['blocked_reason'] == 'SCRIPT_NOT_AGREED', str(r)[:300])
sql("update public.system_settings set value_numeric = 2 where key in ('max_script_rejections', 'max_topic_retries')")
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "TEST", "p_reason": "x"})

# ---- 4. shot rules -------------------------------------------------------
job, r = upto_script('film-3')
def broken(fn):
    pkg = film_shots(); fn(pkg['shots']); return pkg
cases = [
    ('same size twice', lambda s: s[2].update(shot_size='WIDE'), 'same shot_size (WIDE)'),
    ('speaking in a close-up', lambda s: s[5].update(voice_staging='ON_CAMERA', characters=['CHR_MIA', 'CHR_FATIH']), 'nobody speaks in a close shot'),
    ('off-screen speaker listed', lambda s: s[5].update(characters=['CHR_MIA', 'CHR_FATIH']), 'OFF_SCREEN but the speaker'),
    ('speaker missing', lambda s: s[1].update(characters=['CHR_MIA']), 'is not listed in characters'),
    ('staging missing', lambda s: s[1].update(voice_staging=''), 'voice_staging is missing'),
    ('two lines in one shot', lambda s: (s[1].update(dialogue_line_nos=[1, 2]), s[3].update(dialogue_line_nos=[], voice_staging='')), 'at most one is allowed'),
    ('hook too long', lambda s: s[0].update(edit_seconds=3.5), 'the hook must be over'),
    ('cut too short', lambda s: s[2].update(edit_seconds=0.3), 'outside the allowed cut length'),
    ('unknown size', lambda s: s[4].update(shot_size='DUTCH'), 'shot_size is missing or unknown'),
    ('no beats', lambda s: s[4].update(beats=[]), 'has no beats'),
    ('beat outside the cut', lambda s: s[2].update(beats=[{"at": 0, "what": "Mia gasps and covers her mouth"}, {"at": 1.4, "what": "She bursts out laughing"}]), 'has a wrong time'),
    ('unknown prop', lambda s: s[4].update(props=['balloon']), 'Unknown prop: balloon'),
    ('no wide early', lambda s: s[1].update(shot_size='MEDIUM'), 'None of the first three shots is WIDE'),
    ('thin prompt', lambda s: s[4].update(video_prompt='Mia catches the kite string with one hand and smiles at Fatih who is lying on the grass in the park.'), 'at least 200 are needed'),
]
for name, fn_, needle in cases:
    r = save_shots(job, broken(fn_)); d = details(r)
    check(f'shots: {name}', r['accepted'] is False and needle in d, d[:300])
    sql(f"update public.production_jobs set validation_retry_count = 0 where id='{job}'")
    if jstep(job) != 11: sql(f"update public.production_jobs set current_step = 11, state='READY' where id='{job}'")
few = film_shots(); few['shots'] = few['shots'][:4]
r = save_shots(job, few); d = details(r)
check('shots: too few', 'cut from at least 5' in d and 'has no shot' in d, d[:400])
sql(f"update public.production_jobs set validation_retry_count = 0 where id='{job}'")
long_ = film_shots()
for s in long_['shots']: s['edit_seconds'] = 4.0
long_['shots'][0]['edit_seconds'] = 2.0
r = save_shots(job, long_); d = details(r)
check('shots: episode too long', 'The cuts add up to 22' in d, d[:300])
sql(f"update public.production_jobs set validation_retry_count = 0 where id='{job}'")
# a planned cut shorter than its line is lengthened, not refused
short = film_shots(); short['shots'][1]['edit_seconds'] = 1.0
r = save_shots(job, short)
check('short speaking cut is lengthened', r['accepted'] is True, details(r)[:300])
check('assistant YES on record', '"assistant_director": true' in rpc('get_job_context', {"p_job_id": job})['two_yes_text'], '')
ctx = rpc('get_job_context', {"p_job_id": job})
check('pre-QC prompt from the database', 'Pre-Production QC Inspector' in ctx['prompt_text'] and '[[' not in ctx['prompt_text'], '')
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_SHOTS})
rpc('route_revision', {"p_job_id": job})
check('pre-QC sends the shots back', jstep(job) == 11, str(jstep(job)))
r = save_shots(job, film_shots())
check('revised shots accepted', r['accepted'] is True, details(r)[:300])
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
rpc('route_revision', {"p_job_id": job})
ctx = rpc('get_job_context', {"p_job_id": job})
check('director prompt shows the review', 'second YES of the two-yes rule' in ctx['prompt_text'] and '"filmability": 9' in ctx['prompt_text'], ctx['prompt_text'][:200])

# ---- 5. two-yes: the Head Director and the commit -----------------------
sql(f"update public.script_votes set decision = 'NO' where job_id='{job}' and voter_role='ASSISTANT_DIRECTOR'")
expect_error('approval needs the assistant YES', 'record_final_director_decision',
             {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE}, 'DIRECTOR_APPROVAL_REQUIRES_ASSISTANT_YES')
sql(f"update public.script_votes set decision = 'YES' where job_id='{job}' and voter_role='ASSISTANT_DIRECTOR'")
rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
check('both votes on record', one(f"select string_agg(distinct voter_role||'='||decision, ',' order by voter_role||'='||decision) from public.script_votes where job_id='{job}' and decision='YES'") == 'ASSISTANT_DIRECTOR=YES,HEAD_DIRECTOR=YES', '')
sql(f"update public.script_votes set decision = 'NO' where job_id='{job}' and voter_role='HEAD_DIRECTOR'")
expect_error('commit needs two YES', 'commit_production_package', {"p_job_id": job}, 'TWO_YES_REQUIRED')
sql(f"update public.script_votes set decision = 'YES' where job_id='{job}' and voter_role='HEAD_DIRECTOR'")
c = rpc('commit_production_package', {"p_job_id": job})
check('commit: 6 shots, 3 lines', c.get('shots') == 6 and c.get('dialogue_lines') == 3, str(c)[:300])
ep = one(f"select episode_id from public.production_jobs where id='{job}'")
def spec(code, col):
    return one(f"select ss.{col} from public.shots s join public.shot_specifications ss on ss.shot_id=s.id and ss.is_active where s.episode_id='{ep}' and s.shot_code='{code}'")
check('spec keeps the cut', spec('SH02', 'edit_seconds') == '3.2' and spec('SH02', 'duration_seconds') == '5', spec('SH02', 'edit_seconds'))
check('spec keeps size and staging', spec('SH04', 'film_size') == 'OVER_SHOULDER' and spec('SH04', 'voice_staging') == 'BACK_TO_CAMERA' and spec('SH03', 'voice_staging') == '', spec('SH04', 'film_size'))
check('off-screen speaker is not in the shot', spec('SH06', 'character_codes::text') == '["CHR_MIA"]', spec('SH06', 'character_codes::text'))
p2 = spec('SH02', 'generation_prompt')
for needle in ('Wide shot: full bodies', 'Timing: at 0.0 s', 'within the first 3.5 seconds', 'Fatih is talking from the first moment',
               'Wardrobe in this episode, the same in every shot: Fatih wears red bomber jacket', 'Mia wears loose turquoise t-shirt',
               'Props, exactly as described and no extra copies: one small red diamond kite', 'Look: Late afternoon',
               'All the children are the same age and the same height'):
    check(f'prompt: {needle[:32]}', needle in p2, p2[:900])
p3 = spec('SH03', 'generation_prompt')
check('silent shot: nobody speaks', 'Nobody speaks in this shot' in p3 and 'Fatih wears' not in p3, p3[:500])
check('back to camera wording', 'Mia is talking but is seen only from behind' in spec('SH04', 'generation_prompt'), '')
check('off-screen wording', 'A voice is heard from off-screen' in spec('SH06', 'generation_prompt'), '')
check('prompt inside the limit', all(len(spec(f'SH0{i}', 'generation_prompt')) <= 2400 for i in range(1, 7)), '')

# ---- 6. voice fits the cut ------------------------------------------------
n = 0
while True:
    r = rpc('list_voice_work', {"p_job_id": job})
    if not r['items']: break
    for it in r['items']:
        n += 1
        size = 80000 if (n == 1) else 48000 if 'SH04' in it['storage_path'] else 24000
        put(it['storage_path'], size)
        t = rpc('register_voice_take', {"p_line_id": it['line_id'], "p_action": it['action'], "p_storage_path": it['storage_path'], "p_mp3_bitrate_kbps": 128})
        v = rpc('apply_voice_qc', {"p_take_id": t['take_id'], "p_verdict": "PASS", "p_score": None})
        if n == 1:
            check('a 5 s take does not fit a cut', v.get('qc_status') == 'FAIL' or v.get('verdict') == 'FAIL' or 'FAIL' in str(v), str(v)[:300])
check('every line has a voice', one(f"select count(*) from public.shot_audio_productions sap join public.shot_specifications ss on ss.id=sap.shot_specification_id join public.shots s on s.id=ss.shot_id where s.episode_id='{ep}' and sap.is_canonical") == '3', '')
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "MUSIC_SFX_PLAN", "p_producer": "CLAUDE", "p_content": MUSIC_EMPTY})
rpc('check_music_licenses', {"p_job_id": job})
g = rpc('evaluate_budget_gate', {"p_job_id": job, "p_gate_no": 2})
check('budget gate 2', g.get('passed') is True, str(g)[:300])

# ---- 7. video: the reviewer's brief, the retry, the cuts -------------------
rpc('set_generation_enabled', {"p_enabled": True})
shot_ids = one(f"select string_agg(id::text, ',' order by shot_order) from public.shots where episode_id='{ep}'").split(',')
s, (poll, outp, q) = run_shot(shot_ids[0], VISUAL_FAIL)
brief = json.loads(outp['qc_context_text'])
check('reviewer gets the film brief', brief.get('film', {}).get('shot_size') == 'INSERT' and 'first 2.0 seconds' in brief['film']['used_seconds'] and brief['film']['props'][0]['name'] == 'kite', str(brief.get('film'))[:400])
s2, (poll, outp, q) = run_shot(shot_ids[0], dict(VISUAL_PASS, details=dict(VISUAL_PASS['details'], action_start_seconds=1.0)))
req = json.loads(s2['provider_request_text'])
prompt = req['input']['prompt'] if 'input' in req else req['instances'][0]['prompt']
check('retry carries the correction', 'Correction: an earlier take of this shot was rejected because: extra arm' in prompt, prompt[:600])
first = json.loads(s['provider_request_text'])['input']['prompt']
check('first take has no correction', 'Correction:' not in first, first[:300])
p2r = [json.loads(a['provider_request_text'])['input'] for a in []]
for i, sid in enumerate(shot_ids[1:]):
    sx, _ = run_shot(sid)
    if i == 0:
        inp = json.loads(sx['provider_request_text'])['input']
        check('request: references, note and wardrobe', inp['prompt'].startswith('Reference images: @image_1 is Fatih, @image_2 is Mia') and 'Fatih has bright green eyes.' in inp['prompt'] and 'the outfit follows the wardrobe given below' in inp['prompt'] and len(inp['images']) == 2 and inp['duration'] == 5 and len(inp['prompt']) <= 2500, inp['prompt'][:500])
acts = actions()
check('video complete', [a['action'] for a in acts] == ['ADVANCE'], str(acts)[:200])
rpc('ack_video_advance', {"p_job_id": job})
rpc('select_final_audio_track', {"p_job_id": job})
b = rpc('begin_assembly', {"p_job_id": job})
c = rpc('create_render', {"p_job_id": job, "p_signed_urls": sign(b['sign_request_text'])})
fq = rpc('get_job_context', {"p_job_id": job})['prompt_text']
check('final QC prompt carries the planned edit', 'Final QC Inspector' in fq and 'about 13.6' in fq and '"cut": "SH04"' in fq and '[[' not in fq, fq[fq.find('duration_and_format'):][:200] + fq[fq.find('Planned edit'):][:300])
tl = json.loads(c['shotstack_request_text'])['timeline']['tracks']
video = tl[-1]['clips']; voice = tl[0]['clips']
lens = [v['length'] for v in video]
check('cut lengths: planned, or the voice plus half a second', lens == [1.5, 3.2, 1.0, 3.5, 2.2, 2.2], str(lens))
check('cuts follow each other', [v['start'] for v in video] == [0, 1.5, 4.7, 5.7, 9.2, 11.4], str([v['start'] for v in video]))
check('trim: where the reviewer saw the action start', video[0]['asset'].get('trim') == 0.9 and video[1]['asset'].get('trim') == 0.2, str([v['asset'].get('trim') for v in video]))
check('voices start with their cut', [round(v['start'], 2) for v in voice] == [1.65, 5.85, 11.55], str([v['start'] for v in voice]))
check('voices do not overlap', all(voice[i]['start'] + voice[i]['length'] <= voice[i + 1]['start'] for i in range(len(voice) - 1)), '')
check('total is the sum of the cuts', abs(c['total_seconds'] - 13.6) < 0.001, str(c['total_seconds']))
# a repeated policy gate replaces its earlier result in the context
sql(f"insert into public.policy_checks (job_id, gate_no, checker, verdict, result) values ('{job}', 1, 'CLAUDE', 'FAIL', '{{}}'::jsonb)")
pc = json.loads(rpc('get_job_context', {"p_job_id": job})['policy_checks_text'])
check('only the check in force per gate is shown', len(pc) == 1 and pc[0]['verdict'] == 'FAIL', str(pc)[:200])
summary()
