CREATE OR REPLACE FUNCTION public.protect_generation_model_health_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION
            'GENERATION_MODEL_HEALTH_HISTORY_IMMUTABLE';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'GENERATION_MODEL_HEALTH_HISTORY_CANNOT_BE_DELETED';
    END IF;

    RETURN NEW;

END;

$function$
