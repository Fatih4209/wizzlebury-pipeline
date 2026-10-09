CREATE OR REPLACE FUNCTION public.validate_shot_reference_asset()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE
    v_asset_status text;
BEGIN

    SELECT ar.status
    INTO v_asset_status

    FROM public.asset_registry ar

    WHERE ar.id = NEW.asset_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'REFERENCE_ASSET_NOT_FOUND';
    END IF;


    IF v_asset_status <> 'LOCKED' THEN
        RAISE EXCEPTION
            'REFERENCE_ASSET_MUST_BE_LOCKED: %',
            v_asset_status;
    END IF;


    RETURN NEW;

END;
$function$
