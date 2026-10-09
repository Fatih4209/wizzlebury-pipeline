CREATE OR REPLACE FUNCTION public.prevent_overlapping_verified_model_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF NEW.is_verified IS NOT TRUE THEN
        RETURN NEW;
    END IF;


    IF EXISTS (

        SELECT 1

        FROM public.generation_model_pricing gmp

        WHERE gmp.model_id = NEW.model_id

          AND gmp.id <> NEW.id

          AND gmp.is_verified IS TRUE

          AND NEW.effective_from
                < COALESCE(
                    gmp.effective_to,
                    'infinity'::timestamptz
                )

          AND gmp.effective_from
                < COALESCE(
                    NEW.effective_to,
                    'infinity'::timestamptz
                )

    )
    THEN

        RAISE EXCEPTION
            'OVERLAPPING_VERIFIED_MODEL_PRICING';

    END IF;


    RETURN NEW;

END;

$function$
