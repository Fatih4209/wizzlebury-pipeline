CREATE OR REPLACE FUNCTION public.protect_production_manifest()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN

    IF OLD.status = 'LOCKED' THEN
        RAISE EXCEPTION
            'LOCKED_PRODUCTION_MANIFEST_IS_IMMUTABLE';
    END IF;


    IF NEW.status = 'LOCKED'
       AND OLD.status <> 'HUMAN_APPROVED'
    THEN
        RAISE EXCEPTION
            'MANIFEST_MUST_BE_HUMAN_APPROVED_BEFORE_LOCK';
    END IF;


    IF NEW.status = 'LOCKED'
       AND NEW.human_approved IS NOT TRUE
    THEN
        RAISE EXCEPTION
            'MANIFEST_HUMAN_APPROVAL_REQUIRED';
    END IF;


    IF NEW.status = 'LOCKED'
       AND NEW.locked_at IS NULL
    THEN
        NEW.locked_at := now();
    END IF;


    RETURN NEW;

END;
$function$
