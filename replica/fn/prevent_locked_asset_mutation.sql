CREATE OR REPLACE FUNCTION public.prevent_locked_asset_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if old.status = 'LOCKED' then

        -- Controlled retirement: only asset_registry, only
        -- LOCKED -> ARCHIVED, nothing else may change.
        if tg_table_name = 'asset_registry'
           and coalesce(
                   current_setting('m417.asset_retirement', true),
                   'off'
               ) = 'on'
           and new.status = 'ARCHIVED'
           and (to_jsonb(new) - 'status')
               = (to_jsonb(old) - 'status')
        then
            return new;
        end if;

        raise exception 'LOCKED_ASSET_IS_IMMUTABLE';

    end if;


    if new.status = 'LOCKED'
       and old.status <> 'HUMAN_APPROVED'
    then
        raise exception
            'ASSET_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    end if;


    if new.status = 'LOCKED'
       and new.locked_at is null
    then
        new.locked_at := now();
    end if;


    return new;

end;
$function$
