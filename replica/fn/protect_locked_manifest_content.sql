CREATE OR REPLACE FUNCTION public.protect_locked_manifest_content()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_manifest_id uuid;
    v_status text;
BEGIN

    v_manifest_id :=
        CASE
            WHEN TG_OP = 'DELETE'
                THEN OLD.manifest_id
            ELSE NEW.manifest_id
        END;


    SELECT pm.status
    INTO v_status
    FROM public.production_manifests pm
    WHERE pm.id = v_manifest_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRODUCTION_MANIFEST_NOT_FOUND';
    END IF;


    IF v_status = 'LOCKED' THEN
        RAISE EXCEPTION
            'LOCKED_PRODUCTION_MANIFEST_CONTENT_IS_IMMUTABLE';
    END IF;


    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;


    RETURN NEW;

END;
$function$
