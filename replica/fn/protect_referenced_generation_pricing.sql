CREATE OR REPLACE FUNCTION public.protect_referenced_generation_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

DECLARE
    v_pricing_id uuid;
BEGIN

    IF TG_OP = 'DELETE' THEN
        v_pricing_id := OLD.id;
    ELSE
        v_pricing_id := OLD.id;
    END IF;


    IF EXISTS (

        SELECT 1

        FROM public.generation_routing_decisions grd

        WHERE grd.selected_pricing_id = v_pricing_id

          AND grd.decision_status <> 'PENDING'

    )
    THEN

        IF TG_OP = 'DELETE' THEN

            RAISE EXCEPTION
                'ROUTING_REFERENCED_PRICING_CANNOT_BE_DELETED';

        ELSE

            -- effective_to may still close the historical
            -- window, but all other fields must stay fixed.

            IF (
                to_jsonb(NEW)
                - 'effective_to'
                - 'updated_at'
            )
            IS DISTINCT FROM
            (
                to_jsonb(OLD)
                - 'effective_to'
                - 'updated_at'
            )
            THEN

                RAISE EXCEPTION
                    'ROUTING_REFERENCED_PRICING_IMMUTABLE';

            END IF;

        END IF;

    END IF;


    RETURN CASE
        WHEN TG_OP = 'DELETE'
            THEN OLD
        ELSE NEW
    END;

END;

$function$
