CREATE OR REPLACE FUNCTION public.protect_locked_shot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if old.state = 'LOCKED' then

        if
            new.episode_id is distinct from old.episode_id
            or new.shot_code is distinct from old.shot_code
            or new.shot_order is distinct from old.shot_order
            or new.prompt_version is distinct from old.prompt_version
            or new.asset_version is distinct from old.asset_version
            or new.model_version is distinct from old.model_version
            or new.maximum_budget is distinct from old.maximum_budget
            or new.currency is distinct from old.currency
            or new.locked_at is distinct from old.locked_at
        then
            raise exception 'LOCKED_SHOT_PRODUCTION_FIELDS_IMMUTABLE';
        end if;

    end if;

    return new;

end;
$function$
