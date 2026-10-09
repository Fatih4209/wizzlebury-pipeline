CREATE OR REPLACE FUNCTION public.enforce_storyboard_review_integrity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_asset_status text;
BEGIN

    -- -----------------------------------------------------
    -- APPROVED storyboard must be complete.
    -- -----------------------------------------------------

    IF NEW.status = 'APPROVED' THEN

        IF NEW.storyboard_asset_id IS NULL THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_REQUIRES_ASSET';
        END IF;


        IF NEW.reviewed_at IS NULL THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_REQUIRES_REVIEW_TIMESTAMP';
        END IF;


        IF NEW.reviewer_type IS NULL
           OR btrim(NEW.reviewer_type) = ''
        THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_REQUIRES_REVIEWER';
        END IF;


        SELECT ar.status
        INTO v_asset_status

        FROM public.asset_registry ar

        WHERE ar.id = NEW.storyboard_asset_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'STORYBOARD_ASSET_NOT_FOUND';
        END IF;


        IF v_asset_status <> 'LOCKED' THEN
            RAISE EXCEPTION
                'APPROVED_STORYBOARD_ASSET_MUST_BE_LOCKED';
        END IF;

    END IF;


    RETURN NEW;

END;
$function$
