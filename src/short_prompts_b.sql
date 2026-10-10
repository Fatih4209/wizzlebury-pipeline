
-- ----- SHOT_PACKAGE 3: one event per shot ---------------------------------
-- Version 2 with one rule added. Built from version 2 as it stands in
-- the table, so the two cannot drift apart unnoticed.
do $$
declare
    v text;
begin
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 2;
    if v is null then
        raise exception 'M417_013_PROMPT_V2_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$Each beat is one visible action or change of expression. The action must start at once: the cut is short.$a$,
        $a$Each beat is one visible action or change of expression. The action must start at once: the cut is short. At most [[BEATS_MAX]] beats: one event and the reaction to it. The video model performs one event per shot and drops a second one, so what does not fit is left out, never squeezed in.$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has beats starting at 0;$a$,
        $a$every shot has at most [[BEATS_MAX]] beats, the first at 0;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 3, false, 'Step 11: as version 2, plus one event per shot (at most max_beats_per_shot beats).', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;
    update public.step_prompts set is_active = false where prompt_code = 'SHOT_PACKAGE' and version <> 3 and is_active;
    update public.step_prompts set is_active = true where prompt_code = 'SHOT_PACKAGE' and version = 3 and not is_active;
end $$;

-- ----- SHOT_PACKAGE 4: everybody is there from the first shot --------------
-- Version 3 with two rules added: nobody pops into a scene, and a first
-- frame shows props in the state the shot before left them.
do $$
declare
    v text;
begin
    select replace(body, chr(13), '') into v from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 3;
    if v is null then
        raise exception 'M417_014_PROMPT_V3_MISSING: SHOT_PACKAGE';
    end if;
    v := m417_internal.swap_text(v,
        $a$- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.$a$,
        $a$- Keep screen geography: a character who is on the left stays on the left in every shot of the scene. Write it into every video_prompt.
- Nobody pops into the scene. Shot 1 shows every character who takes part in the scene, all in one picture, so the viewer knows who is there before anything happens; a line in shot 1 is spoken by a character who is seen in it, never from off-screen. Only a character whose arrival is the surprise of the payoff may be missing from shot 1.
- The story runs on from picture to picture. The first_frame of a shot shows the place, the characters, their positions and every prop exactly in the state in which the shot before ended: what is closed stays closed until a shot shows it being opened, and what is inside something is not visible before it comes out.$a$);
    v := m417_internal.swap_text(v,
        $a$every shot has camera_angle, camera_move and a first_frame that is a frozen picture;$a$,
        $a$every shot has camera_angle, camera_move and a first_frame that is a frozen picture; shot 1 shows everyone in the scene; every first_frame continues from the end of the shot before it;$a$);
    insert into public.step_prompts (prompt_code, version, is_active, note, body)
    values ('SHOT_PACKAGE', 4, false, 'Step 11: as version 3, plus: everybody is in shot 1, and first frames continue from the shot before.', v)
    on conflict (prompt_code, version) do update set body = excluded.body, note = excluded.note;
    update public.step_prompts set is_active = false where prompt_code = 'SHOT_PACKAGE' and version <> 4 and is_active;
    update public.step_prompts set is_active = true where prompt_code = 'SHOT_PACKAGE' and version = 4 and not is_active;
end $$;
