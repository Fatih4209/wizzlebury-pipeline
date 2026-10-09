#!/bin/bash
# Builds 010_film_grammar.sql from the same parts the full schema uses.
set -e
cd "$(dirname "$0")"
python3 gen_film.py >/dev/null
OUT=010_film_grammar.sql
cat > $OUT <<'HEAD'
-- =====================================================================
-- M417 / WIZZLEBURY  -  010 film grammar and the two-yes rule
--
-- Run after 009. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- 1. Two-yes rule. The Assistant Director (OpenAI) scores the script and
--    votes YES or NO in the answer that carries the shots; a NO sends
--    the script back to the Head Director (Claude) with the reasons, and
--    after repeated NOs the topic is dropped. The Head Director's final
--    approval is the second YES. Without both, nothing is committed, so
--    no voice and no video is paid for.
-- 2. Film rules. A script fixes hook, payoff, look, one outfit per
--    character and every prop. A shot package is a planned edit: shot
--    sizes, cut lengths to a tenth of a second, timed beats, one spoken
--    line per shot and how its speaker is staged.
-- 3. The edit uses a cut out of every generated clip, long enough for
--    the voice spoken in it; voices can no longer overlap.
-- 4. Every shot prompt carries wardrobe, props and look in identical
--    words; a rejected take tells the next one what to avoid.
-- 5. The instructions for topic, script, shots, pre-QC and final
--    decision live in the database (step_prompts) and are handed to
--    Make as prompt_text.
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.validate_shot_package(uuid,jsonb)') is null
       or not exists (select 1 from public.system_settings where key = 'video_prompt_min_chars')
    then
        raise exception 'M417_009_NOT_FOUND: apply 009_shot_package_rules.sql first';
    end if;
end $$;
HEAD
for f in p01b_film_schema.sql film_a.sql film_b.sql film_c.sql film_d.sql film_prompts.sql; do cat $f >> $OUT; done
cat >> $OUT <<'TAIL'

-- ----- permissions ---------------------------------------------------
do $$
declare
    r record;
    v_role text;
begin
    for r in
        select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'm417_internal'
           or (n.nspname = 'public' and p.proname = 'set_video_wardrobe')
    loop
        execute format('revoke all on function %s from public', r.sig);
        foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
            if exists (select 1 from pg_roles where rolname = v_role) then
                execute format('revoke all on function %s from %I', r.sig, v_role);
            end if;
        end loop;
    end loop;
end $$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_010_APPLIED', 'INFO', 'CONTROL_PLANE', 'Film grammar and two-yes rule (010) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
TAIL
wc -l $OUT
