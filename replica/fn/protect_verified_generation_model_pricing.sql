CREATE OR REPLACE FUNCTION public.protect_verified_generation_model_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE

    v_old_business_state jsonb;
    v_new_business_state jsonb;

BEGIN

    -- -----------------------------------------------------
    -- DELETE
    -- -----------------------------------------------------

    IF TG_OP = 'DELETE' THEN

        IF OLD.is_verified IS TRUE THEN

            RAISE EXCEPTION
                'VERIFIED_GENERATION_PRICING_CANNOT_BE_DELETED';

        END IF;


        RETURN OLD;

    END IF;


    -- -----------------------------------------------------
    -- A VERIFIED ROW MAY NEVER BECOME UNVERIFIED
    -- -----------------------------------------------------

    IF OLD.is_verified IS TRUE
       AND NEW.is_verified IS DISTINCT FROM TRUE
    THEN

        RAISE EXCEPTION
            'VERIFIED_GENERATION_PRICING_CANNOT_BE_UNVERIFIED';

    END IF;


    -- -----------------------------------------------------
    -- PROTECT VERIFIED BUSINESS STATE
    --
    -- Only effective_to + updated_at may differ.
    -- -----------------------------------------------------

    IF OLD.is_verified IS TRUE THEN

        v_old_business_state :=
            to_jsonb(OLD)
            - 'effective_to'
            - 'updated_at';

        v_new_business_state :=
            to_jsonb(NEW)
            - 'effective_to'
            - 'updated_at';


        IF v_new_business_state
            IS DISTINCT FROM
            v_old_business_state
        THEN

            RAISE EXCEPTION
                'VERIFIED_GENERATION_PRICING_IMMUTABLE_CREATE_NEW_VERSION';

        END IF;


        -- -------------------------------------------------
        -- effective_to can only be assigned once.
        -- -------------------------------------------------

        IF OLD.effective_to IS NOT NULL
           AND NEW.effective_to
                IS DISTINCT FROM OLD.effective_to
        THEN

            RAISE EXCEPTION
                'VERIFIED_PRICING_EFFECTIVE_TO_IMMUTABLE';

        END IF;


        -- -------------------------------------------------
        -- Cannot reopen an expired/closed price.
        -- -------------------------------------------------

        IF OLD.effective_to IS NOT NULL
           AND NEW.effective_to IS NULL
        THEN

            RAISE EXCEPTION
                'VERIFIED_PRICING_CANNOT_BE_REOPENED';

        END IF;


        -- -------------------------------------------------
        -- Closing timestamp must be after effective_from.
        -- -------------------------------------------------

        IF NEW.effective_to IS NOT NULL
           AND NEW.effective_to <= OLD.effective_from
        THEN

            RAISE EXCEPTION
                'VERIFIED_PRICING_INVALID_EFFECTIVE_TO';

        END IF;

    END IF;


    -- -----------------------------------------------------
    -- NEWLY VERIFIED ROW REQUIREMENTS
    -- -----------------------------------------------------

    IF OLD.is_verified IS DISTINCT FROM TRUE
       AND NEW.is_verified IS TRUE
    THEN

        IF NEW.verified_at IS NULL THEN

            RAISE EXCEPTION
                'VERIFIED_PRICING_REQUIRES_VERIFIED_AT';

        END IF;


        IF NEW.effective_from IS NULL THEN

            RAISE EXCEPTION
                'VERIFIED_PRICING_REQUIRES_EFFECTIVE_FROM';

        END IF;


        IF NEW.effective_to IS NOT NULL
           AND NEW.effective_to <= NEW.effective_from
        THEN

            RAISE EXCEPTION
                'VERIFIED_PRICING_INVALID_EFFECTIVE_WINDOW';

        END IF;

    END IF;


    RETURN NEW;

END;

$function$
