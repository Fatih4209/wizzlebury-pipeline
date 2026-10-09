CREATE OR REPLACE FUNCTION public.protect_benchmark_job_accounting_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if new.benchmark_run_id
            is distinct from old.benchmark_run_id
       or new.benchmark_case_id
            is distinct from old.benchmark_case_id
       or new.model_id
            is distinct from old.model_id
       or new.pricing_id
            is distinct from old.pricing_id
       or new.attempt_no
            is distinct from old.attempt_no
       or new.estimated_cost
            is distinct from old.estimated_cost
    then
        raise exception
            'BENCHMARK_JOB_AUTHORIZATION_FIELDS_IMMUTABLE';
    end if;


    -- An overrun is a fact reported by the provider. It may only be
    -- written by the settlement functions, which also stop generation.
    if new.actual_cost is not null
       and new.actual_cost > old.estimated_cost
       and coalesce(
               current_setting('m417.benchmark_overrun_settlement', true),
               'off'
           ) <> 'on'
    then
        raise exception
            'BENCHMARK_ACTUAL_COST_EXCEEDS_RESERVATION';
    end if;


    return new;

end;
$function$
