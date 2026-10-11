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
