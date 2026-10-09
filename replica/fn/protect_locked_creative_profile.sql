CREATE OR REPLACE FUNCTION public.protect_locked_creative_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN

    IF TG_OP = 'DELETE' THEN

        IF OLD.status = 'LOCKED' THEN
            RAISE EXCEPTION
                'LOCKED_CREATIVE_PROFILE_CANNOT_BE_DELETED';
        END IF;

        RETURN OLD;

    END IF;


    IF OLD.status = 'LOCKED' THEN

        RAISE EXCEPTION
            'LOCKED_CREATIVE_PROFILE_IS_IMMUTABLE';

    END IF;


    IF NEW.status = 'LOCKED'
       AND NEW.locked_at IS NULL
    THEN

        NEW.locked_at := now();

    END IF;


    RETURN NEW;

END;
$function$
