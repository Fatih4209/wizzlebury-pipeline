CREATE OR REPLACE FUNCTION public.protect_episode_creative_profile_binding()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN

    IF OLD.state IN (
        'APPROVED',
        'PRODUCTION',
        'ASSEMBLY',
        'FINAL_QC',
        'READY_TO_PUBLISH',
        'PUBLISHED'
    )
    AND (
        NEW.creative_profile_id IS DISTINCT FROM
            OLD.creative_profile_id

        OR

        NEW.production_mode IS DISTINCT FROM
            OLD.production_mode
    )
    THEN

        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_BINDING_IS_IMMUTABLE';

    END IF;


    RETURN NEW;

END;
$function$
