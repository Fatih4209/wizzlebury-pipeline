"""009: what a shot package has to look like before it is accepted."""
from flow import *
import copy
sql("update public.system_settings set value_numeric = 50 where key = 'max_active_jobs'")

def to_shots(key):
    job = start(key)
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TREND_REPORT", "p_producer": "GROK", "p_content": TREND})
    rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "TOPIC_SELECTION", "p_producer": "CLAUDE", "p_content": TOPIC})
    rpc('record_policy_check', {"p_job_id": job, "p_gate_no": 1, "p_checker": "CLAUDE", "p_result": POLICY_PASS})
    rpc('get_series_bible', {"p_job_id": job})
    r = rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SCRIPT", "p_producer": "CLAUDE", "p_content": SCRIPT}); assert r['accepted'] and r['step_no'] == 11, r
    return job
def save(job, pkg):
    return rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "SHOT_PACKAGE", "p_producer": "OPENAI", "p_content": pkg})
def details(r): return ' | '.join(i['ref'] + ': ' + i['detail'] for i in r.get('issues', []))

# what the writers are told
job = to_shots('r-1')
fmt = json.loads(rpc('get_job_context', {"p_job_id": job})['series_bible_text'])['format']
check('bible: cast limit and the three shot rules', fmt['max_characters_per_shot'] == 3 and 'at most 3 characters' in fmt['shot_cast_rule'] and 'every shot of the episode' in fmt['shot_package_rule'] and 'no codes' in fmt['video_prompt_rule'], str(fmt)[:300])

# the live failure of 9 Oct: only one of two scenes came back
one_shot = shots(); one_shot['shots'] = one_shot['shots'][:1]; one_shot['total_duration_seconds'] = 5
r = save(job, one_shot)
check('a package without a shot for scene 2 is sent back and says so', r['accepted'] is False and 'scene 2: Scene 2 of the script has no shot.' in details(r) and any('complete shot package' in i['fix'] for i in r['issues']), details(r))
ctx = rpc('get_job_context', {"p_job_id": job}); check('the writer is told which scene is missing', 'Scene 2 of the script has no shot' in ctx['preqc_report_text'])

# template left in, codes in the prompt, too short
bad = shots()
bad['shots'][0]['video_prompt'] = '<PROMPT: Premium stylized cinematic 3D animation of Fatih in the park; characters have FATIH_CANONICAL_V1; lighting: soft daylight; camera: establishing shot; tone: warm.>'
bad['shots'][1]['video_prompt'] = 'CHR_MIA laughs.'
r = save(job, bad); d = details(r)
check('placeholder brackets refused', 'shot 1: video_prompt contains angle brackets' in d, d)
check('asset names refused', 'shot 1: video_prompt contains codes or asset names' in d, d)
check('character codes refused', 'shot 2: video_prompt contains codes or asset names' in d, d)
check('a one-line prompt is too short', 'shot 2: video_prompt is only 15 characters long; at least 120 are needed.' in d, d)
check('two failed format checks: still at 11, not blocked', r['state'] == 'READY' and r['step_no'] == 11, str(r)[:200])

# a clean package is accepted and the count of failed checks starts again
r = save(job, shots()); check('complete, descriptive package accepted', r['accepted'] is True and r['step_no'] == 12, str(r)[:300])
check('failed-check count back to zero', one(f"select validation_retry_count from public.production_jobs where id='{job}'") == '0')
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_SHOTS})
r = rpc('route_revision', {"p_job_id": job}); assert r['step_no'] == 11, r
r = save(job, one_shot); check('after a review round a bad package is a first failure again, not the end', r['accepted'] is False and r['state'] == 'READY' and r['step_no'] == 11, str(r)[:300])
r = save(job, one_shot); check('second failure in the round: still open', r['state'] == 'READY', str(r)[:200])
r = save(job, one_shot); check('third failure in a row blocks', r['state'] == 'BLOCKED' and r['blocked_reason'] == 'VALIDATION_RETRY_LIMIT_REACHED', str(r)[:200])
rpc('cancel_production_job', {"p_job_id": job, "p_actor": "OWNER", "p_reason": "test"})

# cast
job = to_shots('r-2')
crowd = shots(); crowd['shots'][1]['characters'] = ['CHR_MIA', 'CHR_FATIH', 'CHR_BRUCE', 'CHR_OMER']
r = save(job, crowd); check('four characters in one shot refused', r['accepted'] is False and 'shot 2: 4 characters are in this shot; at most 3 can be shown.' in details(r), details(r))
mute = shots(); mute['shots'][1]['characters'] = ['CHR_FATIH']
r = save(job, mute); check('a speaker who is not in the shot is refused', r['accepted'] is False and 'shot 2: Line 1 is spoken by Mia, who is not listed in characters of this shot.' in details(r) and len(r['issues']) == 1, details(r))
three = shots(); three['shots'][1]['characters'] = ['Mia', 'Fatih', 'Tombik', 'CHR_MIA']
r = save(job, three); check('three characters (names or codes, repeats ignored) accepted', r['accepted'] is True, details(r))
sql("update public.system_settings set value_numeric = 2 where key = 'max_characters_per_shot'")
job3 = to_shots('r-3'); r = save(job3, three); check('the limit is a setting', r['accepted'] is False and 'at most 2 can be shown' in details(r), details(r))
sql("update public.system_settings set value_numeric = 3 where key = 'max_characters_per_shot'")

# the stored generation prompt: scene first, look next, written character descriptions last
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
rpc('route_revision', {"p_job_id": job})
rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
rpc('commit_production_package', {"p_job_id": job})
ep = one(f"select episode_id from public.production_jobs where id='{job}'")
p1 = one(f"select ss.generation_prompt from public.shot_specifications ss join public.shots s on s.id=ss.shot_id where s.episode_id='{ep}' and s.shot_order=1")
p2 = one(f"select ss.generation_prompt from public.shot_specifications ss join public.shots s on s.id=ss.shot_id where s.episode_id='{ep}' and s.shot_order=2")
order = [p1.find(x) for x in ('A boy runs', 'Action: ', 'Acting: ', 'Camera: ', 'Vertical 9:16 framing.', 'Style. ', 'Location. ', 'Characters. ')]
check('prompt order: scene, action, acting, camera, framing, style, location, characters', all(o >= 0 for o in order) and order == sorted(order), str(order))
check('prompt ends with the character descriptions', p1.rstrip()[-1:] != '' and p1.rfind('Characters. ') > p1.rfind('Style. '))
chars = p2[p2.find('Characters. '):]
check('three characters: each written description kept short', all(n in chars for n in ('Fatih: ', 'Mia: ', 'Tombik: ')) and len(chars) <= len('Characters. ') + 3 * (150 + 12), str(len(chars)))
check('three reference images recorded for the three characters', one(f"select count(*) from public.shot_reference_assets sra join public.shot_specifications ss on ss.id=sra.shot_specification_id join public.shots s on s.id=ss.shot_id where s.episode_id='{ep}' and s.shot_order=2 and sra.reference_role='CHARACTER'") == '3')
summary()
