"""Model outputs shaped exactly as the Make prompts ask for them."""
TREND = {"trends": [{"topic": "lost kite", "why_it_fits": "simple visual payoff", "format_hook": "kite stuck", "audience": "kids", "risk_notes": "", "confidence": 0.8}], "avoid": ["brands"], "summary": "kites"}
TOPIC = {"title": "The Kite That Would Not Land", "premise": "Fatih and Mia chase a kite across the park.", "source_trend": "lost kite", "characters": ["CHR_FATIH", "CHR_MIA"], "location": "LOC_NEIGHBORHOOD_PARK", "emotional_beat": "joy", "hook": "kite dives", "target_duration_seconds": 10, "rationale": "fits", "rejected_alternatives": []}
POLICY_PASS = {"verdict": "PASS", "categories": [], "findings": [], "required_changes": [], "notes": "fine"}
POLICY_FAIL = {"verdict": "PASS", "categories": ["dangerous behaviour"], "findings": [{"category": "dangerous behaviour", "severity": "HIGH", "detail": "climbing a pylon"}], "required_changes": ["no pylon"], "notes": ""}
SCRIPT = {"title": "The Kite That Would Not Land", "logline": "A kite refuses to come down.", "total_duration_seconds": 10,
          "hook": "A red kite dives straight at the camera while Fatih yelps and runs after it.", "payoff": "Mia catches the string with one hand and laughs.",
          "scenes": [{"scene_no": 1, "location": "LOC_NEIGHBORHOOD_PARK", "duration_seconds": 5, "action": "Fatih runs with a kite; it dives.",
                      "dialogue": [{"line_no": 1, "character": "CHR_FATIH", "text": "It's \"alive\"!\nCatch it!", "emotion": "excited", "estimated_seconds": 2}], "sound_notes": "wind"},
                     {"scene_no": 2, "location": "LOC_NEIGHBORHOOD_PARK", "duration_seconds": 5, "action": "Mia catches the string and laughs.",
                      "dialogue": [{"line_no": 1, "character": "Mia", "text": "Got it!", "emotion": "happy", "estimated_seconds": 1}], "sound_notes": ""}],
          "revision_notes": ""}
def beats(d, first, rest, lines=None):
    """Whole-second beats for a d-second shot: a hook-sized first beat, then beats of at most 4 s."""
    d = int(d); out = []; t = 0; n = 1
    step = min(2, d)
    while t < d:
        out.append({"beat_no": n, "start": t, "end": t + step, "shot_size": "CLOSE_UP" if n % 2 else "WIDE", "camera": "static", "description": first if n == 1 else rest, "dialogue_line_nos": (lines or []) if n == 1 else []})
        t += step; n += 1; step = min(4, d - t)
    return out

def shots(d1=5, d2=5):
    return {"shots": [{"shot_no": 1, "scene_no": 1, "duration_seconds": d1, "aspect_ratio": "9:16", "characters": ["CHR_FATIH"], "location": "LOC_NEIGHBORHOOD_PARK", "reference_assets": ["FATIH_CANONICAL_V1"], "camera": "wide tracking shot", "action": "Fatih runs, kite dives", "acting": "wide-eyed", "dialogue_line_nos": [1], "video_prompt": "A boy runs across a sunny park pulling a red kite that suddenly dives. Wide tracking shot; he looks up, eyes wide, mouth open, arms stretched toward the string.", "negative_prompt": "blur", "continuity_notes": "red kite", "beats": beats(d1, "The red kite dives straight toward the camera and fills the frame, string whipping.", "Fatih sprints after it across the grass, eyes wide, mouth open, arms stretched out.", [1])},
                      {"shot_no": 2, "scene_no": 2, "duration_seconds": d2, "aspect_ratio": "9:16", "characters": ["CHR_MIA", "CHR_FATIH"], "location": "LOC_NEIGHBORHOOD_PARK", "reference_assets": [], "camera": "close-up on hands then face", "action": "Mia grabs the string", "acting": "laughing", "dialogue_line_nos": [1], "video_prompt": "A girl catches a kite string and laughs. Close-up on her hands closing around the string, then her face: bright grin, sparkling eyes, hair moving in the wind.", "negative_prompt": "", "continuity_notes": "", "beats": beats(d2, "Mia's hands shoot up and close around the kite string, knuckles tight, string taut.", "Mia throws her head back and laughs, bright grin, hair moving in the wind.", [1])}],
            "hook": "A red kite dives straight at the camera.", "total_duration_seconds": d1 + d2, "continuity_risks": []}
