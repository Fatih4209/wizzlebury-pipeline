CREATE OR REPLACE FUNCTION public.request_human_approval(p_scope_type text, p_scope_id uuid, p_requested_by text, p_summary jsonb DEFAULT '{}'::jsonb, p_ttl_hours integer DEFAULT 72)
 RETURNS TABLE(request_id uuid, token text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_token text;
    v_request_id uuid;
    v_expires_at timestamptz;
    v_scope_version integer;
    v_state text;
begin

    if p_scope_type not in (
        'EPISODE_PRODUCTION',
        'EPISODE_PUBLISH',
        'SHOT_ESCALATION'
    ) then
        raise exception 'INVALID_APPROVAL_SCOPE';
    end if;

    if p_scope_id is null then
        raise exception 'APPROVAL_SCOPE_ID_REQUIRED';
    end if;

    if p_requested_by is null or btrim(p_requested_by) = '' then
        raise exception 'APPROVAL_REQUESTER_REQUIRED';
    end if;

    if p_ttl_hours is null
       or p_ttl_hours < 1
       or p_ttl_hours > 720
    then
        raise exception 'INVALID_APPROVAL_TTL';
    end if;


    if p_scope_type in ('EPISODE_PRODUCTION', 'EPISODE_PUBLISH') then

        select e.production_version, e.state
        into v_scope_version, v_state
        from public.episodes e
        where e.id = p_scope_id;

        if not found then
            raise exception 'EPISODE_NOT_FOUND';
        end if;

        if p_scope_type = 'EPISODE_PRODUCTION'
           and v_state <> 'PREPRODUCTION'
        then
            raise exception
                'EPISODE_NOT_AWAITING_PRODUCTION_APPROVAL: %',
                v_state;
        end if;

        if p_scope_type = 'EPISODE_PUBLISH'
           and v_state <> 'READY_TO_PUBLISH'
        then
            raise exception
                'EPISODE_NOT_AWAITING_PUBLISH_APPROVAL: %',
                v_state;
        end if;

    else

        select s.state
        into v_state
        from public.shots s
        where s.id = p_scope_id;

        if not found then
            raise exception 'SHOT_NOT_FOUND';
        end if;

        if v_state <> 'ESCALATED' then
            raise exception
                'SHOT_NOT_ESCALATED: %',
                v_state;
        end if;

    end if;


    -- A new request replaces a pending one for the same subject.
    update public.approval_requests ar
    set status = 'SUPERSEDED'
    where ar.scope_type = p_scope_type
      and ar.scope_id = p_scope_id
      and ar.status = 'PENDING';


    v_token :=
        replace(gen_random_uuid()::text, '-', '')
        || replace(gen_random_uuid()::text, '-', '');

    v_expires_at :=
        now() + make_interval(hours => p_ttl_hours);


    insert into public.approval_requests (
        scope_type,
        scope_id,
        scope_version,
        token_hash,
        requested_by,
        summary,
        expires_at
    )
    values (
        p_scope_type,
        p_scope_id,
        v_scope_version,
        encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
        p_requested_by,
        coalesce(p_summary, '{}'::jsonb),
        v_expires_at
    )
    returning id
    into v_request_id;


    return query
    select v_request_id, v_token, v_expires_at;

end;
$function$
