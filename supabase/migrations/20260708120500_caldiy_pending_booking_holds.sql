-- Keep pending bookings and confirmation holds blocking availability.
-- This re-applies the slot-blocking behavior on top of the live database,
-- because the earlier migration files are already recorded as applied.

begin;

create or replace function private.public_booking_available_user_ids(
  p_username text,
  p_event_slug text,
  p_start_time timestamptz,
  p_end_time timestamptz
)
returns bigint[]
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_context jsonb := private.resolve_public_booking_context(p_username, p_event_slug);
  v_event_type_id bigint := nullif(v_context->'event_type'->>'id', '')::bigint;
  v_candidate_user_ids bigint[] := private.public_booking_context_user_ids(p_username, p_event_slug);
  v_available_user_ids bigint[] := '{}'::bigint[];
  v_user record;
  v_local_start timestamp;
  v_local_end timestamp;
  v_has_availability boolean;
  v_has_booking_conflict boolean;
begin
  if v_context is null then
    return '{}'::bigint[];
  end if;

  if coalesce(array_length(v_candidate_user_ids, 1), 0) = 0 then
    return '{}'::bigint[];
  end if;

  for v_user in
    select u.id, coalesce(nullif(u.time_zone, ''), 'UTC') as time_zone
    from public.users u
    where u.id = any(v_candidate_user_ids)
    order by array_position(v_candidate_user_ids, u.id)
  loop
    v_local_start := p_start_time at time zone v_user.time_zone;
    v_local_end := p_end_time at time zone v_user.time_zone;

    select exists (
      select 1
      from public.availability a
      where a.user_id = v_user.id
        and (
          (v_event_type_id is null and a.event_type_id is null)
          or a.event_type_id = v_event_type_id
        )
        and (
          (a.date is not null and a.date = v_local_start::date)
          or (
            a.date is null
            and extract(dow from v_local_start)::int = any(a.days)
          )
        )
        and v_local_start::time >= a.start_time
        and v_local_end::time <= a.end_time
    )
    into v_has_availability;

    if not v_has_availability then
      continue;
    end if;

    select exists (
      select 1
      from public.bookings b
      where b.user_id = v_user.id
        and b.status in ('accepted', 'pending')
        and tstzrange(b.start_time, b.end_time, '[)') && tstzrange(p_start_time, p_end_time, '[)')
    )
    into v_has_booking_conflict;

    if v_has_booking_conflict then
      continue;
    end if;

    v_available_user_ids := array_append(v_available_user_ids, v_user.id);
  end loop;

  return coalesce(v_available_user_ids, '{}'::bigint[]);
end;
$$;

create or replace function public.get_public_booking_availability(
  p_username text,
  p_event_slug text,
  p_date_from timestamptz,
  p_date_to timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_context jsonb := private.resolve_public_booking_context(p_username, p_event_slug);
  v_event_type_id bigint := nullif(v_context->'event_type'->>'id', '')::bigint;
  v_dynamic_group_slug text := lower(p_username);
  v_availability jsonb := '[]'::jsonb;
  v_bookings jsonb := '[]'::jsonb;
begin
  if v_context is null then
    return null;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'user_id', a.user_id,
        'event_type_id', a.event_type_id,
        'date', a.date,
        'days', a.days,
        'start_time', a.start_time,
        'end_time', a.end_time,
        'buffer', a.buffer
      )
      order by a.id
    ),
    '[]'::jsonb
  )
  into v_availability
  from public.availability a
  where (
    v_event_type_id is not null
    and a.event_type_id = v_event_type_id
  )
    or (
      v_event_type_id is null
      and a.event_type_id is null
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', b.id,
        'uid', b.uid,
        'user_id', b.user_id,
        'event_type_id', b.event_type_id,
        'title', b.title,
        'description', b.description,
        'start_time', b.start_time,
        'end_time', b.end_time,
        'location', b.location,
        'status', b.status,
        'dynamic_event_slug_ref', b.dynamic_event_slug_ref,
        'dynamic_group_slug_ref', b.dynamic_group_slug_ref,
        'creation_source', b.creation_source
      )
      order by b.start_time
    ),
    '[]'::jsonb
  )
  into v_bookings
  from public.bookings b
  where (
    (v_event_type_id is not null and b.event_type_id = v_event_type_id)
    or (
      v_event_type_id is null
      and b.dynamic_event_slug_ref = p_event_slug
      and b.dynamic_group_slug_ref = v_dynamic_group_slug
    )
  )
    and b.status in ('accepted', 'pending')
    and tstzrange(b.start_time, b.end_time, '[)') && tstzrange(p_date_from, p_date_to, '[)');

  return jsonb_build_object(
    'page', v_context,
    'availability_rules', v_availability,
    'bookings', v_bookings
  );
end;
$$;

commit;
