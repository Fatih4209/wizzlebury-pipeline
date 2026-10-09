CREATE OR REPLACE FUNCTION public.require_production_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_authorized boolean;
begin

    if new.status = 'BUDGET_RESERVED'
       and old.status = 'CREATED'
    then

        select e.production_authorized
        into v_authorized
        from public.shots s
        join public.episodes e
            on e.id = s.episode_id
        where s.id = new.shot_id;

        if coalesce(v_authorized, false) is not true then
            raise exception 'PRODUCTION_NOT_AUTHORIZED';
        end if;

    end if;

    return new;
end;
$function$
