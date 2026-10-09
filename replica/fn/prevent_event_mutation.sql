CREATE OR REPLACE FUNCTION public.prevent_event_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    raise exception 'EVENT_LOG_IS_APPEND_ONLY';
end;
$function$
