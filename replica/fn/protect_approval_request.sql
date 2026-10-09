CREATE OR REPLACE FUNCTION public.protect_approval_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin

    if tg_op = 'DELETE' then
        raise exception 'APPROVAL_REQUESTS_CANNOT_BE_DELETED';
    end if;

    if old.status <> 'PENDING' then
        raise exception
            'APPROVAL_REQUEST_ALREADY_DECIDED: %',
            old.status;
    end if;

    if new.scope_type is distinct from old.scope_type
       or new.scope_id is distinct from old.scope_id
       or new.scope_version is distinct from old.scope_version
       or new.token_hash is distinct from old.token_hash
       or new.requested_by is distinct from old.requested_by
       or new.summary is distinct from old.summary
       or new.expires_at is distinct from old.expires_at
       or new.created_at is distinct from old.created_at
    then
        raise exception 'APPROVAL_REQUEST_IDENTITY_IMMUTABLE';
    end if;

    return new;

end;
$function$
