CREATE OR REPLACE FUNCTION public.decide_human_approval(p_token text, p_decision text, p_decided_by text, p_channel text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS TABLE(request_id uuid, scope_type text, scope_id uuid, status text, effect text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_row public.approval_requests;
    v_effect text := 'RECORDED';
    v_version integer;
    v_state text;
begin

    v_row := public.consume_approval_token(
        p_token,
        null,
        p_decision,
        p_decided_by,
        p_channel,
        p_note
    );


    if v_row.scope_type = 'SHOT_ESCALATION' then
        -- Escalations carry a choice, so they are decided through
        -- resolve_escalated_shot.
        raise exception 'USE_RESOLVE_ESCALATED_SHOT';
    end if;


    select e.production_version, e.state
    into v_version, v_state
    from public.episodes e
    where e.id = v_row.scope_id
    for update;

    if not found then
        raise exception 'EPISODE_NOT_FOUND';
    end if;

    if v_version is distinct from v_row.scope_version then
        raise exception
            'APPROVAL_VERSION_STALE: requested for v%, episode is v%',
            v_row.scope_version,
            v_version;
    end if;


    if v_row.scope_type = 'EPISODE_PRODUCTION' then

        if v_state <> 'PREPRODUCTION' then
            raise exception
                'EPISODE_NOT_AWAITING_PRODUCTION_APPROVAL: %',
                v_state;
        end if;

        if p_decision = 'APPROVED' then

            update public.episodes
            set
                human_approved = true,
                state = 'APPROVED'
            where id = v_row.scope_id;

            v_effect := 'EPISODE_APPROVED_FOR_PRODUCTION';

        end if;

    elsif v_row.scope_type = 'EPISODE_PUBLISH' then

        if v_state <> 'READY_TO_PUBLISH' then
            raise exception
                'EPISODE_NOT_AWAITING_PUBLISH_APPROVAL: %',
                v_state;
        end if;

        if p_decision = 'APPROVED' then
            v_effect := 'EPISODE_CLEARED_TO_PUBLISH';
        end if;

    end if;


    insert into public.events (
        event_type,
        episode_id,
        severity,
        source,
        message,
        metadata
    )
    values (
        'HUMAN_APPROVAL_' || p_decision,
        v_row.scope_id,
        case when p_decision = 'APPROVED' then 'INFO' else 'WARNING' end,
        'HUMAN_APPROVAL',
        v_row.scope_type || ' ' || lower(p_decision) || ' by ' || p_decided_by,
        jsonb_build_object(
            'request_id', v_row.id,
            'scope_type', v_row.scope_type,
            'scope_version', v_row.scope_version,
            'decided_by', p_decided_by,
            'channel', p_channel,
            'note', p_note
        )
    );


    return query
    select
        v_row.id,
        v_row.scope_type,
        v_row.scope_id,
        v_row.status,
        v_effect;

end;
$function$
