CREATE OR REPLACE FUNCTION public.require_attempt_insert_authorization()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_authorized boolean;
    v_episode_state text;
BEGIN

    -- Only paid/reserved production attempts require this gate.
    IF NEW.status = 'BUDGET_RESERVED' THEN

        SELECT
            e.production_authorized,
            e.state
        INTO
            v_authorized,
            v_episode_state

        FROM public.shots s

        JOIN public.episodes e
            ON e.id = s.episode_id

        WHERE s.id = NEW.shot_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION 'SHOT_OR_EPISODE_NOT_FOUND';
        END IF;


        IF COALESCE(v_authorized, false) IS NOT TRUE THEN
            RAISE EXCEPTION 'PRODUCTION_NOT_AUTHORIZED';
        END IF;


        IF v_episode_state <> 'PRODUCTION' THEN
            RAISE EXCEPTION
                'EPISODE_NOT_IN_PRODUCTION: %',
                v_episode_state;
        END IF;

    END IF;


    RETURN NEW;

END;
$function$
