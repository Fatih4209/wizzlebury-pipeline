CREATE OR REPLACE FUNCTION public.validate_generation_output_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_attempt_shot_id uuid;
BEGIN

    SELECT a.shot_id
    INTO v_attempt_shot_id
    FROM public.attempts a
    WHERE a.id = NEW.attempt_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'GENERATION_OUTPUT_ATTEMPT_NOT_FOUND';
    END IF;


    IF v_attempt_shot_id <> NEW.shot_id THEN
        RAISE EXCEPTION
            'GENERATION_OUTPUT_SHOT_MISMATCH';
    END IF;


    RETURN NEW;

END;
$function$
