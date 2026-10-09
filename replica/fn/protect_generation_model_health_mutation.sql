CREATE OR REPLACE FUNCTION public.protect_generation_model_health_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE
    v_internal boolean;
BEGIN

    v_internal :=
        COALESCE(
            current_setting(
                'm417.model_health_update',
                true
            ),
            'off'
        ) = 'on';

    IF v_internal IS NOT TRUE THEN
        RAISE EXCEPTION
            'DIRECT_MODEL_HEALTH_MUTATION_FORBIDDEN';
    END IF;

    RETURN CASE
        WHEN TG_OP = 'DELETE' THEN OLD
        ELSE NEW
    END;

END;

$function$
