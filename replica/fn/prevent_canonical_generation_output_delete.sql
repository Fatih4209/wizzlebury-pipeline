CREATE OR REPLACE FUNCTION public.prevent_canonical_generation_output_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN

    IF OLD.is_canonical = true
       OR OLD.status = 'CANONICAL'
    THEN

        RAISE EXCEPTION
            'CANONICAL_GENERATION_OUTPUT_CANNOT_BE_DELETED';

    END IF;


    RETURN OLD;

END;
$function$
