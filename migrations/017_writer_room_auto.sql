-- =====================================================================
-- M417 / WIZZLEBURY  -  017 the writers' room runs by itself
--
-- 016 gave one question to one model. This is the chain around it, so that
-- nobody has to push the steps by hand:
--
--   IDEA -> RESEARCH (grok) -> DRAFT (claude) -> EDIT (openai)
--        -> FINAL (claude, two halves at once) -> SPEC (claude, two halves)
--        -> DONE
--
-- public.writer_episodes holds one row per episode (one place, one small
-- problem, twelve one-take scenes). m417_internal.writer_tick() runs every
-- two minutes, looks at the one episode that is on its way, and when the
-- answers of its step are in, checks them and starts the next step. SPEC
-- turns the final script into twelve "onetake" specs; each one is checked
-- with as_prompts before the episode counts as DONE, so a DONE episode can
-- be planned as shorts without anybody touching it.
--
-- Why two halves: the Make module that calls Claude gives up after 300
-- seconds; a whole rewrite of twelve scenes did not fit, two halves of six
-- take about 150 seconds each.
--
-- The room only starts a new episode while fewer than writer_buffer
-- finished episodes are waiting to be planned (planned_at is null), so it
-- cannot spend money on a pile of scripts nobody films.
-- Safe to run more than once.
-- =====================================================================
begin;

alter table public.writer_runs add column if not exists part text not null default '';
-- a new kind of step: SPEC
alter table public.writer_runs drop constraint if exists writer_runs_step_check;
alter table public.writer_runs add constraint writer_runs_step_check
    check (step in ('RESEARCH', 'DRAFT', 'EDIT', 'FINAL', 'SPEC', 'OTHER'));

