CREATE OR REPLACE FUNCTION public.authorize_episode_production(p_episode_id uuid)
 RETURNS TABLE(episode_id uuid, production_authorized boolean, authorized_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_state text;
    v_human_approved boolean;
    v_authorized_at timestamptz;
begin

    select
        e.state,
        e.human_approved
    into
        v_state,
        v_human_approved
    from public.episodes e
    where e.id = p_episode_id
    for update;

    if not found then
        raise exception 'EPISODE_NOT_FOUND';
    end if;

    if v_human_approved is not true then
        raise exception 'HUMAN_APPROVAL_REQUIRED';
    end if;

    if v_state <> 'APPROVED' then
        raise exception 'EPISODE_NOT_APPROVED';
    end if;

    v_authorized_at := now();

    update public.episodes
    set
        production_authorized = true,
        authorized_at = v_authorized_at,
        state = 'PRODUCTION'
    where id = p_episode_id;

    insert into public.events (
        event_type,
        episode_id,
        severity,
        source,
        message
    )
    values (
        'PRODUCTION_AUTHORIZED',
        p_episode_id,
        'INFO',
        'CONTROL_PLANE',
        'Episode production authorized'
    );

    return query
    select
        p_episode_id,
        true,
        v_authorized_at;

end;
$function$
