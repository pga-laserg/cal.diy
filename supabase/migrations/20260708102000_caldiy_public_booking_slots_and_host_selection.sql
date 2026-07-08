-- Public booking slot generation and host selection for the Cal.diy-shaped Supabase port.
-- This is the next layer after the basic booking write path:
-- - generate bookable slots from stored availability
-- - pick an actually available host for group-style pages
-- - keep booking creation aligned with the same availability check

begin;

create or replace function private.public_booking_context_user_ids(
  p_username text,
  p_event_slug text
)
returns bigint[]
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(
    array_agg((item->>'id')::bigint order by ord),
    '{}'::bigint[]
  )
  from jsonb_array_elements(
    case
      when jsonb_typeof(private.resolve_public_booking_context(p_username, p_event_slug)->'users') = 'array'
        and jsonb_array_length(coalesce(private.resolve_public_booking_context(p_username, p_event_slug)->'users', '[]'::jsonb)) > 0
        then private.resolve_public_booking_context(p_username, p_event_slug)->'users'
      when private.resolve_public_booking_context(p_username, p_event_slug)->'user' is not null
        then jsonb_build_array(private.resolve_public_booking_context(p_username, p_event_slug)->'user')
      else '[]'::jsonb
    end
  ) with ordinality as user_item(item, ord);
$$;

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

