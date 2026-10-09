CREATE OR REPLACE FUNCTION public.validate_storyboard_asset()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE
    v_asset_status text;
BEGIN

    IF NEW.storyboard_asset_id IS NULL THEN
        RETURN NEW;
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
            'STORYBOARD_ASSET_MUST_BE_LOCKED: %',
            v_asset_status;
    END IF;


    RETURN NEW;

END;
$function$
