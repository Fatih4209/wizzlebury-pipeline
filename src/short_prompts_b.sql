
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
    update public.step_prompts set is_active = (version = 3) where prompt_code = 'SHOT_PACKAGE';
end $$;
