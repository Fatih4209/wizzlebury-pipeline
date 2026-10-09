CREATE OR REPLACE FUNCTION public.validate_manifest_pilot_shot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_pilot_episode_id uuid;
    v_manifest_binding_count integer;
BEGIN

    IF NEW.pilot_shot_id IS NULL THEN
        RAISE EXCEPTION
            'MANIFEST_PILOT_SHOT_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Pilot shot must belong to manifest episode.
    -- -----------------------------------------------------

    SELECT s.episode_id
    INTO v_pilot_episode_id

    FROM public.shots s

    WHERE s.id = NEW.pilot_shot_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'MANIFEST_PILOT_SHOT_NOT_FOUND';
    END IF;


    IF v_pilot_episode_id IS DISTINCT FROM NEW.episode_id THEN
        RAISE EXCEPTION
            'MANIFEST_PILOT_SHOT_EPISODE_MISMATCH';
    END IF;


    -- -----------------------------------------------------
    -- Before HUMAN_APPROVED / LOCKED, pilot must already
    -- exist inside the manifest.
    -- -----------------------------------------------------

    IF NEW.status IN (
        'HUMAN_APPROVED',
        'LOCKED'
    )
    THEN

        SELECT COUNT(*)
        INTO v_manifest_binding_count

        FROM public.production_manifest_shots pms

        JOIN public.shot_specifications ss
          ON ss.id = pms.shot_specification_id
         AND ss.shot_id = pms.shot_id

        WHERE pms.manifest_id = NEW.id
          AND pms.shot_id = NEW.pilot_shot_id;


        IF v_manifest_binding_count <> 1 THEN
            RAISE EXCEPTION
                'MANIFEST_PILOT_SHOT_BINDING_REQUIRED';
        END IF;

    END IF;


    RETURN NEW;

END;
$function$