create table if not exists public.writer_episodes (
    code text primary key,
    no integer not null unique,
    title text not null,
    place text not null,
    wardrobe text not null default 'school',
    premise text not null,
    state text not null default 'IDEA'
        check (state in ('IDEA', 'RESEARCH', 'DRAFT', 'EDIT', 'FINAL', 'SPEC', 'DONE', 'FAILED')),
    tries integer not null default 0,
    step_at timestamptz,
    research text,
    draft text,
    edit text,
    final_text text,
    specs jsonb,
    error text,
    planned_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
alter table public.writer_episodes enable row level security;

insert into public.auto_shorts_settings (key, value, description) values
    ('writer_auto', 'true', 'true = the writers'' room starts the next episode by itself.'),
    ('writer_buffer', '2', 'How many finished, not yet planned episodes may wait before the room stops writing.')
on conflict (key) do nothing;

-- ----- the texts of the room (code, so a new run of this file updates them) --
insert into public.auto_shorts_settings (key, value, description) values
('writer_s_research', $t$You are the researcher of the writers' room of the children's animated series WIZZLEBURY. You know what children of 4 to 9 and their parents watch on YouTube and YouTube Shorts right now. You are concrete and practical and never give general advice. The series bible is below.$t$, 'Writers'' room: system text of the researcher.'),

('writer_p_research', $t$Research task for episode {EP_NO}, "{EP_TITLE}".
PLACE: {EP_PLACE}
STORY IDEA: {EP_PREMISE}

Answer in plain English, no JSON, with these numbered parts:
1. WHAT WORKS NOW: the 8 most reliable things that make children of this age (and their parents) keep watching short everyday-life scenes on YouTube and Shorts right now. Be concrete: kinds of first-second hooks, kinds of gags children laugh at, kinds of moments that feel warm. Name well-known series only as a measure of tone, never to copy.
2. GOLD FOR THIS EPISODE: 15 specific, fresh, visual ideas for this place and this story: looks, reactions, tiny physical comedy, running gags, sweet friendship moments between Fatih and Mia (children, friendship only), grown-ups who are warm before they are funny. Each idea one or two sentences, playable in a ten-second single shot, no text on screen, no props that need reading.
3. FIRST SECOND: 12 different ways to open a ten-second scene in this place so that a child does not swipe away (a movement, a sound, a face).
4. LINES: 20 very short lines (at most six words) that these children or the grown-ups could say, funny or sweet, natural for native English-speaking children.
5. TRAPS: what makes such scenes feel flat, fake or boring, and what to avoid for a made-for-kids channel.
Be specific and practical; no general advice.$t$, 'Writers'' room: the research task.'),

('writer_s_draft', $t$You are the head writer of the children's animated series WIZZLEBURY. Follow the series bible exactly; its production limits are hard limits.$t$, 'Writers'' room: system text of the head writer.'),

('writer_p_draft', $t$Write episode {EP_NO}, "{EP_TITLE}", in full.

PLACE: {EP_PLACE}
STORY: {EP_PREMISE}

RESEARCH from our researcher (use what is strong, drop what is weak or cannot be produced):
{EP_RESEARCH}

WHAT TO DELIVER. First one short paragraph STANDING SET: the place, the light, and where everybody sits or stands for the whole episode. Then twelve scenes. Every scene is one continuous shot of about ten seconds and must also work alone as a Short for a child who has seen nothing else. Write each scene in exactly this layout, in plain English, no markdown, no bold, no tables:

SCENE n - short name
SHORT TITLE: a YouTube Shorts title of at most 45 characters, with one emoji
IN THE PICTURE: the children (at most three, named from left to right) and the grown-ups (at most two), and where each one is
FIRST PICTURE: what the very first frame shows (place, light, who sits or stands where, what each one holds, what lies where). Everything and everybody the scene needs is already here.
FIRST SECOND: the movement, sound or face that stops the thumb
ACTION: at most FOUR numbered acting moments in order, written as acting (who looks at whom, what the face does, where the pause is, one piece of small body comedy) with the turns of the camera. Put spoken lines inside the action in quotation marks with the speaker.
SOUNDS: what is heard besides the voices
LAST FACE: the reaction the shot ends on and the button
WHY IT WORKS: one sentence

Rules for the whole episode:
- Build one or two running gags that pay off in the last scene.
- Fatih and Mia are the leads: at least four scenes are carried by the looks between them. Every other child who is in the story gets one scene that is really his.
- The comedy grows from scene 4 to scene 8; scene 9 or 10 is the brave or true moment and it is quiet; the last scene is warm and ends on a small laugh.
- Vary who is in the picture, so that everybody of the story appears although only three children fit in one scene.
- Fewer, bigger, clearer moments. Simple does not mean flat: every moment is acting.
- The camera only turns gently from face to face or moves slowly closer. It never dips under a table and never follows a flying object. If a small signal with a foot or a hand matters, it is in the picture from the start and big enough to see.
- Whoever speaks is the one the camera is looking at, and is facing the camera.
- Somebody who arrives (a parent at a door) is already visible in the first picture, small and waiting.
- Nobody shoots up, drops, runs or falls. Objects move a hand's width, never across the room.
- Nothing that needs reading.

After scene 12 add three lines: RUNNING GAG, HEART OF THE EPISODE, RISKS FOR PRODUCTION (what the video model may get wrong).$t$, 'Writers'' room: the task of the first draft.'),

('writer_s_edit', $t$You are the toughest script editor of the children's animated series WIZZLEBURY. You protect the audience (children of 4 to 9 and their parents) and the owner, who has rejected simple, flat, cold scripts again and again. You never praise to be polite. You judge only against the series bible below; its production limits are hard limits.$t$, 'Writers'' room: system text of the editor.'),

('writer_p_edit', $t$Below is the head writer's draft of episode {EP_NO}, "{EP_TITLE}": twelve scenes, each one continuous ten-second shot that must also work alone as a Short.

YOUR JOB
A. For EACH of the twelve scenes give:
   SCENE n - scores from 1 to 5 for: HOOK (does the first second stop a swiping child), ACTING (looks, faces, pauses - is it a film moment or a list of events), COMEDY/WARMTH (does a child laugh or feel something), CLARITY (understood with the sound off, and alone as a Short), PRODUCIBLE (can a video model make it in one ten-second shot: count the acting moments, check the hard limits, small unreadable gestures, objects that must fly or be handled).
   Then at most three sentences: the weakest thing in the scene, and the exact fix (rewrite the beat or the line - give the new wording, not advice).
   Any scene with a score under 4 anywhere must get a concrete fix.
B. Check the DIALOGUE: mark every line that a native English-speaking nine-year-old would not say, is longer than six words, or explains the joke; give a better line.
C. Check the EPISODE: do the running gags build and pay off; is the brave or true moment earned and quiet; do the last two scenes land warm and funny; is any scene a repeat of another; which ONE scene is the weakest and should be replaced, and with what (write the replacement in four sentences; it must grow out of a character, never out of a random object).
D. Check the HARD LIMITS scene by scene: more than three children or two grown-ups in the picture, somebody entering from outside the frame, anything to read, complicated hand work, something thrown at a person, more than four acting moments. List every break.
E. THREE BEST moments that must not be touched in the rewrite.
Plain English, no markdown tables, no introduction, no closing compliments.

THE DRAFT
{EP_DRAFT}$t$, 'Writers'' room: the task of the editor.'),

('writer_p_final', $t$Rewrite episode {EP_NO}, "{EP_TITLE}", into its final shooting version. Below are (1) your draft, (2) the notes of the script editor, (3) the standing notes of the producer. Where editor and producer disagree, the producer wins.

{PART}

HOW TO REWRITE
- Keep what is alive: the editor's three best moments, the looks between Fatih and Mia, the running gags.
- Cut every scene down to FOUR numbered acting moments at most. Fewer, bigger, clearer moments - but each moment still written as acting (who looks at whom, what the face does, where the pause is). Do not make the scenes poorer; make them sharper. Simple does not mean flat.
- Every scene must still open with something that stops the thumb in the first second and end on a face.
- Keep the layout of the draft for every scene (SCENE, SHORT TITLE, IN THE PICTURE, FIRST PICTURE, FIRST SECOND, ACTION with moments numbered 1 to 4, SOUNDS, LAST FACE, WHY IT WORKS). Plain text, no markdown, no bold.

(3) STANDING NOTES OF THE PRODUCER
a. The camera never dips under a table and never follows a flying object. It only turns gently from face to face or moves slowly closer. If a signal with a foot or a hand matters, the picture is framed from the start so that it is visible, and the movement is big: the whole foot swings and bumps the other shoe twice; one slow full nod.
b. If the editor replaces a character's own gag by a random object, do not follow him: keep the gag of the character and make its movement tiny instead (an object goes a hand's width, lands on the owner himself, and stays there for the rest of the episode without anybody mentioning it).
c. Grown-ups never carry a child's toy or invention. Blurred background children never hand over anything and never react.
d. Somebody who arrives is in the picture from the very first frame, small and waiting (behind the glass of a door, in a doorway); those in front have their backs to him and do not know.
e. A running sound gag is used in at most three scenes, so that it stays strong.
f. In scenes with two grown-ups keep the children to two if you can; five people in one picture is the absolute limit and happens at most once, in the last scene.
g. No mouth is ever described as moving for a line unless that person is clearly in the picture and facing the camera at that moment: after a camera turn, the speaker is the one the camera is looking at.
h. Nobody shoots up, drops, runs or falls: a child half-rises and sinks back.

(2) NOTES OF THE SCRIPT EDITOR
{EP_EDIT}

(1) YOUR DRAFT
{EP_DRAFT}$t$, 'Writers'' room: the task of the final rewrite ({PART} says which half).'),

('writer_s_spec', $t$You are the production engineer of the children's animated series WIZZLEBURY. You turn a finished script into exact data for the image model (which draws the first picture) and the video model (which films ten seconds from that picture). You change nothing in the story. You make every moment concrete and visible, because these models see only what is said in plain words. The series bible is below.$t$, 'Writers'' room: system text of the production engineer.'),

('writer_p_spec', $t$Turn {PART} of the final script of episode {EP_NO}, "{EP_TITLE}", into production data. Answer with ONE JSON array and nothing else: no markdown, no code fence, no comment before or after. One object per scene, in the order of the script.
{EP_ERROR}
Every object has exactly these keys:
- "n": the number of the scene.
- "title": the YouTube Shorts title: natural English, at most 45 characters, one emoji at the end.
- "l1": first line of the description: one sentence that says what happens, with the names of the children of the scene in it, ending like "in this funny kids cartoon!".
- "l2": second line: one or two short sentences that make a child curious, then "Watch to the end!".
- "hashtags": exactly three hashtags in lower case, separated by spaces, fitting the scene (for example "#school #classroom #funnykids").
- "tags": six to eight search tags in lower case, separated by commas, the first names of the children of the scene among them.
- "spec": an object with these keys:
  - "kind": always "onetake".
  - "wardrobe": always "{EP_WARDROBE}".
  - "seconds": always 10.
  - "cast": two or three of "FATIH", "MIA", "OMER", "TOMBIK", "BRUCE" - exactly the children of the scene, in the order in which their heads are seen in the picture from left to right (a child in a back row is listed where his head is seen). Never one child alone: if the script has only one, add the friend who sits next to him.
  - "adults": a list with none, one or two of "TEACHER", "COOK", "COACH", "DRIVER", "MOM", "DAD", "MIAMOM", "MIADAD" - exactly the grown-ups of the scene.
  - "crowd": leave this key out, or, only if the script wants classmates or other people far behind: "and a few softly blurred children far in the background who sit still and do nothing".
  - "place": two or three sentences that describe the whole place of the episode for a painter: walls, furniture, windows, the light and where it comes from, colours, and every fixed thing that any scene of the episode needs (for example a door with a glass panel in the back wall). It says that boards and walls are plain, with nothing written on them. Use the same text in every scene.
  - "scene": the FIRST PICTURE of this scene for the painter, three to five sentences: how close and how high the camera is, where every child and grown-up is (left, middle, right; front or back; sitting, standing, kneeling), what each one holds, what lies where, and the pose and the face each one has in the first frame. Name nobody here: write "the boy on the left", "the girl in the middle", "the boy in the back on the right", "the teacher", "the father". Blank things stay blank: "a plain blue folder with nothing on it".
  - "action": what happens in the ten seconds, as ONE paragraph of at most 120 words, in the present tense and in order. The first sentence is the FIRST SECOND of the script; the last sentence is the LAST FACE. Keep every acting moment of the script (the looks, the pauses, what each face does), but in plain visible words: no comparisons ("like grass in the wind"), no thoughts ("as if it might bite"), no "silently saying". Write the children as {1}, {2}, {3} (their number in "cast") and the grown-ups as {TEACHER}, {COOK}, {COACH}, {DRIVER}, {MOM}, {DAD}, {MIAMOM}, {MIADAD}; never write their names. Say when "the camera turns to" somebody or "moves slowly closer". Every spoken line is written like this: who, how, the line - for example: {2} leans to {1} and whispers in a happy, cheeky cartoon boy voice: "Leave it to me!" Voices: Fatih "a warm, bright cartoon boy voice"; Mia "a clear, cheerful cartoon child voice"; Tombik "a happy, cheeky cartoon boy voice"; Ömer "a quick, eager cartoon boy voice"; Bruce "a dreamy, excited cartoon boy voice"; the teacher and mothers "a warm, friendly woman's voice"; fathers and other men "a warm, friendly man's voice". A line is said only while the camera is on the speaker.
  - "sounds": the sounds of the script besides the voices, in lower case, separated by commas.
  - "expect": two to four short sentences that a checker can verify by watching the finished video: who does what, with every spoken line in quotation marks, using the real names here (for example: Tombik raises his hand and calls: "Miss Lily! Question!").

Inside JSON strings every quotation mark is written as \" and there are no line breaks.

THE FINAL SCRIPT
{EP_FINAL}$t$, 'Writers'' room: the task that turns the final script into one-take specs ({PART} says which scenes).')
on conflict (key) do update set value = excluded.value, description = excluded.description;

-- ----- one question to one model: now also tells Make how hard to think -----
create or replace function m417_internal.writer_ask(
    p_episode text, p_step text, p_model text, p_system text, p_prompt text, p_max_tokens integer default 8000)
 returns bigint language plpgsql security definer set search_path to ''
as $function$
declare
    v_id bigint;
begin
    insert into public.writer_runs (episode, step, model, system_text, prompt)
    values (p_episode, p_step, p_model, p_system, p_prompt)
    returning id into v_id;
    update public.writer_runs
    set req = net.http_post(
        url := m417_internal.as_set('webhook_writer'),
        body := jsonb_build_object('id', v_id, 'model', p_model, 'system', coalesce(p_system, ''),
                                   'prompt', p_prompt, 'max_tokens', p_max_tokens,
                                   'effort', coalesce(nullif(current_setting('m417.writer_effort', true), ''), 'medium')),
        timeout_milliseconds := 300000)
    where id = v_id;
    return v_id;
end;
$function$;

-- ----- fill a text of the room with the data of an episode ------------------
create or replace function m417_internal.writer_fill(p_tpl text, p_code text, p_part text)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
    ep public.writer_episodes;
    v text := p_tpl;
begin
    select * into ep from public.writer_episodes e where e.code = p_code;
    v := replace(v, '{PART}', coalesce(p_part, ''));
    v := replace(v, '{EP_NO}', ep.no::text);
    v := replace(v, '{EP_TITLE}', ep.title);
    v := replace(v, '{EP_PLACE}', ep.place);
    v := replace(v, '{EP_WARDROBE}', ep.wardrobe);
    v := replace(v, '{EP_PREMISE}', ep.premise);
    v := replace(v, '{EP_ERROR}', case when coalesce(ep.error, '') = '' then ''
        else E'\nNOTE: your previous answer was rejected by the checker with this message: ' || ep.error || E'\nFix exactly that.\n' end);
    v := replace(v, '{EP_RESEARCH}', coalesce(ep.research, ''));
    v := replace(v, '{EP_EDIT}', coalesce(ep.edit, ''));
    v := replace(v, '{EP_DRAFT}', coalesce(ep.draft, ''));
    v := replace(v, '{EP_FINAL}', coalesce(ep.final_text, ''));
    return v;
end;
$function$;

-- ----- start one step of an episode ------------------------------------------
create or replace function m417_internal.writer_start(p_code text, p_step text)
 returns void language plpgsql security definer set search_path to ''
as $function$
declare
    ep public.writer_episodes;
    v_model text := case p_step when 'RESEARCH' then 'grok' when 'EDIT' then 'openai' else 'claude' end;
    v_max integer := case p_step when 'RESEARCH' then 6000 when 'DRAFT' then 32000 when 'EDIT' then 12000 else 20000 end;
    v_parts text[] := case when p_step in ('FINAL', 'SPEC') then array['A', 'B'] else array[''] end;
    v_part text;
    v_rule text;
    v_id bigint;
begin
    select * into ep from public.writer_episodes e where e.code = p_code;
    if not found then
        raise exception 'WRITER: unknown episode %', p_code;
    end if;
    -- a draft that ran into the 300 seconds of Make is tried again with less thinking
    perform set_config('m417.writer_effort', case when p_step = 'DRAFT' and ep.tries >= 1 then 'low' else 'medium' end, true);
    foreach v_part in array v_parts loop
        v_rule := case p_step || v_part
            when 'FINALA' then 'IN THIS ANSWER WRITE ONLY SCENES 1 TO 6 (another writer does 7 to 12 from the same notes at the same time; do not write the closing lines). Start directly with "SCENE 1".'
            when 'FINALB' then 'IN THIS ANSWER WRITE ONLY SCENES 7 TO 12 and then the three closing lines RUNNING GAG, HEART OF THE EPISODE, RISKS FOR PRODUCTION (another writer does 1 to 6 from the same notes at the same time, with the same fixes). Start directly with "SCENE 7".'
            when 'SPECA' then 'scenes 1 to 6'
            when 'SPECB' then 'scenes 7 to 12'
            else '' end;
        v_id := m417_internal.writer_ask(p_code, p_step, v_model,
            m417_internal.as_set('writer_s_' || case p_step when 'FINAL' then 'draft' else lower(p_step) end)
                || E'\n\n' || m417_internal.as_set('writer_bible'),
            m417_internal.writer_fill(m417_internal.as_set('writer_p_' || lower(p_step)), p_code, v_rule),
            v_max);
        update public.writer_runs set part = v_part where id = v_id;
    end loop;
    update public.writer_episodes set state = p_step, step_at = now(), updated_at = now() where code = p_code;
end;
$function$;

-- ----- read one half of the SPEC answer and check every scene ----------------
create or replace function m417_internal.writer_parse_specs(p_code text, p_text text)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare
    v_txt text := coalesce(p_text, '');
    v_from integer := position('[' in v_txt);
    v_to integer := length(v_txt) - position(']' in reverse(v_txt)) + 1;
    v_arr jsonb;
    v_one jsonb;
    v_n integer;
begin
    if v_from = 0 or v_to <= v_from then
        raise exception 'the answer is not a JSON array';
    end if;
    begin
        v_arr := substring(v_txt from v_from for v_to - v_from + 1)::jsonb;
    exception when others then
        raise exception 'the answer is not valid JSON (%)', left(sqlerrm, 200);
    end;
    if jsonb_typeof(v_arr) <> 'array' then
        raise exception 'the answer is not a JSON array';
    end if;
    for v_one in select x from jsonb_array_elements(v_arr) x loop
        v_n := (v_one ->> 'n')::integer;
        if coalesce(btrim(v_one ->> 'title'), '') = '' or length(v_one ->> 'title') > 60 then
            raise exception 'scene %: title is missing or longer than 60 characters', v_n;
        end if;
        if coalesce(btrim(v_one ->> 'l1'), '') = '' or coalesce(btrim(v_one ->> 'l2'), '') = ''
           or coalesce(btrim(v_one ->> 'hashtags'), '') = '' or coalesce(btrim(v_one ->> 'tags'), '') = '' then
            raise exception 'scene %: l1, l2, hashtags or tags is missing', v_n;
        end if;
        if v_one -> 'spec' ->> 'kind' is distinct from 'onetake' then
            raise exception 'scene %: spec.kind must be "onetake"', v_n;
        end if;
        if array_length(regexp_split_to_array(btrim(v_one -> 'spec' ->> 'action'), '\s+'), 1) > 150 then
            raise exception 'scene %: action is longer than 150 words', v_n;
        end if;
        begin
            perform m417_internal.as_prompts(p_code || '-S' || lpad(v_n::text, 2, '0'), v_one -> 'spec');
        exception when others then
            raise exception 'scene %: %', v_n, left(sqlerrm, 300);
        end;
    end loop;
    return v_arr;
end;
$function$;

-- ----- the clock of the room ---------------------------------------------------
create or replace function m417_internal.writer_tick()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    ep public.writer_episodes;
    v_open integer;
    v_runs integer;
    v_a text;
    v_b text;
    v_err text;
    v_specs jsonb;
    v_place text;
    v_waiting integer;
begin
    if not pg_try_advisory_xact_lock(417017) then
        return jsonb_build_object('writer', 'busy');
    end if;

    select * into ep from public.writer_episodes e
    where e.state in ('RESEARCH', 'DRAFT', 'EDIT', 'FINAL', 'SPEC') order by e.no limit 1;

    if not found then
        if coalesce(m417_internal.as_set('writer_auto'), 'false') <> 'true' then
            return jsonb_build_object('writer', 'off');
        end if;
        -- a failed episode stops the room until somebody has looked: the cause is
        -- usually outside (no credit at a model, Make scenario switched off) and
        -- the next episode would only fail the same way and cost money
        if exists (select 1 from public.writer_episodes e where e.state = 'FAILED') then
            return jsonb_build_object('writer', 'stopped: a failed episode needs a look');
        end if;
        select count(*) into v_waiting from public.writer_episodes e where e.state = 'DONE' and e.planned_at is null;
        if v_waiting >= coalesce(m417_internal.as_set('writer_buffer')::integer, 1) then
            return jsonb_build_object('writer', 'enough scripts waiting', 'waiting', v_waiting);
        end if;
        select * into ep from public.writer_episodes e where e.state = 'IDEA' order by e.no limit 1;
        if not found then
            return jsonb_build_object('writer', 'no ideas left');
        end if;
        update public.writer_episodes set tries = 0, error = null where code = ep.code;
        perform m417_internal.writer_start(ep.code, 'RESEARCH');
        return jsonb_build_object('writer', 'started', 'episode', ep.code, 'step', 'RESEARCH');
    end if;

    select count(*), count(*) filter (where r.done_at is null),
           max(r.output) filter (where r.part in ('', 'A')), max(r.output) filter (where r.part = 'B')
    into v_runs, v_open, v_a, v_b
    from public.writer_runs r
    where r.episode = ep.code and r.step = ep.state and r.created_at >= ep.step_at;

    v_a := regexp_replace(coalesce(v_a, ''), '\*\*', '', 'g');
    v_b := regexp_replace(coalesce(v_b, ''), '\*\*', '', 'g');

    if v_runs = 0 then
        v_err := 'the step was never sent';
    elsif v_open > 0 then
        if now() - ep.step_at < interval '8 minutes' then
            return jsonb_build_object('writer', 'waiting', 'episode', ep.code, 'step', ep.state);
        end if;
        v_err := 'no answer from the model within 8 minutes';
    else
        v_err := case ep.state
            when 'RESEARCH' then case when length(v_a) < 1500 then 'the research is too short' end
            when 'DRAFT' then case when length(v_a) < 8000 or position('SCENE 12' in v_a) = 0 then 'the draft is not complete' end
            when 'EDIT' then case when length(v_a) < 3000 then 'the notes of the editor are too short' end
            when 'FINAL' then case when length(v_a) < 4000 or length(v_b) < 4000
                                     or position('SCENE 6' in v_a) = 0 or position('SCENE 12' in v_b) = 0
                                   then 'the final script is not complete' end
            else null end;
        if ep.state = 'SPEC' then
            begin
                v_specs := m417_internal.writer_parse_specs(ep.code, v_a) || m417_internal.writer_parse_specs(ep.code, v_b);
                if jsonb_array_length(v_specs) <> 12 then
                    v_err := 'expected 12 scenes, got ' || jsonb_array_length(v_specs);
                end if;
            exception when others then
                v_err := left(sqlerrm, 500);
            end;
        end if;
    end if;

    if v_err is not null then
        if ep.tries >= 2 then
            update public.writer_episodes set state = 'FAILED', error = ep.state || ': ' || v_err, updated_at = now() where code = ep.code;
            return jsonb_build_object('writer', 'failed', 'episode', ep.code, 'step', ep.state, 'error', v_err);
        end if;
        update public.writer_episodes set tries = tries + 1, error = v_err where code = ep.code;
        perform m417_internal.writer_start(ep.code, ep.state);
        return jsonb_build_object('writer', 'retry', 'episode', ep.code, 'step', ep.state, 'error', v_err);
    end if;

    if ep.state = 'RESEARCH' then
        update public.writer_episodes set research = v_a, tries = 0, error = null where code = ep.code;
        perform m417_internal.writer_start(ep.code, 'DRAFT');
    elsif ep.state = 'DRAFT' then
        update public.writer_episodes set draft = v_a, tries = 0, error = null where code = ep.code;
        perform m417_internal.writer_start(ep.code, 'EDIT');
    elsif ep.state = 'EDIT' then
        update public.writer_episodes set edit = v_a, tries = 0, error = null where code = ep.code;
        perform m417_internal.writer_start(ep.code, 'FINAL');
    elsif ep.state = 'FINAL' then
        update public.writer_episodes set final_text = btrim(v_a) || E'\n\n' || btrim(v_b), tries = 0, error = null where code = ep.code;
        perform m417_internal.writer_start(ep.code, 'SPEC');
    else
        -- one place and one wardrobe for the whole episode: the two halves were
        -- written apart, so the text of the first scene is used for all twelve
        v_place := v_specs -> 0 -> 'spec' ->> 'place';
        select jsonb_agg(jsonb_set(jsonb_set(x, '{spec,place}', to_jsonb(v_place)), '{spec,wardrobe}', to_jsonb(ep.wardrobe))
                         order by (x ->> 'n')::integer)
        into v_specs from jsonb_array_elements(v_specs) x;
        update public.writer_episodes set specs = v_specs, state = 'DONE', tries = 0, error = null, updated_at = now() where code = ep.code;
        return jsonb_build_object('writer', 'done', 'episode', ep.code);
    end if;
    return jsonb_build_object('writer', 'next step', 'episode', ep.code, 'after', ep.state);
end;
$function$;

do $do$
begin
    revoke all on function m417_internal.writer_tick() from public;
    revoke all on function m417_internal.writer_start(text, text) from public;
    revoke all on function m417_internal.writer_fill(text, text, text) from public;
    revoke all on function m417_internal.writer_parse_specs(text, text) from public;
    if exists (select 1 from pg_roles where rolname = 'anon') then
        revoke all on public.writer_episodes from anon, authenticated;
    end if;
    if exists (select 1 from pg_extension where extname = 'pg_cron') then
        perform cron.schedule('m417-writer-room', '*/2 * * * *', 'select m417_internal.writer_tick()');
    end if;
end $do$;

commit;
