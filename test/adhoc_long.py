"""A one-minute episode through the whole pipeline with the showcase settings."""
import sys, types
src = open('test_film.py').read().split("# ---- 1. script rules")[0]
exec(src)
sql("""update public.system_settings set value_numeric = v.n from (values ('episode_min_seconds', 50), ('episode_max_seconds', 65), ('min_shots', 16), ('max_shots', 26), ('max_dialogue_lines', 14)) v(k, n) where key = v.k""")
script = copy.deepcopy(FILM_SCRIPT)
lines = ["It's alive!", "Catch it, Mia!", "I am trying!", "Left! No, right!", "You said left!", "It moved!", "Got it!", "No you don't.", "Hold still, kite.", "It likes you.", "It hates me.", "Best kite ever."]
script['scenes'] = []
for sc in range(1, 5):
    script['scenes'].append({"scene_no": sc, "location": "LOC_NEIGHBORHOOD_PARK", "characters": ["CHR_FATIH", "CHR_MIA"], "duration_seconds": 14.5,
        "action": "Fatih on the left runs across the lawn pulling the red kite; it dives at him and he ducks while Mia on the right points and laughs.",
        "dialogue": [{"line_no": i + 1, "character": "CHR_FATIH" if i % 2 == 0 else "CHR_MIA", "text": lines[(sc - 1) * 3 + i], "emotion": "x"} for i in range(3)], "sound_notes": ""})
script['total_duration_seconds'] = 58
sizes = ["INSERT", "WIDE", "CLOSE_UP", "OVER_SHOULDER", "MEDIUM", "EXTREME_CLOSE_UP"]
shots = []; n = 0
for sc in range(1, 5):
    for k in range(6):
        n += 1
        size = sizes[k]
        if k in (1, 3, 4):
            ln = {1: 1, 3: 2, 4: 3}[k]
            speaker = "CHR_FATIH" if ln % 2 == 1 else "CHR_MIA"
            staging = "ON_CAMERA" if size in ("WIDE", "MEDIUM") else "BACK_TO_CAMERA"
            shots.append(shot(n, sc, size, 2.8, ["CHR_FATIH", "CHR_MIA"], [ln], staging))
        else:
            shots.append(shot(n, sc, size, 2.0 if n > 1 else 1.8, ["CHR_MIA"] if k else []))
pkg = {"script_vote": YES, "shots": shots, "total_edit_seconds": 0, "continuity_risks": []}
job, r = upto_script('long-1', script)
assert r['accepted'], details(r)
ctx = rpc('get_job_context', {"p_job_id": job}); print('prompt chars step 11:', len(ctx['prompt_text']))
r = save_shots(job, pkg); assert r['accepted'], details(r)
rpc('save_artifact', {"p_job_id": job, "p_artifact_type": "PREQC_REPORT", "p_producer": "GEMINI", "p_content": PREQC_PASS})
rpc('route_revision', {"p_job_id": job})
rpc('record_final_director_decision', {"p_job_id": job, "p_actor": "CLAUDE", "p_result": DIRECTOR_APPROVE})
c = rpc('commit_production_package', {"p_job_id": job}); print('commit', c.get('shots'), c.get('dialogue_lines'), c.get('step_no'))
g = voice(job); print('gate2', g.get('passed'), g.get('problems'), g.get('estimated_video_cost'))
rpc('set_generation_enabled', {"p_enabled": True})
video_all_pass(job)
rpc('select_final_audio_track', {"p_job_id": job})
b = rpc('begin_assembly', {"p_job_id": job})
c = rpc('create_render', {"p_job_id": job, "p_signed_urls": sign(b['sign_request_text'])})
tl = json.loads(c['shotstack_request_text'])['timeline']['tracks']
print('clips', len(tl[-1]['clips']), 'voices', len(tl[0]['clips']), 'total', c['total_seconds'], 'request chars', len(c['shotstack_request_text']))
r = assemble_rest = None
