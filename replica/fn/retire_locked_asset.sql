CREATE OR REPLACE FUNCTION public.retire_locked_asset(p_asset_id uuid, p_actor text, p_reason text)
 RETURNS TABLE(asset_id uuid, asset_code text, version integer, affected_open_shots integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_status text;
    v_code text;
    v_version integer;
    v_affected integer;
begin

    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;

    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;


    select ar.status, ar.asset_code, ar.version
    into v_status, v_code, v_version
    from public.asset_registry ar
    where ar.id = p_asset_id
    for update;

    if not found then
        raise exception 'ASSET_NOT_FOUND';
    end if;

    if v_status <> 'LOCKED' then
        raise exception
            'ASSET_NOT_LOCKED: %',
            v_status;
    end if;


    -- Never pull a reference out from under a paid generation.
    if exists (
        select 1
        from public.attempts a
        join public.shot_specifications ss
          on ss.shot_id = a.shot_id
         and ss.is_active = true
        where a.status in (
                  'BUDGET_RESERVED',
                  'SUBMITTED',
                  'GENERATING'
              )
          and (
                exists (
                    select 1
                    from public.shot_reference_assets sra
                    where sra.shot_specification_id = ss.id
                      and sra.asset_id = p_asset_id
                )
                or exists (
                    select 1
                    from public.storyboard_reviews sr
                    where sr.shot_specification_id = ss.id
                      and sr.storyboard_asset_id = p_asset_id
                )
          )
    )
    then
        raise exception 'ASSET_IN_USE_BY_ACTIVE_ATTEMPT';
    end if;


    -- Shots that are not finished yet and still point at this asset.
    -- They will be blocked until they get a new specification.
    select count(distinct s.id)
    into v_affected
    from public.shots s
    join public.shot_specifications ss
      on ss.shot_id = s.id
     and ss.is_active = true
    where s.state not in ('LOCKED', 'CANCELLED')
      and (
            exists (
                select 1
                from public.shot_reference_assets sra
                where sra.shot_specification_id = ss.id
                  and sra.asset_id = p_asset_id
            )
            or exists (
                select 1
                from public.storyboard_reviews sr
                where sr.shot_specification_id = ss.id
                  and sr.storyboard_asset_id = p_asset_id
            )
      );


    perform set_config('m417.asset_retirement', 'on', true);

    update public.asset_registry
    set status = 'ARCHIVED'
    where id = p_asset_id;

    perform set_config('m417.asset_retirement', 'off', true);


    insert into public.events (
        event_type,
        severity,
        source,
        message,
        metadata
    )
    values (
        'LOCKED_ASSET_RETIRED',
        'WARNING',
        'CONTROL_PLANE',
        'Locked asset retired.',
        jsonb_build_object(
            'asset_id', p_asset_id,
            'asset_code', v_code,
            'version', v_version,
            'actor', p_actor,
            'reason', p_reason,
            'affected_open_shots', v_affected
        )
    );


    return query
    select p_asset_id, v_code, v_version, v_affected;

end;
$function$
