CREATE OR REPLACE FUNCTION public.protect_benchmark_run_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
    v_internal_accounting boolean;
begin

    v_internal_accounting :=
        coalesce(
            current_setting(
                'm417.benchmark_accounting',
                true
            ),
            'off'
        ) = 'on';


    -- APPROVED/RUNNING CONFIGURATION IS IMMUTABLE
    if old.status in (
        'HUMAN_APPROVED',
        'RUNNING',
        'BLOCKED',
        'COMPLETED'
    )
    then

        if new.run_code
                is distinct from old.run_code
           or new.benchmark_name
                is distinct from old.benchmark_name
           or new.hard_budget_usd
                is distinct from old.hard_budget_usd
           or new.max_generation_count
                is distinct from old.max_generation_count
           or new.human_approved
                is distinct from old.human_approved
           or new.approved_at
                is distinct from old.approved_at
        then
            raise exception
                'APPROVED_BENCHMARK_RUN_CONFIGURATION_IMMUTABLE';
        end if;

    end if;


    -- ACCOUNTING COUNTERS
    if (
        new.reserved_usd
            is distinct from old.reserved_usd
        or new.settled_usd
            is distinct from old.settled_usd
        or new.generation_count
            is distinct from old.generation_count
    )
    and v_internal_accounting is not true
    then
        raise exception
            'BENCHMARK_RUN_ACCOUNTING_FIELDS_PROTECTED';
    end if;


    -- HARD BUDGET (replaces generation_benchmark_runs_spend_check):
    -- no new money may be reserved past the cap. Settling an overrun
    -- is allowed to exceed it, because the money is already spent.
    if new.reserved_usd > old.reserved_usd
       and (new.reserved_usd + new.settled_usd) > new.hard_budget_usd
    then
        raise exception
            'BENCHMARK_HARD_BUDGET_EXCEEDED';
    end if;


    return new;

end;
$function$
