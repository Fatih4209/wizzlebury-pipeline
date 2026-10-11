-- =====================================================================
-- M417 / WIZZLEBURY  -  016 writers' room
--
-- The owner, 11 October: "the ones who write must be you: Grok researches,
-- you look, OpenAI looks, and you work for the strongest script" - he does
-- not want to sit in a chat and direct. Since the move to the Google path
-- the scripts were written by hand in the chat; this brings the three
-- models back in front of production.
--
-- One Make scenario (M417-Yazar Odası) takes {id, model, system, prompt,
-- max_tokens}, asks grok / claude / openai and hands the answer back with
-- public.writer_save(id, base64 text). Base64 because the answers are free
-- text with quotes and line breaks. The chain of an episode is
--   RESEARCH (grok) -> DRAFT (claude) -> EDIT (openai) -> FINAL (claude)
-- Lessons of the first evening:
--   * claude-opus-5-5 always thinks; at the default effort the thinking ate
--     the whole answer (12 000 tokens: empty text; 28 000: two scenes). The
--     Make module now runs with effort = medium and the room asks for 32 000.
--   * The Claude answer can come in several text blocks: the scenario joins
--     all of them, and saves the stop reason when there is no text at all.
-- Safe to run more than once.
-- =====================================================================
begin;

create table if not exists public.writer_runs (
    id bigint generated always as identity primary key,
    episode text not null,
    step text not null check (step in ('RESEARCH', 'DRAFT', 'EDIT', 'FINAL', 'OTHER')),
    model text not null check (model in ('grok', 'claude', 'openai')),
    system_text text,
    prompt text not null,
    output text,
    req bigint,
    created_at timestamptz not null default now(),
    done_at timestamptz
);
alter table public.writer_runs enable row level security;

insert into public.auto_shorts_settings (key, value, description) values
    ('webhook_writer', 'https://hook.eu1.make.com/m6fuh5p7virkd15fq1mrupim1x4ojc9c', 'Make: one question to grok, claude or openai for the writers'' room.')
on conflict (key) do nothing;

-- The series bible every model of the room gets as its system text. The
-- project doc claude/dizi-kitabi-ve-senaryo-kurallari.md is the Turkish twin.
insert into public.auto_shorts_settings (key, value, description) values
    ('writer_bible', $bible$WIZZLEBURY - series bible for the writers' room

WHAT IT IS. An original 3D animated series for children of about 4 to 9 and their families, in English, made for kids. It shows the everyday life of five friends: school, classroom, school bus, canteen, sports lesson, park, dance class, coming home to mum and dad. It must feel like a moment from a real film about real children: warm, sincere, alive. Sweet smiles, glances, small true feelings - and real comedy with energy.

THE OWNER'S WORDS (he is the only judge): "The videos do not give the warmth I want." "You write far too simply - add looks, facial expressions, winks; a strong script makes a strong video." "It must be like a real film and for children." "There must be energy and dialogue; then it gets to the point and it is funny." "On YouTube the first second matters." He does not want gag machines (a surprise popping out of a box), children lined up doing a dance, or a flat list of events.

THE CHILDREN (all about nine; faces and hair never change)
- FATIH, the lead. Curious, fair, a natural leader, honest. Weakness: dreamy and forgetful; blushes when embarrassed. Typical moment: takes a breath and says the true thing.
- MIA, as strong a lead as Fatih. Clever, tidy, the one who warns; secretly mischievous. Typical moment: rolls her eyes, then cannot hide her smile. Fatih and Mia are close friends who understand each other with one look. Friendship only: they are children.
- TOMBIK, the heart of the comedy. Loves food, cheeky, loyal, impatient, cannot keep quiet. Typical moment: "Leave it to me!" - and makes it bigger.
- OMER (Ömer). Brave, sporty, helpful, too quick. First to run, first to fall, first to laugh.
- BRUCE, the little inventor. Dreamy; his inventions backfire. Wiggles his eyebrows: "Watch this!"

THE GROWN-UPS (warm before they are funny; never mock a child)
TEACHER Miss Lily (patient; bites her lip not to laugh). COOK of the canteen (gives everybody a little extra). COACH (sports teacher; too enthusiastic). DRIVER of the school bus (hums songs). MOM and DAD = Fatih's parents (Dad is always just in time). MIAMOM and MIADAD = Mia's parents.

FORM
- A SCENE is ONE continuous shot of about ten seconds, one camera, no cut; the camera turns smoothly from one person to the next. Every scene is also published alone as a Short.
- An EPISODE is twelve scenes = two minutes, in ONE place, about ONE small problem with something real at stake (embarrassment, letting a friend down). Shape: set-up (1-3), attempts that go wrong (4-8), the turn (9-10), warm landing (11-12).

HOW A SCENE IS WRITTEN
1. FIRST SECOND: a movement, a sound or a face already in trouble. Never a quiet wide shot of a normal room.
2. Acting, not a list of lines: who looks at whom (sideways, stolen, held), what happens in the face (a smile freezes, an eyebrow goes up, a lip is bitten, eyes light up, an eye-roll, a wink), where there is a pause (a swallow, a held breath).
3. At most three or four acting moments in ten seconds, in a clear order; the video model drops the rest.
4. Dialogue is short and natural for native English-speaking children: at most six words a line, at most three lines a scene. A scene must be understood with the sound off.
5. Comedy comes from character (Tombik's appetite, Bruce's invention, Ömer's haste), from a body doing one honest wrong thing, from a running gag - never from a random object.
6. Feeling between Fatih and Mia is carried by looks.
7. The scene ends on a face (a reaction), with a small "button" that makes a replay likely.
8. No lesson speeches; nobody is humiliated; no cheating shown as friendship; the child is safe when he tells the truth.

HARD LIMITS OF PRODUCTION (a scene that breaks one cannot be made)
- In one scene at most THREE of the children and at most TWO grown-ups are in the picture, and EVERYBODY who appears must already be visible in the first picture (nobody walks in from outside the frame; a face may appear behind the glass of a door that is in the picture from the start).
- The children keep their places from left to right for the whole scene.
- Nothing to read anywhere: no writing on the board, on paper, on clothes, no name tags.
- No complicated hand work (folding, writing, tying), no big jumps, no fast running, nothing thrown at a person.
- Other children of the class may exist only as soft blurred figures in the background who do nothing.$bible$, 'The series bible given to every model of the writers'' room.')
on conflict (key) do nothing;

-- Called by Make with the service key.
create or replace function public.writer_save(p_id bigint, p_b64 text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_n integer;
begin
    update public.writer_runs
    set output = convert_from(decode(regexp_replace(p_b64, '\s', '', 'g'), 'base64'), 'UTF8'), done_at = now()
    where id = p_id and output is null;
    get diagnostics v_n = row_count;
    return jsonb_build_object('saved', v_n);
end;
$function$;

do $do$
begin
    revoke all on function public.writer_save(bigint, text) from public;
    if exists (select 1 from pg_roles where rolname = 'anon') then
        revoke all on function public.writer_save(bigint, text) from anon, authenticated;
        grant execute on function public.writer_save(bigint, text) to service_role;
    end if;
end $do$;

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
                                   'prompt', p_prompt, 'max_tokens', p_max_tokens),
        timeout_milliseconds := 300000)
    where id = v_id;
    return v_id;
end;
$function$;

commit;
