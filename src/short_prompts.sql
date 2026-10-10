
-- ----- the instructions for the looping short ----------------------------
-- New versions are written as changes to version 1, so the two cannot
-- drift apart unnoticed: a sentence that is no longer found stops the
-- migration instead of being skipped.
create or replace function m417_internal.swap_text(p_body text, p_old text, p_new text)
 returns text language plpgsql immutable set search_path to ''
as $function$
begin
    if position(p_old in p_body) = 0 then
        raise exception 'M417_012_PROMPT_SENTENCE_NOT_FOUND: %', left(p_old, 80);
    end if;
    return replace(p_body, p_old, p_new);
end;
$function$;

do $$
declare
    v text;
    v_converge constant text := $a$Converge. Every revision round costs time, and the package has to be good enough to film well, not perfect. Ask for REVISE_SHOTS only for a defect a viewer would notice in the finished film, or one that would make the video model show the wrong thing. A wording improvement is not a reason to revise: put it in director_notes and APPROVE. If the package was already revised at your request and those changes were made, APPROVE unless a new and serious defect has appeared.

$a$;
begin
    -- TOPIC 2 ----------------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'TOPIC' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: TOPIC';
    end if;
    v := m417_internal.swap_text(v,
        $a$- One character wants something concrete; something gets in the way; it escalates in two or three steps; it ends on a surprise that is funny or warm.$a$,
        $a$- One character wants something concrete; something gets in the way or builds up once; it ends on a surprise that is funny or warm. There is no room for more: the whole short is [[SHOTS_MIN]] to [[SHOTS_MAX]] shots.$a$);
    v := m417_internal.swap_text(v,
        $a$If the production request contains a brief, follow it.$a$,
        $a$THIS FORMAT: A LOOPING SHORT
- One idea, one place, one main object. Two characters carry it; a third may appear only as the surprise at the end.
- It follows one of these patterns; name it in pattern:
  DONT_OPEN_IT - a warning, a slow opening, a harmless funny surprise.
  CAN_HE_DO_IT - a countdown, an attempt, an unexpected result.
  EXPECTATION_FLIP - something built with care, a threat approaches, a different thing happens.
  KINDNESS - someone lacks something, a friend notices, a small warm reward.
  WHO_DID_IT - the evidence, the faces one by one, the least expected culprit.
  COPY_ME - one clear move, the others copy it, the last one adds a funny twist.
  COUNT_AND_JUMP - a rhythm of three, one action on every count, back to one.
  BIG_BUILD_UP - a huge promise, shaking and lights, a tiny result.
  HIDE_AND_PEEK - an empty place, hiding spots found one by one, the last one hides in plain sight.
- The last image leads back to the first, so the short can be watched again and again: the lid falls shut and the box wobbles again, the runner is back at the start line, someone turns to the viewer ("Again!", "Your turn!"). Say how in loop.
- It ends warm. Nobody is humiliated, nobody is hurt.
- Never: strings, ropes, cords, kites or anything tied; more than three of the same object; anything poured, splashed or swum in; mirrors; fine finger work.
- Vary. Do not use the pattern, the lead character or the location of the most recent shorts back to back.

Recent shorts, newest first: [[RECENT]]

If the production request contains a brief, follow it.$a$);
    v := m417_internal.swap_text(v,
        $a$"emotional_beat": "", "hook": "",$a$,
        $a$"emotional_beat": "", "pattern": "", "hook": "", "loop": "",$a$);
    v := m417_internal.swap_text(v,
        $a$premise tells the whole story in three to five sentences: the want, the obstacle, each escalation, the payoff.$a$,
        $a$premise tells the whole story in two or three sentences: the hook, the build-up, the payoff. pattern is one of the pattern names above. loop says how the last image leads back to the first.$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('TOPIC', 2, false, 'Step 7: as version 1, for the looping short - patterns, loop, variety.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- SCRIPT 2 ---------------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SCRIPT' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: SCRIPT';
    end if;
    v := m417_internal.swap_text(v,
        $a$- At most [[LINES_MAX]] spoken lines. Every line is one short sentence of at most [[LINE_CHARS]] characters, spaces included.$a$,
        $a$- At most [[LINES_MAX]] spoken lines, each of at most [[LINE_WORDS]] words and [[LINE_CHARS]] characters, spaces included. A line is something a child would shout in the playground: a warning, a dare, a count, a cheer.$a$);
    v := m417_internal.swap_text(v,
        $a$- Then a clear want, an obstacle, two or three escalations each bigger than the last, a turn nobody expected, and a payoff that answers the hook. End on a short button: one last look, line or gag.$a$,
        $a$- Then one build-up and a payoff that answers the hook. Three movements and nothing more: hook, build-up, payoff. The payoff is a surprise, harmless and warm; nobody is humiliated or hurt.
- loop: the last image leads back to the first, so the short can be watched again and again: the lid falls shut and the box wobbles again, the runner is back at the start line, someone turns to the viewer ("Again!", "Your turn!"). Say how in loop.
- One place, one main object. Two characters carry it; a third may appear only as the surprise at the end.$a$);
    v := m417_internal.swap_text(v,
        $a$- Tell it in pictures. Dialogue is real conversation between the characters: short, quick, back and forth, each line answering the one before; one character never explains the plot.$a$,
        $a$- Tell it in pictures: with the sound off the story is still clear. When two lines are spoken they answer each other; nobody explains the plot.$a$);
    v := m417_internal.swap_text(v,
        $a$WRITE IT SO IT CANNOT BE FILMED WRONG$a$,
        $a$SOUND
- music_mood: the mood of the music that runs from the first frame, one of: [[MUSIC_MOODS]].
- sfx: up to three sound effects, each with the moment it lands on, for example {"at": "the lid pops open", "sound": "pop"}.

WRITE IT SO IT CANNOT BE FILMED WRONG$a$);
    v := m417_internal.swap_text(v,
        $a$tiny hand work such as tying knots.$a$,
        $a$tiny hand work such as tying knots. Never: strings, ropes, cords, kites or anything tied; more than three of the same object; anything poured, splashed or swum in.$a$);
    v := m417_internal.swap_text(v,
        $a${"title": "", "logline": "", "hook": "", "payoff": "", "look": "",$a$,
        $a${"title": "", "logline": "", "pattern": "", "hook": "", "payoff": "", "loop": "", "music_mood": "", "sfx": [{"at": "", "sound": ""}], "look": "",$a$);
    v := m417_internal.swap_text(v,
        $a$Before answering, check: the total is inside the range;$a$,
        $a$Before answering, check: the total is inside the range; loop and music_mood are filled; no line has more than [[LINE_WORDS]] words;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SCRIPT', 2, false, 'Step 10: as version 1, for the looping short - three movements, loop, music, few words.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- SHOT_PACKAGE 2 -----------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$- story: want, obstacle, escalation, a real turn, a payoff that lands?$a$,
        $a$- story: one idea, one build-up, a payoff that answers the hook and surprises - and does the last image lead back to the first?$a$);
    v := m417_internal.swap_text(v,
        $a$- dialogue: short, natural, back and forth, each line worth its seconds?$a$,
        $a$- dialogue: a few words per line, the kind of thing a child shouts - is every line needed?$a$);
    v := m417_internal.swap_text(v,
        $a$How the film is made: every shot is generated separately by an AI video model as a clip of [[GEN_SECONDS]] seconds, and the edit uses the first edit_seconds of it. The model sees one shot at a time and remembers nothing.$a$,
        $a$How the film is made: every shot is produced in two steps. First one still picture of its first instant is drawn and the owner approves it. Then an AI video model animates that exact picture into a clip of [[GEN_SECONDS]] seconds, and the edit uses the first edit_seconds of it. The model sees one shot at a time and remembers nothing.$a$);
    v := m417_internal.swap_text(v,
        $a$DIALOGUE
- At most one spoken line per shot.$a$,
        $a$CAMERA
- camera_angle is one of EYE_LEVEL, LOW_ANGLE, HIGH_ANGLE, TOP_DOWN, PROFILE, THREE_QUARTER, DRONE. EYE_LEVEL (the children's eye level) is the default. LOW_ANGLE for a daring or heroic moment. HIGH_ANGLE for a small "uh-oh". TOP_DOWN for something on a table or on the ground. PROFILE (seen exactly from the side) for running, jumping and walking. THREE_QUARTER gives depth to two children side by side. DRONE (high above the place) only in the first or the last shot, with shot_size WIDE or EXTREME_WIDE.
- camera_move is exactly one of STATIC, PUSH_IN, PULL_BACK, TRACK, PAN, RISE, DRONE_DESCEND, HANDHELD. STATIC is the safe choice and the right one for dancing and for a surprise. PUSH_IN builds tension. PULL_BACK reveals the surprise. TRACK follows a run or a jump. PAN travels across faces. RISE opens up the place at the end. DRONE_DESCEND only with camera_angle DRONE. A shot in which a line is spoken ON_CAMERA is STATIC or PUSH_IN.
- A short of three shots: the hook MEDIUM or MEDIUM_CLOSE at EYE_LEVEL, face and problem in one picture; the build-up WIDE or PROFILE with one move; the payoff a CLOSE_UP reaction or a PULL_BACK that reveals the surprise.

FIRST FRAME
- first_frame describes the still picture of the first instant of the shot in 80 to 500 characters: who is where in the frame (left, right, foreground, background), each pose, each expression, where each prop is. A frozen moment: no movement, nothing that happens later. This picture is drawn first and shown to the owner, so it must be exact.
- The last shot ends close to the first_frame of shot 1, as the script's loop says, so the short loops.

DIALOGUE
- At most one spoken line per shot.$a$);
    v := m417_internal.swap_text(v,
        $a$- camera: angle and movement (static, slow push-in, pan, low angle ...).$a$,
        $a$- camera: the angle and the move once more in a few plain words.$a$);
    v := m417_internal.swap_text(v,
        $a$"purpose": "", "shot_size": "", "camera": "",$a$,
        $a$"purpose": "", "shot_size": "", "camera_angle": "", "camera_move": "", "camera": "", "first_frame": "",$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has beats starting at 0;$a$,
        $a$every shot has beats starting at 0; every shot has camera_angle, camera_move and a first_frame that is a frozen picture;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 2, false, 'Step 11: as version 1, plus the camera vocabulary and the first frame of every shot.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- DIRECTOR 2 and 3 ---------------------------------------------------
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'DIRECTOR' and version = 1;
    if v is null then
        raise exception 'M417_012_PROMPT_V1_MISSING: DIRECTOR';
    end if;
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('DIRECTOR', 2, false, 'Step 14: as v1, plus a rule to converge instead of polishing without end.',
            m417_internal.swap_text(v, $a$APPROVE requires a pre-QC verdict of PASS$a$,
                                    v_converge || $a$APPROVE requires a pre-QC verdict of PASS$a$))
    on conflict (prompt_code, version) do nothing;
    v := m417_internal.swap_text(v,
        $a$APPROVE requires a pre-QC verdict of PASS$a$,
        v_converge || $a$This is a looping short of a few shots. What decides it: the first picture raises a question, the payoff answers it with a surprise, the last image leads back to the first, and every first_frame can be drawn exactly as written. The owner sees and approves the first frame of every shot before any video is paid for, so do not hold the package back over details a picture will settle.

APPROVE requires a pre-QC verdict of PASS$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('DIRECTOR', 3, false, 'Step 14: as v2, for the looping short with approved first frames.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;

    -- The short-format versions are the ones in force.
    update public.step_prompts set is_active = false
    where prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE', 'DIRECTOR') and is_active
      and not ((prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE') and version = 2)
               or (prompt_code = 'DIRECTOR' and version = 3));
    update public.step_prompts set is_active = true
    where (prompt_code in ('TOPIC', 'SCRIPT', 'SHOT_PACKAGE') and version = 2)
       or (prompt_code = 'DIRECTOR' and version = 3);
end $$;
