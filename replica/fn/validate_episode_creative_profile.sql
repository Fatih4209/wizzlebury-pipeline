CREATE OR REPLACE FUNCTION public.validate_episode_creative_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_profile_mode text;
    v_profile_status text;
    v_locked_at timestamptz;
BEGIN

    -- -----------------------------------------------------
    -- Planning may begin before a profile is selected.
    -- Production lifecycle may not.
    -- -----------------------------------------------------

    IF NEW.creative_profile_id IS NULL THEN

        IF NEW.state NOT IN (
            'PLANNED',
            'BLOCKED',
            'CANCELLED'
        ) THEN

            RAISE EXCEPTION
                'EPISODE_CREATIVE_PROFILE_REQUIRED';

        END IF;

        RETURN NEW;

    END IF;


    -- -----------------------------------------------------
    -- Resolve canonical profile.
    -- -----------------------------------------------------

    SELECT
        p.production_mode,
        p.status,
        p.locked_at

    INTO
        v_profile_mode,
        v_profile_status,
        v_locked_at

    FROM public.production_creative_profiles p

    WHERE p.id = NEW.creative_profile_id;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_NOT_FOUND';

    END IF;


    -- -----------------------------------------------------
    -- Profile must match episode production mode.
    -- -----------------------------------------------------

    IF v_profile_mode IS DISTINCT FROM
       NEW.production_mode
    THEN

        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_MODE_MISMATCH';

    END IF;


    -- -----------------------------------------------------
    -- Only canonical LOCKED profiles may be bound.
    -- -----------------------------------------------------

    IF v_profile_status <> 'LOCKED'
       OR v_locked_at IS NULL
    THEN

        RAISE EXCEPTION
            'EPISODE_CREATIVE_PROFILE_NOT_LOCKED';

    END IF;


    RETURN NEW;

END;
$function$