create or replace function public.get_public_booking_slots(
  p_username text,
  p_event_slug text,
  p_date_from timestamptz,
  p_date_to timestamptz,
  p_frequency_minutes integer default 15
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_context jsonb := private.resolve_public_booking_context(p_username, p_event_slug);
  v_event_length integer := greatest(coalesce(nullif(v_context->'event_type'->>'length', '')::integer, 30), 5);
  v_frequency integer := greatest(coalesce(p_frequency_minutes, 15), 5);
  v_slots jsonb;
begin
  if v_context is null then
    return null;
  end if;

  with candidate_slots as (
    select gs as slot_start
    from generate_series(
      p_date_from,
      p_date_to - make_interval(mins => v_event_length),
      make_interval(mins => v_frequency)
    ) as gs
  ),
  available_slots as (
    select
      to_char(slot_start at time zone 'UTC', 'YYYY-MM-DD') as slot_date,
      jsonb_build_object(
        'time', slot_start,
        'userIds', to_jsonb(private.public_booking_available_user_ids(p_username, p_event_slug, slot_start, slot_start + make_interval(mins => v_event_length)))
      ) as slot
    from candidate_slots
  ),
  filtered_slots as (
    select slot_date, slot
    from available_slots
    where coalesce(jsonb_array_length(slot->'userIds'), 0) > 0
  ),
  grouped_slots as (
    select slot_date, jsonb_agg(slot order by slot->>'time') as slots
    from filtered_slots
    group by slot_date
  )
  select coalesce(jsonb_object_agg(slot_date, slots), '{}'::jsonb)
  into v_slots
  from grouped_slots;

  return jsonb_build_object(
    'page', v_context,
    'slots', coalesce(v_slots, '{}'::jsonb)
  );
end;
$$;

create or replace function public.create_public_booking(
  p_username text,
  p_event_slug text,
  p_start_time timestamptz,
  p_end_time timestamptz,
  p_time_zone text,
  p_booker_name text,
  p_booker_email text,
  p_location text default null,
  p_notes text default null,
  p_guests jsonb default '[]'::jsonb,
  p_metadata jsonb default '{}'::jsonb,
  p_responses jsonb default '{}'::jsonb,
  p_creation_source public.creation_source default 'webapp'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth
as $$
declare
  v_context jsonb := private.resolve_public_booking_context(p_username, p_event_slug);
  v_available_user_ids bigint[] := private.public_booking_available_user_ids(
    p_username,
    p_event_slug,
    p_start_time,
    p_end_time
  );
  v_event_type_id bigint := nullif(v_context->'event_type'->>'id', '')::bigint;
  v_organizer_user_id bigint := nullif(v_context->>'organizer_user_id', '')::bigint;
  v_booking_uid text := replace(gen_random_uuid()::text, '-', '');
  v_i_cal_uid text := replace(gen_random_uuid()::text, '-', '');
  v_actor_id uuid;
  v_booking public.bookings%rowtype;
  v_available_user_count integer := coalesce(array_length(v_available_user_ids, 1), 0);
  v_dynamic_group_slug text := lower(p_username);
  v_attendee_rows integer := 0;
begin
  if v_context is null then
    raise exception 'public_booking_context_not_found';
  end if;

  if p_end_time <= p_start_time then
    raise exception 'invalid_booking_window';
  end if;

  if v_available_user_count = 0 then
    raise exception 'public_booking_conflict';
  end if;

  v_organizer_user_id := v_available_user_ids[1];

  perform pg_advisory_xact_lock(hashtext(
    coalesce(v_event_type_id::text, v_dynamic_group_slug || ':' || p_event_slug)
  ));

  insert into public.audit_actors (
    type,
    email,
    name
  )
  values (
    'guest',
    p_booker_email,
    p_booker_name
  )
  on conflict (email) do update
  set name = coalesce(excluded.name, public.audit_actors.name)
  returning id into v_actor_id;

  insert into public.bookings (
    uid,
    user_id,
    user_primary_email,
    event_type_id,
    title,
    description,
    responses,
    start_time,
    end_time,
    location,
    status,
    metadata,
    i_cal_uid,
    creation_source,
    dynamic_event_slug_ref,
    dynamic_group_slug_ref
  )
  values (
    v_booking_uid,
    v_organizer_user_id,
    p_booker_email,
    v_event_type_id,
    coalesce(v_context->'event_type'->>'title', initcap(replace(p_event_slug, '-', ' '))),
    p_notes,
    case
      when p_responses = '{}'::jsonb then null
      else p_responses
    end,
    p_start_time,
    p_end_time,
    p_location,
    'accepted',
    p_metadata,
    v_i_cal_uid,
    p_creation_source,
    case when v_event_type_id is null then p_event_slug else null end,
    case when v_event_type_id is null then v_dynamic_group_slug else null end
  )
  returning * into v_booking;

  insert into public.attendees (
    email,
    name,
    time_zone,
    phone_number,
    locale,
    booking_id
  )
  select distinct on (attendee_email)
    attendee_email,
    attendee_name,
    attendee_time_zone,
    attendee_phone_number,
    attendee_locale,
    v_booking.id
  from (
    select
      0 as ord,
      p_booker_email as attendee_email,
      p_booker_name as attendee_name,
      p_time_zone as attendee_time_zone,
      null::text as attendee_phone_number,
      'en'::text as attendee_locale
    union all
    select
      guest_item.ordinality as ord,
      coalesce(nullif(guest_item.value->>'email', ''), p_booker_email) as attendee_email,
      coalesce(nullif(guest_item.value->>'name', ''), p_booker_name) as attendee_name,
      coalesce(nullif(guest_item.value->>'time_zone', ''), p_time_zone) as attendee_time_zone,
      nullif(guest_item.value->>'phone_number', '') as attendee_phone_number,
      coalesce(nullif(guest_item.value->>'locale', ''), 'en') as attendee_locale
    from jsonb_array_elements(coalesce(p_guests, '[]'::jsonb)) with ordinality as guest_item(value, ordinality)
  ) attendee_rows
  order by attendee_email, ord;

  get diagnostics v_attendee_rows = row_count;

  insert into public.booking_audits (
    booking_uid,
    actor_id,
    type,
    action,
    timestamp,
    source,
    operation_id,
    data,
    context
  )
  values (
    v_booking.uid,
    v_actor_id,
    'record_created',
    'created'::public.booking_audit_action,
    now(),
    'webapp',
    replace(gen_random_uuid()::text, '-', ''),
    jsonb_build_object(
      'attendee_count', greatest(v_attendee_rows, 1),
      'event_type_id', v_event_type_id,
      'organizer_user_id', v_organizer_user_id,
      'available_user_ids', to_jsonb(v_available_user_ids)
    ),
    jsonb_build_object(
      'username', p_username,
      'event_slug', p_event_slug,
      'time_zone', p_time_zone
    )
  );

  return jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'attendee_count', greatest(v_attendee_rows, 1),
    'page', v_context,
    'selected_user_id', v_organizer_user_id,
    'available_user_ids', to_jsonb(v_available_user_ids)
  );
end;
$$;

grant execute on function private.public_booking_context_user_ids(text, text) to anon, authenticated;
grant execute on function private.public_booking_available_user_ids(text, text, timestamptz, timestamptz) to anon, authenticated;
grant execute on function public.get_public_booking_slots(text, text, timestamptz, timestamptz, integer) to anon, authenticated;
grant execute on function public.create_public_booking(
  text,
  text,
  timestamptz,
  timestamptz,
  text,
  text,
  text,
  text,
  text,
  jsonb,
  jsonb,
  jsonb,
  public.creation_source
) to anon, authenticated;

commit;
