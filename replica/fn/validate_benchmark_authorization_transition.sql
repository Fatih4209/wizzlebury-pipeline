CREATE OR REPLACE FUNCTION public.validate_benchmark_authorization_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

BEGIN

    IF TG_OP <> 'UPDATE'
       OR NEW.authorization_status =
          OLD.authorization_status
    THEN
        RETURN NEW;
    END IF;


    IF NOT (

        (
            OLD.authorization_status = 'PLANNED'
            AND NEW.authorization_status IN (
                'AUTHORIZED',
                'REVOKED'
            )
        )

        OR

        (
            OLD.authorization_status = 'AUTHORIZED'
            AND NEW.authorization_status IN (
                'CONSUMED',
                'REVOKED'
            )
        )

    )
    THEN

        RAISE EXCEPTION
            'INVALID_BENCHMARK_AUTHORIZATION_TRANSITION: % -> %',
            OLD.authorization_status,
            NEW.authorization_status;

    END IF;


    RETURN NEW;

END;

$function$
