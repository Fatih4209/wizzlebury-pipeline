CREATE OR REPLACE FUNCTION public.validate_micro_short_production_mode()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_mode text;
    v_episode_id uuid;
    v_total_duration numeric;
    v_invalid_specs integer;
BEGIN

    -- -----------------------------------------------------
    -- EPISODE DIRECT VALIDATION
    -- -----------------------------------------------------

    IF TG_TABLE_NAME = 'episodes' THEN

        IF NEW.production_mode = 'MICRO_SHORT'
           AND NEW.state NOT IN (
               'PLANNED',
               'PREPRODUCTION',
               'BLOCKED',
               'CANCELLED'
           )
        THEN

            SELECT
                COALESCE(SUM(ss.duration_seconds), 0),

                COUNT(*) FILTER (
                    WHERE ss.aspect_ratio <> '9:16'
                       OR ss.duration_seconds < 1
                       OR ss.duration_seconds > 15
                )

            INTO
                v_total_duration,
                v_invalid_specs

            FROM public.shots s

            JOIN public.shot_specifications ss
              ON ss.shot_id = s.id
             AND ss.is_active = true

            WHERE s.episode_id = NEW.id;

            IF v_invalid_specs > 0 THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_FORMAT_INVALID';
            END IF;

            IF v_total_duration < 6
               OR v_total_duration > 15
            THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_TOTAL_DURATION_INVALID: %',
                    v_total_duration;
            END IF;

        END IF;

        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- SHOT SPECIFICATION VALIDATION
    -- -----------------------------------------------------

    IF TG_TABLE_NAME = 'shot_specifications' THEN

        SELECT
            s.episode_id,
            e.production_mode

        INTO
            v_episode_id,
            v_mode

        FROM public.shots s

        JOIN public.episodes e
          ON e.id = s.episode_id

        WHERE s.id = NEW.shot_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'SHOT_EPISODE_NOT_FOUND';
        END IF;


        IF v_mode = 'MICRO_SHORT'
           AND NEW.is_active = true
        THEN

            IF NEW.aspect_ratio <> '9:16' THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_REQUIRES_9_16';
            END IF;

            IF NEW.duration_seconds < 1
               OR NEW.duration_seconds > 15
            THEN
                RAISE EXCEPTION
                    'MICRO_SHORT_SHOT_DURATION_INVALID';
            END IF;

        END IF;

        RETURN NEW;
    END IF;


    RETURN NEW;

END;
$function$
