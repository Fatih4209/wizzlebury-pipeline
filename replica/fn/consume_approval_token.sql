CREATE OR REPLACE FUNCTION public.consume_approval_token(p_token text, p_expected_scope_type text, p_decision text, p_decided_by text, p_channel text, p_note text)
 RETURNS approval_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_row public.approval_requests;
begin

    if p_token is null or btrim(p_token) = '' then
        raise exception 'APPROVAL_TOKEN_REQUIRED';
    end if;

    if p_decision not in ('APPROVED', 'REJECTED') then
        raise exception 'INVALID_APPROVAL_DECISION';
    end if;

    if p_decided_by is null or btrim(p_decided_by) = '' then
        raise exception 'APPROVAL_DECIDER_REQUIRED';
    end if;


    select ar.*
    into v_row
    from public.approval_requests ar
    where ar.token_hash =
          encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
    for update;

    if not found then
        raise exception 'APPROVAL_TOKEN_INVALID';
    end if;

    if p_expected_scope_type is not null
       and v_row.scope_type <> p_expected_scope_type
    then
        raise exception
            'APPROVAL_TOKEN_SCOPE_MISMATCH: %',
            v_row.scope_type;
    end if;

    if v_row.status <> 'PENDING' then
        raise exception
            'APPROVAL_TOKEN_ALREADY_USED: %',
            v_row.status;
    end if;

    if v_row.expires_at <= now() then
        raise exception 'APPROVAL_TOKEN_EXPIRED';
    end if;


    update public.approval_requests ar
    set
        status = p_decision,
        decided_at = now(),
        decided_by = p_decided_by,
        decision_channel = p_channel,
        decision_note = p_note
    where ar.id = v_row.id
    returning ar.*
    into v_row;

    return v_row;

end;
$function$
