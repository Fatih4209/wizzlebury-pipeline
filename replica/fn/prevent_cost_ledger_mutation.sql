CREATE OR REPLACE FUNCTION public.prevent_cost_ledger_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    raise exception 'COST_LEDGER_IS_APPEND_ONLY';

end;
$function$
