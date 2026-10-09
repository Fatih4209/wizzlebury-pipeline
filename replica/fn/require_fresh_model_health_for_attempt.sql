CREATE OR REPLACE FUNCTION public.require_fresh_model_health_for_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_selected_model_id uuid;
    v_decision_status text;
    v_health_status text;
    v_last_checked_at timestamptz;
    v_max_age_minutes numeric;
begin

    -- Only paid/reserved attempts require fresh health.
    if new.status <> 'BUDGET_RESERVED' then
        return new;
    end if;


    if new.routing_decision_id is null then
        raise exception 'ROUTING_DECISION_REQUIRED';
    end if;


    select
        grd.decision_status,
        grd.selected_model_id
    into
        v_decision_status,
        v_selected_model_id
    from public.generation_routing_decisions grd
    where grd.id = new.routing_decision_id
    for share;

    if not found then
        raise exception 'ROUTING_DECISION_NOT_FOUND';
    end if;

    if v_decision_status <> 'SELECTED' then
        raise exception
            'ROUTING_DECISION_NOT_SELECTED: %',
            v_decision_status;
    end if;

    if v_selected_model_id is null then
        raise exception 'ROUTING_SELECTED_MODEL_REQUIRED';
    end if;


    -- Fail closed:
    --   AVAILABLE + recent -> allowed
    --   anything else      -> blocked
    select
        gmh.availability_status,
        gmh.last_checked_at
    into
        v_health_status,
        v_last_checked_at
    from public.generation_model_health gmh
    where gmh.model_id = v_selected_model_id
    for share;

    if not found then
        raise exception
            'ROUTING_MODEL_HEALTH_MISSING';
    end if;

    if v_health_status is distinct from 'AVAILABLE' then
        raise exception
            'ROUTING_MODEL_NOT_CURRENTLY_AVAILABLE: %',
            coalesce(v_health_status, 'NULL');
    end if;

    if v_last_checked_at is null then
        raise exception
            'ROUTING_MODEL_HEALTH_NOT_VERIFIED';
    end if;


    select st.value_numeric
    into v_max_age_minutes
    from public.system_settings st
    where st.key = 'model_health_max_age_minutes';

    if not found
       or v_max_age_minutes is null
       or v_max_age_minutes <= 0
    then
        raise exception 'MODEL_HEALTH_MAX_AGE_SETTING_MISSING';
    end if;

    if v_last_checked_at
       < now() - (v_max_age_minutes * interval '1 minute')
    then
        raise exception
            'ROUTING_MODEL_HEALTH_STALE: last checked % minutes ago, limit %',
            floor(extract(epoch from (now() - v_last_checked_at)) / 60),
            v_max_age_minutes;
    end if;


    return new;

end;
$function$
