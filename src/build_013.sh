#!/bin/bash
# Builds 013_one_event.sql from the same parts the full schema uses.
set -e
cd "$(dirname "$0")"
OUT=013_one_event.sql
fn() { awk -v n="$1" 'index($0, "create or replace function " n "(") == 1 {p=1} p {print} p && /^\$function\$;/ {exit}' short_a.sql; }
cat > $OUT <<'HEAD'
-- =====================================================================
-- M417 / WIZZLEBURY  -  013 one event per shot
--
-- Run after 012. Safe to run more than once; one transaction.
-- Nothing is generated and nothing is spent by running this file.
--
-- 1. A shot of a short carries one event and the reaction to it: at most
--    max_beats_per_shot timed beats (3). More is refused with the reason.
--    The shot instructions say so (SHOT_PACKAGE version 3).
-- 2. The list of recent shorts given to the topic writer no longer
--    contains cancelled jobs.
-- =====================================================================
begin;

do $$
begin
    if to_regprocedure('m417_internal.validate_camera_plan(uuid, jsonb)') is null
       or not exists (select 1 from public.step_prompts where prompt_code = 'SHOT_PACKAGE' and version = 2)
    then
        raise exception 'M417_012_NOT_FOUND: apply 012_short_format.sql first';
    end if;
end $$;

insert into public.system_settings (key, value_numeric, description) values
    ('max_beats_per_shot', 3, 'Most timed beats in one shot of a short: one event and the reaction to it.')
on conflict (key) do nothing;

HEAD
fn m417_internal.validate_one_event >> $OUT
fn m417_internal.validate_shot_package >> $OUT
awk 'index($0, "create or replace function m417_internal.step_prompt(") == 1 {p=1} p {print} p && /^\$function\$;/ {exit}' short_a.sql >> $OUT
cat short_prompts_b.sql >> $OUT
cat >> $OUT <<'TAIL'

do $$
declare
    v_role text;
begin
    execute 'revoke all on function m417_internal.validate_one_event(uuid, jsonb) from public';
    foreach v_role in array array['anon', 'authenticated', 'service_role']
    loop
        if exists (select 1 from pg_roles where rolname = v_role) then
            execute format('revoke all on function m417_internal.validate_one_event(uuid, jsonb) from %I', v_role);
        end if;
    end loop;
end $$;

insert into public.events (event_type, severity, source, message, metadata)
values ('SCHEMA_013_APPLIED', 'INFO', 'CONTROL_PLANE', 'One event per shot (013) applied.',
        jsonb_build_object('applied_at', now()));

notify pgrst, 'reload schema';

commit;
TAIL
wc -l $OUT
