-- =====================================================================
-- M417 / WIZZLEBURY  -  019 one continuous take, uniforms, set dressing
--
-- 13 October, the owner: an episode is ONE continuous take of about two
-- minutes (no scenes cut together), Shorts are cut out of it afterwards.
-- The Google video model makes about 10 seconds at a time, but it can
-- EXTEND a stored video from its last moment ("previousInteractionId",
-- store = true). Tested: piece 1 (10 s) + extension = one 20 s video
-- without a cut, same faces and room.
--
-- Make scenario "M417-Google Uzat (tek cekim zinciri)" (7933095, webhook
-- in setting webhook_extend) takes {mode: start|extend, image_url, prev_id,
-- prompt, path}: start = image to video from the first picture, extend =
-- continue the previous interaction. It uploads the (whole, growing) video
-- to path and calls public.chain_save(path, interaction_id, status).
-- public.chain_plan holds the pieces of a take, m417_internal.chain_tick()
-- (pg_cron m417-chain, every minute) sends the next piece as soon as the
-- previous one has arrived. The last piece's file is the whole take.
--
-- Also: the owner's school uniform (wardrobe 'uniform') and the set
-- dressing of the locked classroom (public.auto_sets) - the locked rooms
-- keep their architecture, the missing objects are a layout record.
-- Lesson: the Supabase MCP tool cancels queries whose quoted text contains
-- a semicolon - all prompt texts here are written without one.
-- Applied live 13 October. Safe to run more than once.
-- =====================================================================
begin;

insert into public.auto_shorts_settings (key, value, description) values
    ('webhook_extend', 'https://hook.eu1.make.com/h80lmiy3td30y5ycv5vb9yujehqpcj78', 'Make: Google video start / extend (continuous one take). {mode: start|extend, image_url, prev_id, prompt, path}')
on conflict (key) do nothing;

create table if not exists public.auto_chain (
    path text primary key,
    interaction_id text,
    status text,
    created_at timestamptz not null default now()
);
alter table public.auto_chain enable row level security;

