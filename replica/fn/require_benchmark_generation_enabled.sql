CREATE OR REPLACE FUNCTION public.require_benchmark_generation_enabled()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
    v_generation_enabled boolean;
    v_enters_paid_path boolean := false;
BEGIN

    -- -----------------------------------------------------
    -- Only guard entry into BUDGET_RESERVED.
    -- -----------------------------------------------------

    IF TG_OP = 'INSERT' THEN

        v_enters_paid_path :=
            NEW.status = 'BUDGET_RESERVED';

    ELSIF TG_OP = 'UPDATE' THEN

        v_enters_paid_path :=
            OLD.status IS DISTINCT FROM 'BUDGET_RESERVED'
            AND NEW.status = 'BUDGET_RESERVED';

    END IF;


    IF v_enters_paid_path IS NOT TRUE THEN
        RETURN NEW;
    END IF;


    -- -----------------------------------------------------
    -- GLOBAL M417 KILL SWITCH
    -- -----------------------------------------------------

    SELECT sf.value
    INTO v_generation_enabled
    FROM public.system_flags sf
    WHERE sf.key = 'generation_enabled'
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'GENERATION_FLAG_MISSING';
    END IF;


    IF v_generation_enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'GENERATION_DISABLED';
    END IF;


    RETURN NEW;

END;
$function$
