-- Test-only helpers: call public functions the way PostgREST does.
create schema if not exists t;
grant usage on schema t to service_role;
create or replace function t.rpc(p_fn text, p_args jsonb default '{}'::jsonb, p_object boolean default false)
 returns jsonb language plpgsql as $$
declare
    v_proc record;
    v_in_names text[] := array[]::text[];
    v_in_types oid[] := array[]::oid[];
    v_parts text[] := array[]::text[];
    v_key text;
    v_i integer;
    v_type oid;
    v_sql text;
    v_out jsonb;
begin
    select p.oid, p.proname, p.proargnames, p.proargmodes, p.proallargtypes, p.proargtypes, p.proretset, p.pronargs
    into v_proc
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = p_fn;
    if not found then
        raise exception 'PGRST202: function public.% not found', p_fn;
    end if;
    if not has_function_privilege(current_user, v_proc.oid, 'execute') then
        raise exception 'PGRST: permission denied for function %', p_fn;
    end if;
    for v_i in 1 .. v_proc.pronargs loop
        v_in_names := v_in_names || v_proc.proargnames[v_i];
        v_in_types := v_in_types || (v_proc.proargtypes::oid[])[v_i - 1];
    end loop;
    for v_key in select jsonb_object_keys(p_args) loop
        v_i := array_position(v_in_names, v_key);
        if v_i is null then
            raise exception 'PGRST202: no function public.% with parameter %', p_fn, v_key;
        end if;
        v_type := v_in_types[v_i];
        if v_type in ('jsonb'::regtype, 'json'::regtype) then
            v_parts := v_parts || format('%I => %L::jsonb', v_key, (p_args -> v_key)::text);
        elsif jsonb_typeof(p_args -> v_key) = 'null' then
            v_parts := v_parts || format('%I => null::%s', v_key, v_type::regtype);
        else
            v_parts := v_parts || format('%I => %L::%s', v_key, p_args ->> v_key, v_type::regtype);
        end if;
    end loop;
    if v_proc.proretset then
        v_sql := format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I(%s) x', p_fn, array_to_string(v_parts, ', '));
    else
        v_sql := format('select to_jsonb(public.%I(%s))', p_fn, array_to_string(v_parts, ', '));
    end if;
    execute v_sql into v_out;
    if p_object and jsonb_typeof(v_out) = 'array' then
        if jsonb_array_length(v_out) <> 1 then
            raise exception 'PGRST116: expected exactly one row, got %', jsonb_array_length(v_out);
        end if;
        v_out := v_out -> 0;
    end if;
    return v_out;
end $$;
grant execute on function t.rpc(text, jsonb, boolean) to service_role;

-- Simulates a file uploaded to Supabase Storage.
create or replace function t.put(p_path text, p_size bigint, p_mime text default 'audio/mpeg')
 returns void language sql as $$
    insert into storage.objects (bucket_id, name, metadata)
    values ('production-assets', p_path, jsonb_build_object('size', p_size, 'mimetype', p_mime))
    on conflict (bucket_id, name) do update set metadata = excluded.metadata;
$$;

-- The older suites exercise the pipeline with the film rules and the
-- two-yes rule off; test_film.py switches them on.
update public.system_flags set value = false where key in ('film_grammar_enforced', 'assistant_vote_required');
