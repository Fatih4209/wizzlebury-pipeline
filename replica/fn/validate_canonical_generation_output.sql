CREATE OR REPLACE FUNCTION public.validate_canonical_generation_output()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if new.is_canonical = true then

        if new.qc_status <> 'PASS' then
            raise exception
                'CANONICAL_OUTPUT_REQUIRES_QC_PASS';
        end if;

        if new.status not in (
            'AVAILABLE',
            'CANONICAL'
        ) then
            raise exception
                'CANONICAL_OUTPUT_NOT_AVAILABLE';
        end if;

        if new.reviewed_at is null then
            raise exception
                'CANONICAL_OUTPUT_REQUIRES_REVIEW';
        end if;

        -- Enforced when an output becomes canonical. Outputs made
        -- canonical before this rule keep working (their evidence
        -- fields are immutable, so they could not be repaired).
        if (
               tg_op = 'INSERT'
               or old.is_canonical is not true
           )
           and (
               new.storage_path is null
               or btrim(new.storage_path) = ''
           )
        then
            raise exception
                'CANONICAL_OUTPUT_REQUIRES_DURABLE_STORAGE';
        end if;

        if new.canonical_at is null then
            new.canonical_at := now();
        end if;

        new.status := 'CANONICAL';

    else

        -- Prevent stale canonical timestamp.
        new.canonical_at := null;

        -- If canonical flag is removed before final lock phase,
        -- return CANONICAL status to AVAILABLE.
        if new.status = 'CANONICAL' then
            new.status := 'AVAILABLE';
        end if;

    end if;

    return new;

end;
$function$