PREQC_PASS = {"verdict": "PASS", "issues": [], "continuity_status": "PASS", "character_identity_status": "PASS", "lip_sync_status": "READY", "notes": ""}
PREQC_SHOTS = {"verdict": "REVISE_SHOTS", "issues": [{"target": "SHOTS", "ref": "shot 2", "severity": "MEDIUM", "detail": "framing unclear", "fix": "medium shot"}], "continuity_status": "PASS", "character_identity_status": "PASS", "lip_sync_status": "READY", "notes": ""}
PREQC_SCRIPT = {"verdict": "REVISE_SCRIPT", "issues": [{"target": "SCRIPT", "ref": "scene 1", "severity": "HIGH", "detail": "line too long", "fix": "shorten"}], "continuity_status": "PASS", "character_identity_status": "PASS", "lip_sync_status": "READY", "notes": ""}
DIRECTOR_APPROVE = {"decision": "APPROVE", "director_notes": "Good.", "required_changes": [], "child_safety_status": "PASS", "production_ready": True}
MUSIC_EMPTY = {"tracks": [], "notes": "library empty"}
VISUAL_PASS = {"verdict": "PASS", "score": 0.86, "notes": "ok", "details": {"character_identity": "PASS", "anatomy": "PASS", "motion": "PASS", "prompt_adherence": "PASS", "continuity": "PASS", "lip_sync": "NOT_APPLICABLE", "artifacts": "PASS", "child_safety": "PASS"}}
VISUAL_FAIL = {"verdict": "FAIL", "score": 0.3, "notes": "extra arm", "details": {"character_identity": "PASS", "anatomy": "FAIL", "motion": "PASS", "prompt_adherence": "PASS", "continuity": "PASS", "lip_sync": "NOT_APPLICABLE", "artifacts": "FAIL", "child_safety": "PASS"}}
FINAL_PASS = {"verdict": "PASS", "score": 0.9, "notes": "", "details": {"dialogue_match": "PASS", "lip_sync": "PASS", "audio_mix": "PASS", "edit_order": "PASS", "character_consistency": "PASS", "visual_artifacts": "PASS", "duration_and_format": "PASS", "child_safety": "PASS"}}
FINAL_FAIL = {"verdict": "FAIL", "score": 0.4, "notes": "audio drift", "details": {"dialogue_match": "FAIL", "lip_sync": "FAIL", "audio_mix": "PASS", "edit_order": "PASS", "character_consistency": "PASS", "visual_artifacts": "PASS", "duration_and_format": "PASS", "child_safety": "PASS"}}
RELEASE_APPROVE = {"decision": "APPROVE", "notes": "ship", "required_changes": []}
METADATA = {"candidates": [{"candidate_no": 1, "title": "The Kite That Would Not Land", "description": "A kite with a mind of its own. #Shorts #animation", "tags": ["kite", "animation", "kids"], "angle": "funny"}]}
PACKAGE = {"title": "The Kite That Would Not Land", "description": "A kite with a mind of its own. #Shorts", "tags": ["kite", "animation", "kids", "wizzlebury"], "language": "en", "selected_candidate_no": 1, "rationale": "accurate"}
REQUEST = {"creative_profile_code": "MICRO_SHORT_PREMIUM_V1", "episode_budget_usd": 10, "shot_budget_usd": 3}