create or replace function public.chain_save(p_path text, p_id text, p_status text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
begin
    insert into public.auto_chain (path, interaction_id, status) values (p_path, p_id, p_status)
    on conflict (path) do update set interaction_id = excluded.interaction_id, status = excluded.status, created_at = now();
    return jsonb_build_object('saved', true);
end;
$function$;
do $do$
begin
    revoke all on function public.chain_save(text, text, text) from public;
    if exists (select 1 from pg_roles where rolname = 'anon') then
        revoke all on function public.chain_save(text, text, text) from anon, authenticated;
        grant execute on function public.chain_save(text, text, text) to service_role;
    end if;
end $do$;

create table if not exists public.chain_plan (
    take text not null,
    n integer not null,
    prompt text not null,
    image_url text,
    sent_at timestamptz,
    tries integer not null default 0,
    primary key (take, n)
);
alter table public.chain_plan enable row level security;

create or replace function m417_internal.chain_path(p_take text, p_n integer)
 returns text language sql immutable set search_path to ''
as $function$
    select 'auto/chain/' || p_take || '/P' || lpad(p_n::text, 2, '0') || '.mp4';
$function$;

create or replace function m417_internal.chain_tick()
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    r public.chain_plan;
    v_prev text;
    v_out jsonb := '[]'::jsonb;
begin
    if not pg_try_advisory_xact_lock(417018) then
        return jsonb_build_object('chain', 'busy');
    end if;
    for r in
        select distinct on (p.take) p.* from public.chain_plan p
        where not exists (select 1 from public.auto_chain c where c.path = m417_internal.chain_path(p.take, p.n))
        order by p.take, p.n
    loop
        if r.sent_at is not null and now() - r.sent_at < interval '10 minutes' then
            v_out := v_out || jsonb_build_object('take', r.take, 'n', r.n, 'state', 'waiting');
            continue;
        end if;
        if r.sent_at is not null and r.tries >= 2 then
            v_out := v_out || jsonb_build_object('take', r.take, 'n', r.n, 'state', 'stuck');
            continue;
        end if;
        if r.n = 1 then
            perform m417_internal.as_post(m417_internal.as_set('webhook_extend'), jsonb_build_object(
                'mode', 'start', 'image_url', r.image_url, 'prompt', r.prompt, 'path', m417_internal.chain_path(r.take, 1)));
        else
            select c.interaction_id into v_prev from public.auto_chain c where c.path = m417_internal.chain_path(r.take, r.n - 1);
            if v_prev is null then
                continue;
            end if;
            perform m417_internal.as_post(m417_internal.as_set('webhook_extend'), jsonb_build_object(
                'mode', 'extend', 'prev_id', v_prev, 'prompt', r.prompt, 'path', m417_internal.chain_path(r.take, r.n)));
        end if;
        update public.chain_plan set sent_at = now(), tries = tries + 1 where take = r.take and n = r.n;
        v_out := v_out || jsonb_build_object('take', r.take, 'n', r.n, 'state', 'sent');
    end loop;
    return jsonb_build_object('chain', v_out);
end;
$function$;
revoke all on function m417_internal.chain_tick() from public;

-- the school uniform (owner, 13 October), every child in his own colour of backpack
insert into public.auto_wardrobe (character_code, wardrobe, outfit_frame, outfit_clip) values
('FATIH', 'uniform', 'the school uniform: a white short-sleeved polo shirt with a thin navy collar trim, a navy knitted sweater vest with a small round sky-blue school badge without any letters, grey trousers, navy socks and black shoes, and his own red backpack', 'the school uniform with a navy sweater vest and his red backpack'),
('MIA', 'uniform', 'the school uniform: a white short-sleeved polo shirt with a thin navy collar trim, a navy knitted sweater vest with a small round sky-blue school badge without any letters, a navy pleated skirt that reaches her knees, white knee socks and black shoes, a small lilac hair clip, and her own purple backpack', 'the school uniform with a navy sweater vest and pleated skirt, a lilac hair clip and her purple backpack'),
('TOMBIK', 'uniform', 'the school uniform: a white short-sleeved polo shirt with a thin navy collar trim, a navy knitted sweater vest with a small round sky-blue school badge without any letters, grey trousers, navy socks and black shoes, and his own yellow backpack', 'the school uniform with a navy sweater vest and his yellow backpack'),
('OMER', 'uniform', 'the school uniform: a white short-sleeved polo shirt with a thin navy collar trim, a navy knitted sweater vest with a small round sky-blue school badge without any letters, grey trousers, navy socks and white sneakers with orange laces, and his own orange backpack', 'the school uniform with a navy sweater vest and his orange backpack'),
('BRUCE', 'uniform', 'the school uniform: a white short-sleeved polo shirt with a thin navy collar trim, a navy knitted sweater vest with a small round sky-blue school badge without any letters, grey trousers, navy socks and black shoes, and his own teal backpack', 'the school uniform with a navy sweater vest and his teal backpack')
on conflict (character_code, wardrobe) do update set outfit_frame = excluded.outfit_frame, outfit_clip = excluded.outfit_clip;

-- set dressing of the locked classroom (owner's list, 13 October)
create table if not exists public.auto_sets (
    code text primary key,
    place_code text not null references public.auto_places (code),
    dressing text not null,
    notes text
);
alter table public.auto_sets enable row level security;
insert into public.auto_sets (code, place_code, dressing, notes) values
('CLASSROOM_SET_V1', 'CLASSROOM_REVERSE',
 'Set dressing added to the locked room without changing its walls, windows, door or furniture layout. Student desks: neat rows of separate wooden desks for two, each child with a personal working area. On every desk: a textbook, a notebook, a pencil case, a pencil, an eraser and a plain homework folder. Backpacks: every child has a backpack of a different colour hanging on the chair. Teacher desk: a homework tray, a pen pot, an attendance book, a few books and a shiny red star trophy. Walls: a colourful alphabet poster with big friendly letters, the world map, a poster of class rules drawn as simple pictures, children''s drawings pinned up, a round wall clock and a notice board. Back of the room: a bookshelf, a green classroom plant, a blue recycling bin and a board showing the children''s work. Windows: the same fixed windows with warm morning light. Door: the classroom door to the corridor, always in the same place on the left of the back wall in this view, the door through which Fatih''s dad will come in. All children of the class wear the same school uniform: a white short-sleeved polo shirt with a thin navy collar trim, a navy knitted sweater vest with a small round sky-blue school badge without any letters, grey trousers or a navy pleated skirt.',
 'Owner, 13 Oct: the locked rooms CLASSROOM_MASTER_V1 and CLASSROOM_REVERSE_V1 keep their architecture, the missing objects are defined here as a set layout record.')
on conflict (code) do update set dressing = excluded.dressing, notes = excluded.notes, place_code = excluded.place_code;

do $do$
begin
    if exists (select 1 from pg_extension where extname = 'pg_cron') then
        perform cron.schedule('m417-chain', '* * * * *', 'select m417_internal.chain_tick()');
    end if;
end $do$;

commit;
