CREATE OR REPLACE FUNCTION public.supersede_shot_specification(p_new_specification_id uuid, p_actor text, p_reason text)
 RETURNS TABLE(shot_id uuid, old_specification_id uuid, new_specification_id uuid, new_version integer, retired_routing_decisions integer, next_step text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_shot_id uuid;
    v_new_status text;
    v_new_active boolean;
    v_new_version integer;
    v_new_locked_at timestamptz;

    v_old_id uuid;
    v_old_status text;
    v_old_version integer;

    v_shot_state text;
    v_retired integer := 0;
begin

    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'ACTOR_REQUIRED';
    end if;

    if p_reason is null or btrim(p_reason) = '' then
        raise exception 'REASON_REQUIRED';
    end if;


    select
        ss.shot_id,
        ss.status,
        ss.is_active,
        ss.version,
        ss.locked_at
    into
        v_shot_id,
        v_new_status,
        v_new_active,
        v_new_version,
        v_new_locked_at
    from public.shot_specifications ss
    where ss.id = p_new_specification_id;

    if not found then
        raise exception 'NEW_SPECIFICATION_NOT_FOUND';
    end if;


    select s.state
    into v_shot_state
    from public.shots s
    where s.id = v_shot_id
    for update;

    if v_shot_state in (
        'LOCKED',
        'CANCELLED',
        'QUEUED',
        'GENERATING',
        'GENERATED',
        'QC_PENDING'
    ) then
        raise exception
            'SHOT_STATE_DOES_NOT_ALLOW_NEW_SPECIFICATION: %',
            v_shot_state;
    end if;


    if exists (
        select 1
        from public.attempts a
        where a.shot_id = v_shot_id
          and a.status in (
              'CREATED',
              'BUDGET_RESERVED',
              'SUBMITTED',
              'GENERATING'
          )
    ) then
        raise exception 'SHOT_HAS_ACTIVE_ATTEMPT';
    end if;


    if v_new_status <> 'LOCKED'
       or v_new_locked_at is null
    then
        raise exception
            'NEW_SPECIFICATION_MUST_BE_LOCKED: %',
            v_new_status;
    end if;

    if v_new_active is true then
        raise exception 'NEW_SPECIFICATION_ALREADY_ACTIVE';
    end if;


    select ss.id, ss.status, ss.version
    into v_old_id, v_old_status, v_old_version
    from public.shot_specifications ss
    where ss.shot_id = v_shot_id
      and ss.is_active = true
    for update;

    if not found then
        raise exception 'ACTIVE_SPECIFICATION_NOT_FOUND';
    end if;

    if v_old_status <> 'LOCKED' then
        raise exception
            'ACTIVE_SPECIFICATION_NOT_LOCKED: %',
            v_old_status;
    end if;

    if v_new_version <= v_old_version then
        raise exception
            'NEW_SPECIFICATION_VERSION_MUST_INCREASE: % <= %',
            v_new_version,
            v_old_version;
    end if;


    perform set_config('m417.spec_supersession', 'on', true);

    update public.shot_specifications
    set
        status = 'SUPERSEDED',
        is_active = false
    where id = v_old_id;

    update public.shot_specifications
    set is_active = true
    where id = p_new_specification_id;

    perform set_config('m417.spec_supersession', 'off', true);


    -- Unused routing decisions made for the old specification must
    -- not be handed out again.
    perform set_config('m417.routing_supersession', 'on', true);

    update public.generation_routing_decisions grd
    set is_current = false
    where grd.shot_id = v_shot_id
      and grd.is_current = true
      and grd.shot_specification_id <> p_new_specification_id
      and grd.decision_status <> 'PENDING'
      and not exists (
          select 1
          from public.attempts a
          where a.routing_decision_id = grd.id
      );

    get diagnostics v_retired = row_count;

    perform set_config('m417.routing_supersession', 'off', true);


    insert into public.events (
        event_type,
        shot_id,
        severity,
        source,
        message,
        metadata
    )
    values (
        'SHOT_SPECIFICATION_SUPERSEDED',
        v_shot_id,
        'WARNING',
        'CONTROL_PLANE',
        'Active shot specification replaced.',
        jsonb_build_object(
            'old_specification_id', v_old_id,
            'old_version', v_old_version,
            'new_specification_id', p_new_specification_id,
            'new_version', v_new_version,
            'actor', p_actor,
            'reason', p_reason,
            'retired_routing_decisions', v_retired
        )
    );


    return query
    select
        v_shot_id,
        v_old_id,
        p_new_specification_id,
        v_new_version,
        v_retired,
        'NEW_MANIFEST_VERSION_REQUIRED'::text;

end;
$function$
