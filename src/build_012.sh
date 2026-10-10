#!/bin/bash
# Builds 012_short_format.sql from the same parts the full schema uses.
set -e
cd "$(dirname "$0")"
OUT=012_short_format.sql
cat > $OUT <<'HEAD'
-- =====================================================================
-- M417 / WIZZLEBURY  -  012 short format: keyframe first, camera plan
--
-- Run after 011. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- 1. Keyframe first. A still picture of the first instant of every shot
--    is drawn, checked and shown to the owner. Only an approved picture
--    becomes the start frame of a paid video generation; without one no
--    attempt row can be created while keyframe_required is on.
-- 2. With a start frame the video request no longer describes what
--    everything looks like; it says what moves and what the camera does.
-- 3. Camera plan. Every shot names an angle and a move from a fixed
--    vocabulary and describes its first frame.
-- 4. Looping short. A script states how it loops and its music mood and
--    keeps every line to a few words. New instructions for topic,
--    script, shots and final decision.
-- 5. At most max_parallel_video_attempts generations run side by side.
--
-- The three new flags are created switched off.
-- =====================================================================
begin;

do $$
begin
    if to_regclass('public.step_prompts') is null
       or to_regclass('public.script_votes') is null
       or not exists (select 1 from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 1)
    then
        raise exception 'M417_010_NOT_FOUND: apply 010_film_grammar.sql first';
    end if;
end $$;
HEAD
cat short_a.sql short_prompts.sql short_prompts_b.sql >> $OUT
# the same permission blocks as the full schema
awk '/^insert into public.events/{exit} {print}' p10_grants.sql >> $OUT
cat >> $OUT <<'TAIL'
insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_012_APPLIED', 'INFO', 'CONTROL_PLANE', 'Short format: keyframe first, camera plan (012) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
TAIL
wc -l $OUT
