CREATE OR REPLACE FUNCTION public.set_generation_enabled(p_enabled boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin

    update public.system_flags
    set value = p_enabled
    where key = 'generation_enabled';

    if not found then
        raise exception 'GENERATION_FLAG_MISSING';
    end if;

    insert into public.events (
        event_type,
        severity,
        source,
        message,
        metadata
    )
    values (
        case
            when p_enabled
            then 'GENERATION_ENABLED'
            else 'GENERATION_DISABLED'
        end,
        case
            when p_enabled
            then 'INFO'
            else 'WARNING'
        end,
        'CONTROL_PLANE',
        case
            when p_enabled
            then 'Paid generation enabled'
            else 'Paid generation disabled'
        end,
        jsonb_build_object(
            'enabled',
            p_enabled
        )
    );

    return p_enabled;

end;
$function$
