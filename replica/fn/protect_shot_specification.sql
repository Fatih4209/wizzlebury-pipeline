CREATE OR REPLACE FUNCTION public.protect_shot_specification()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_supersession boolean;
begin

    v_supersession :=
        coalesce(
            current_setting('m417.spec_supersession', true),
            'off'
        ) = 'on';


    if old.status = 'LOCKED' then

        if v_supersession then

            -- Retire the old active specification.
            if new.status = 'SUPERSEDED'
               and old.is_active = true
               and new.is_active = false
               and (to_jsonb(new) - 'status' - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'status' - 'is_active' - 'updated_at')
            then
                return new;
            end if;

            -- Activate the new locked specification.
            if new.status = 'LOCKED'
               and old.is_active = false
               and new.is_active = true
               and (to_jsonb(new) - 'is_active' - 'updated_at')
                   = (to_jsonb(old) - 'is_active' - 'updated_at')
            then
                return new;
            end if;

        end if;

        raise exception
            'LOCKED_SHOT_SPECIFICATION_IS_IMMUTABLE';

    end if;


    if new.status = 'LOCKED'
       and old.status <> 'HUMAN_APPROVED'
    then
        raise exception
            'SHOT_SPEC_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    end if;


    if new.status = 'LOCKED'
       and new.locked_at is null
    then
        new.locked_at := now();
    end if;


    return new;

end;
$function$
