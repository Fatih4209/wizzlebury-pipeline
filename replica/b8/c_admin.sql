-- The owner names the public copy of a canonical reference image.
-- p_object_path is the file's path inside the public bucket.
create or replace function public.set_video_reference(
    p_asset_code text, p_object_path text, p_actor text, p_bucket text default 'public-refs')
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
    v_asset_id uuid;
    v_path text := btrim(coalesce(p_object_path, ''));
    v_bucket text := btrim(coalesce(p_bucket, ''));
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;
    select ar.id into v_asset_id
    from public.asset_registry ar
    where ar.asset_code = p_asset_code and ar.status = 'LOCKED'
    order by ar.version desc
    limit 1;
    if not found then
        raise exception 'LOCKED_ASSET_NOT_FOUND: %', coalesce(p_asset_code, '(empty)');
    end if;
    if v_path = '' or v_path ~ '^/' or v_path ~ '[[:space:]?#]' or v_bucket = '' or v_bucket ~ '[/[:space:]?#]' then
        raise exception 'REFERENCE_PATH_INVALID: %/%', v_bucket, v_path;
    end if;
    insert into public.video_reference_images (asset_id, bucket, object_path, is_active, set_by)
    values (v_asset_id, v_bucket, v_path, true, p_actor)
    on conflict (asset_id) do update
        set bucket = excluded.bucket, object_path = excluded.object_path, is_active = true,
            set_by = excluded.set_by, updated_at = now();
    insert into public.events (event_type, severity, source, message, metadata)
    values ('VIDEO_REFERENCE_SET', 'INFO', 'CONTROL_PLANE',
            'Public reference image set for ' || p_asset_code || ' by ' || p_actor,
            jsonb_build_object('asset_code', p_asset_code, 'bucket', v_bucket, 'object_path', v_path));
    return jsonb_build_object(
        'asset_code', p_asset_code, 'decision', 'SET',
        'url', rtrim(m417_internal.txt('storage_base_url', ''), '/') || '/object/public/' || v_bucket || '/' || v_path);
end;
$function$;
