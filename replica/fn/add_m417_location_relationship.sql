CREATE OR REPLACE FUNCTION public.add_m417_location_relationship(p_from_code text, p_to_code text, p_relationship_type text, p_minutes integer, p_travel_mode text, p_rules jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$

declare

    v_series_id uuid;
    v_from_id uuid;
    v_to_id uuid;

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
    into v_from_id
    from public.locations
    where series_id = v_series_id
      and location_code = p_from_code
    limit 1;


    select id
    into v_to_id
    from public.locations
    where series_id = v_series_id
      and location_code = p_to_code
    limit 1;


    if v_from_id is null then
        raise exception
        'FROM location not found: %',
        p_from_code;
    end if;


    if v_to_id is null then
        raise exception
        'TO location not found: %',
        p_to_code;
    end if;


    insert into public.location_relationships (
        series_id,
        from_location_id,
        to_location_id,
        relationship_type,
        approximate_travel_minutes,
        travel_mode,
        geography_rules
    )

    values (
        v_series_id,
        v_from_id,
        v_to_id,
        p_relationship_type,
        p_minutes,
        p_travel_mode,
        p_rules
    )

    on conflict (
        series_id,
        from_location_id,
        to_location_id,
        relationship_type
    )

    do update set

        approximate_travel_minutes =
            excluded.approximate_travel_minutes,

        travel_mode =
            excluded.travel_mode,

        geography_rules =
            excluded.geography_rules;

end;

$function$
