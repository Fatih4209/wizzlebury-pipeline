CREATE OR REPLACE FUNCTION public.add_m417_location_asset_plan(p_location_code text, p_asset_code text, p_asset_role text, p_view_type text, p_priority text, p_rules jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$

declare

    v_series_id uuid;
    v_location_id uuid;

begin

    select id
    into v_series_id
    from public.series
    where series_code = 'M417'
    limit 1;


    if v_series_id is null then
        raise exception 'M417 series not found';
    end if;


    select id
    into v_location_id
    from public.locations
    where series_id = v_series_id
      and location_code = p_location_code
    limit 1;


    if v_location_id is null then
        raise exception
        'Location not found: %',
        p_location_code;
    end if;


    insert into public.location_asset_plan (

        series_id,
        location_id,
        asset_code,
        asset_role,
        view_type,
        priority,
        production_rules,
        status

    )

    values (

        v_series_id,
        v_location_id,
        p_asset_code,
        p_asset_role,
        p_view_type,
        p_priority,
        p_rules,
        'PLANNED'

    )

    on conflict (
        series_id,
        location_id,
        asset_code
    )

    do update set

        asset_role = excluded.asset_role,
        view_type = excluded.view_type,
        priority = excluded.priority,
        production_rules = excluded.production_rules;

end;

$function$
