-- Booking schedule rules for the Cal.diy-shaped Supabase port.
-- This pass closes the gaps between the app's scheduling behavior and the
-- current Supabase booking RPCs:
-- - model the missing event-type scheduling fields
-- - enforce minimum booking and reschedule notice
-- - respect before/after buffers when checking conflicts
-- - stop pending bookings from blocking slots unless the event type says so
-- - honor slot intervals and first-available-slot behavior in slot generation

begin;

alter table public.event_types
  add column if not exists minimum_booking_notice integer not null default 120,
  add column if not exists show_optimized_slots boolean not null default false,
  add column if not exists slot_interval integer,
  add column if not exists disable_cancelling boolean not null default false,
  add column if not exists disable_rescheduling boolean not null default false;

create or replace function private.public_booking_event_settings(
  p_username text,
  p_event_slug text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_context jsonb := private.resolve_public_booking_context(p_username, p_event_slug);
  v_event jsonb := coalesce(v_context->'event_type', '{}'::jsonb);
  v_event_type_id bigint := nullif(v_event->>'id', '')::bigint;
  v_event_record record;
begin
  if v_context is null then
    return null;
  end if;

  if v_event_type_id is null then
    return jsonb_build_object(
      'id', null,
      'length', coalesce(nullif(v_event->>'length', '')::integer, 30),
      'offset_start', coalesce(nullif(v_event->>'offset_start', '')::integer, 0),
      'minimum_booking_notice', 120,
      'minimum_reschedule_notice', null,
      'before_event_buffer', 0,
      'after_event_buffer', 0,
      'slot_interval', coalesce(nullif(v_event->>'length', '')::integer, 30),
      'show_optimized_slots', false,
      'only_show_first_available_slot', false,
      'requires_confirmation', false,
      'requires_confirmation_for_free_email', false,
      'requires_confirmation_will_block_slot', false,
      'requires_booker_email_verification', false,
      'allow_rescheduling_cancelled_bookings', false,
      'disable_cancelling', false,
      'disable_rescheduling', false
    );
  end if;

  select
    e.id,
    e.length,
    e.offset_start,
    e.minimum_booking_notice,
    e.minimum_reschedule_notice,
    e.before_event_buffer,
    e.after_event_buffer,
    e.slot_interval,
    e.show_optimized_slots,
    e.only_show_first_available_slot,
    e.requires_confirmation,
    e.requires_confirmation_for_free_email,
    e.requires_confirmation_will_block_slot,
    e.requires_booker_email_verification,
    e.allow_rescheduling_cancelled_bookings,
    e.disable_cancelling,
    e.disable_rescheduling
  into v_event_record
  from public.event_types e
  where e.id = v_event_type_id
  limit 1;

  if v_event_record.id is null then
    return jsonb_build_object(
      'id', null,
      'length', coalesce(nullif(v_event->>'length', '')::integer, 30),
      'offset_start', coalesce(nullif(v_event->>'offset_start', '')::integer, 0),
      'minimum_booking_notice', 120,
      'minimum_reschedule_notice', null,
      'before_event_buffer', 0,
      'after_event_buffer', 0,
      'slot_interval', coalesce(nullif(v_event->>'length', '')::integer, 30),
      'show_optimized_slots', false,
      'only_show_first_available_slot', false,
      'requires_confirmation', false,
      'requires_confirmation_for_free_email', false,
      'requires_confirmation_will_block_slot', false,
      'requires_booker_email_verification', false,
      'allow_rescheduling_cancelled_bookings', false,
      'disable_cancelling', false,
      'disable_rescheduling', false
    );
  end if;

  return jsonb_build_object(
    'id', v_event_record.id,
    'length', coalesce(v_event_record.length, 30),
    'offset_start', coalesce(v_event_record.offset_start, 0),
    'minimum_booking_notice', coalesce(v_event_record.minimum_booking_notice, 120),
    'minimum_reschedule_notice', v_event_record.minimum_reschedule_notice,
    'before_event_buffer', coalesce(v_event_record.before_event_buffer, 0),
    'after_event_buffer', coalesce(v_event_record.after_event_buffer, 0),
    'slot_interval', coalesce(v_event_record.slot_interval, v_event_record.length, 30),
    'show_optimized_slots', coalesce(v_event_record.show_optimized_slots, false),
    'only_show_first_available_slot', coalesce(v_event_record.only_show_first_available_slot, false),
    'requires_confirmation', coalesce(v_event_record.requires_confirmation, false),
    'requires_confirmation_for_free_email', coalesce(v_event_record.requires_confirmation_for_free_email, false),
    'requires_confirmation_will_block_slot', coalesce(v_event_record.requires_confirmation_will_block_slot, false),
    'requires_booker_email_verification', coalesce(v_event_record.requires_booker_email_verification, false),
    'allow_rescheduling_cancelled_bookings', coalesce(v_event_record.allow_rescheduling_cancelled_bookings, false),
    'disable_cancelling', coalesce(v_event_record.disable_cancelling, false),
    'disable_rescheduling', coalesce(v_event_record.disable_rescheduling, false)
  );
end;
$$;

create or replace function private.public_booking_event_timezone(
  p_username text,
  p_event_slug text
)
returns text
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(
    nullif(private.resolve_public_booking_context(p_username, p_event_slug)->'team'->>'time_zone', ''),
    nullif(private.resolve_public_booking_context(p_username, p_event_slug)->'user'->>'time_zone', ''),
    'UTC'
  )
$$;

create or replace function private.public_booking_limit_conflict(
  p_user_id bigint,
  p_event_type_id bigint,
  p_time_zone text,
  p_start_time timestamptz,
  p_end_time timestamptz,
  p_excluded_booking_uid text default null
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_event record;
  v_selected_duration integer := greatest(round(extract(epoch from (p_end_time - p_start_time)) / 60.0)::integer, 1);
  v_local_start timestamp := p_start_time at time zone p_time_zone;
  v_period_start timestamp;
  v_limit_unit text;
  v_limit_key text;
  v_limit_value integer;
  v_booking_count integer;
  v_total_duration integer;
begin
  if p_event_type_id is null then
    return false;
  end if;

  select booking_limits, duration_limits
  into v_event
  from public.event_types e
  where e.id = p_event_type_id
  limit 1;

  if v_event is null then
    return false;
  end if;

  for v_limit_key, v_limit_value in
    select key, nullif(value, '')::integer
    from jsonb_each_text(coalesce(v_event.booking_limits, '{}'::jsonb))
  loop
    if v_limit_value is null then
      continue;
    end if;

    v_limit_unit := case v_limit_key
      when 'PER_DAY' then 'day'
      when 'PER_WEEK' then 'week'
      when 'PER_MONTH' then 'month'
      when 'PER_YEAR' then 'year'
      else null
    end;

    v_period_start := case v_limit_key
      when 'PER_DAY' then date_trunc('day', v_local_start)
      when 'PER_WEEK' then date_trunc('week', v_local_start)
      when 'PER_MONTH' then date_trunc('month', v_local_start)
      when 'PER_YEAR' then date_trunc('year', v_local_start)
      else null
    end;

    if v_period_start is null then
      continue;
    end if;

    select count(*)
    into v_booking_count
    from public.bookings b
    where b.user_id = p_user_id
      and b.event_type_id = p_event_type_id
      and b.status in ('accepted', 'pending')
      and (p_excluded_booking_uid is null or b.uid <> p_excluded_booking_uid)
      and date_trunc(v_limit_unit, b.start_time at time zone p_time_zone) = v_period_start;

    if v_booking_count >= v_limit_value then
      return true;
    end if;
  end loop;

  for v_limit_key, v_limit_value in
    select key, nullif(value, '')::integer
    from jsonb_each_text(coalesce(v_event.duration_limits, '{}'::jsonb))
  loop
    if v_limit_value is null then
      continue;
    end if;

    v_period_start := case v_limit_key
      when 'PER_DAY' then date_trunc('day', v_local_start)
      when 'PER_WEEK' then date_trunc('week', v_local_start)
      when 'PER_MONTH' then date_trunc('month', v_local_start)
      when 'PER_YEAR' then date_trunc('year', v_local_start)
      else null
    end;

    if v_period_start is null then
      continue;
    end if;

    select coalesce(sum(greatest(round(extract(epoch from (b.end_time - b.start_time)) / 60.0)::integer, 1)), 0)
    into v_total_duration
    from public.bookings b
    where b.user_id = p_user_id
      and b.event_type_id = p_event_type_id
      and b.status in ('accepted', 'pending')
      and (p_excluded_booking_uid is null or b.uid <> p_excluded_booking_uid)
      and date_trunc(v_limit_unit, b.start_time at time zone p_time_zone) = v_period_start;

    if v_total_duration + v_selected_duration > v_limit_value then
      return true;
    end if;
  end loop;

  return false;
end;
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
  v_settings jsonb := private.public_booking_event_settings(p_username, p_event_slug);
  v_time_zone text := private.public_booking_event_timezone(p_username, p_event_slug);
  v_event_type_id bigint := nullif(v_context->'event_type'->>'id', '')::bigint;
  v_candidate_user_ids bigint[] := private.public_booking_context_user_ids(p_username, p_event_slug);
  v_available_user_ids bigint[] := '{}'::bigint[];
  v_user record;
  v_local_start timestamp;
  v_local_end timestamp;
  v_has_availability boolean;
  v_has_booking_conflict boolean;
  v_minimum_booking_notice integer := coalesce(nullif(v_settings->>'minimum_booking_notice', '')::integer, 120);
  v_before_buffer integer := coalesce(nullif(v_settings->>'before_event_buffer', '')::integer, 0);
  v_after_buffer integer := coalesce(nullif(v_settings->>'after_event_buffer', '')::integer, 0);
  v_booking_start timestamptz := p_start_time - make_interval(mins => v_before_buffer);
  v_booking_end timestamptz := p_end_time + make_interval(mins => v_after_buffer);
begin
  if v_context is null then
    return '{}'::bigint[];
  end if;

  if p_start_time < now() + make_interval(mins => v_minimum_booking_notice) then
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
      left join public.event_types existing_event_type on existing_event_type.id = b.event_type_id
      where b.user_id = v_user.id
        and (
          b.status = 'accepted'
          or (
            b.status = 'pending'
            and coalesce(existing_event_type.requires_confirmation_will_block_slot, false)
          )
        )
        and tstzrange(
          b.start_time - make_interval(mins => coalesce(existing_event_type.before_event_buffer, 0)),
          b.end_time + make_interval(mins => coalesce(existing_event_type.after_event_buffer, 0)),
          '[)'
        ) && tstzrange(v_booking_start, v_booking_end, '[)')
    )
    into v_has_booking_conflict;

    if v_has_booking_conflict then
      continue;
    end if;

    if private.public_booking_limit_conflict(
      v_user.id,
      v_event_type_id,
      v_time_zone,
      p_start_time,
      p_end_time
    ) then
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
  v_settings jsonb := private.public_booking_event_settings(p_username, p_event_slug);
  v_event_length integer := greatest(coalesce(nullif(v_settings->>'length', '')::integer, 30), 5);
  v_frequency integer := greatest(
    coalesce(nullif(v_settings->>'slot_interval', '')::integer, p_frequency_minutes, v_event_length),
    5
  );
  v_minimum_booking_notice integer := coalesce(nullif(v_settings->>'minimum_booking_notice', '')::integer, 120);
  v_show_optimized_slots boolean := coalesce((v_settings->>'show_optimized_slots')::boolean, false);
  v_only_show_first_available_slot boolean := coalesce((v_settings->>'only_show_first_available_slot')::boolean, false);
  v_window_start timestamptz := greatest(p_date_from, now() + make_interval(mins => v_minimum_booking_notice));
  v_series_start timestamptz;
  v_slots jsonb;
begin
  if v_context is null then
    return null;
  end if;

  if v_only_show_first_available_slot or v_show_optimized_slots then
    v_series_start := v_window_start;
  else
    v_series_start := date_trunc('hour', v_window_start)
      + make_interval(mins => ceil(extract(minute from v_window_start)::numeric / v_frequency) * v_frequency);

    if v_series_start < v_window_start then
      v_series_start := v_series_start + make_interval(mins => v_frequency);
    end if;
  end if;

  with candidate_slots as (
    select gs as slot_start
    from generate_series(
      v_series_start,
      p_date_to - make_interval(mins => v_event_length),
      make_interval(mins => v_frequency)
    ) as gs
  ),
  available_slots as (
    select
      slot_start,
      to_char(slot_start at time zone 'UTC', 'YYYY-MM-DD') as slot_date,
      jsonb_build_object(
        'time', slot_start,
        'userIds', to_jsonb(private.public_booking_available_user_ids(
          p_username,
          p_event_slug,
          slot_start,
          slot_start + make_interval(mins => v_event_length)
        ))
      ) as slot
    from candidate_slots
  ),
  filtered_slots as (
    select slot_start, slot_date, slot
    from available_slots
    where coalesce(jsonb_array_length(slot->'userIds'), 0) > 0
  ),
  first_slots_per_day as (
    select
      slot_date,
      slot,
      row_number() over (partition by slot_date order by slot_start) as rn
    from filtered_slots
  ),
  grouped_slots as (
    select slot_date, jsonb_agg(slot order by slot->>'time') as slots
    from (
      select slot_date, slot
      from first_slots_per_day
      where not v_only_show_first_available_slot or rn = 1
    ) kept_slots
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
  v_settings jsonb := private.public_booking_event_settings(p_username, p_event_slug);
  v_event_type_id bigint := nullif(v_context->'event_type'->>'id', '')::bigint;
  v_time_zone text := private.public_booking_event_timezone(p_username, p_event_slug);
  v_available_user_ids bigint[] := '{}'::bigint[];
  v_booking_uid text := replace(gen_random_uuid()::text, '-', '');
  v_i_cal_uid text := replace(gen_random_uuid()::text, '-', '');
  v_actor_id uuid;
  v_booking public.bookings%rowtype;
  v_available_user_count integer := coalesce(array_length(v_available_user_ids, 1), 0);
  v_dynamic_group_slug text := lower(p_username);
  v_attendee_rows integer := 0;
  v_booking_status public.booking_status := 'accepted';
  v_requires_confirmation boolean := coalesce((v_settings->>'requires_confirmation')::boolean, false);
  v_requires_booker_email_verification boolean := coalesce(
    (v_settings->>'requires_booker_email_verification')::boolean,
    false
  );
  v_minimum_booking_notice integer := coalesce(nullif(v_settings->>'minimum_booking_notice', '')::integer, 120);
begin
  if v_context is null then
    raise exception 'public_booking_context_not_found';
  end if;

  if p_end_time <= p_start_time then
    raise exception 'invalid_booking_window';
  end if;

  if p_start_time < now() + make_interval(mins => v_minimum_booking_notice) then
    raise exception 'minimum_booking_notice_not_met';
  end if;

  perform pg_advisory_xact_lock(hashtext(
    coalesce(v_event_type_id::text, v_dynamic_group_slug || ':' || p_event_slug)
  ));

  v_available_user_ids := private.public_booking_available_user_ids(
    p_username,
    p_event_slug,
    p_start_time,
    p_end_time
  );
  v_available_user_count := coalesce(array_length(v_available_user_ids, 1), 0);

  if v_available_user_count = 0 then
    raise exception 'public_booking_conflict';
  end if;

  if private.public_booking_limit_conflict(
    v_available_user_ids[1],
    v_event_type_id,
    v_time_zone,
    p_start_time,
    p_end_time
  ) then
    raise exception 'public_booking_limit_conflict';
  end if;

  if v_requires_confirmation or v_requires_booker_email_verification then
    v_booking_status := 'pending';
  end if;

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
    v_available_user_ids[1],
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
    v_booking_status,
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
    case when v_booking_status = 'pending' then 'pending' else 'created' end::public.booking_audit_action,
    now(),
    'webapp',
    replace(gen_random_uuid()::text, '-', ''),
    jsonb_build_object(
      'attendee_count', greatest(v_attendee_rows, 1),
      'event_type_id', v_event_type_id,
      'selected_user_id', v_available_user_ids[1]
    ),
    jsonb_build_object(
      'username', p_username,
      'event_slug', p_event_slug,
      'time_zone', p_time_zone,
      'status', v_booking_status
    )
  );

  return jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'attendee_count', greatest(v_attendee_rows, 1),
    'page', v_context,
    'selected_user_id', v_available_user_ids[1],
    'available_user_ids', to_jsonb(v_available_user_ids)
  );
end;
$$;

create or replace function public.update_booking_no_show_status(
  p_booking_uid text,
  p_attendees jsonb default '[]'::jsonb,
  p_no_show_host boolean default null,
  p_actor_email text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth
as $$
declare
  v_booking public.bookings%rowtype;
  v_actor_id uuid;
  v_host_old_no_show boolean;
  v_host_user_uuid uuid;
  v_attendee_changes jsonb := '[]'::jsonb;
  v_host_change jsonb := null;
  v_data jsonb;
begin
  select *
  into v_booking
  from public.bookings b
  where b.uid = p_booking_uid
  limit 1;

  if v_booking.id is null then
    raise exception 'booking_not_found';
  end if;

  if p_no_show_host is null and coalesce(jsonb_array_length(p_attendees), 0) = 0 then
    raise exception 'no_show_update_payload_required';
  end if;

  select u.uuid
  into v_host_user_uuid
  from public.users u
  where u.id = v_booking.user_id
  limit 1;

  insert into public.audit_actors (
    type,
    email,
    name
  )
  values (
    'guest',
    coalesce(p_actor_email, v_booking.user_primary_email, ''),
    p_actor_email
  )
  on conflict (email) do update
  set name = coalesce(excluded.name, public.audit_actors.name)
  returning id into v_actor_id;

  if p_no_show_host is not null then
    v_host_old_no_show := v_booking.no_show_host;

    update public.bookings
    set no_show_host = p_no_show_host,
        updated_at = now()
    where uid = p_booking_uid;

    v_host_change := jsonb_build_object(
      'userUuid', v_host_user_uuid,
      'noShow', jsonb_build_object(
        'old', v_host_old_no_show,
        'new', p_no_show_host
      )
    );
  end if;

  if coalesce(jsonb_array_length(p_attendees), 0) > 0 then
    with input_attendees as (
      select distinct on (lower(email))
        lower(email) as email,
        no_show
      from jsonb_to_recordset(p_attendees) as attendee(email text, no_show boolean)
    ),
    current_attendees as (
      select
        a.id,
        a.email,
        a.no_show as old_no_show,
        i.no_show as new_no_show
      from public.attendees a
      join input_attendees i
        on lower(a.email) = i.email
      where a.booking_id = v_booking.id
    ),
    updated_attendees as (
      update public.attendees a
      set no_show = c.new_no_show
      from current_attendees c
      where a.id = c.id
      returning c.email, c.old_no_show, c.new_no_show
    )
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'attendeeEmail', email,
          'noShow', jsonb_build_object('old', old_no_show, 'new', new_no_show)
        )
        order by email
      ),
      '[]'::jsonb
    )
    into v_attendee_changes
    from updated_attendees;
  end if;

  v_data := jsonb_build_object(
    'version', 1,
    'fields', jsonb_strip_nulls(
      jsonb_build_object(
        'host', v_host_change,
        'attendeesNoShow', case when coalesce(jsonb_array_length(v_attendee_changes), 0) > 0 then v_attendee_changes else null end
      )
    )
  );

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
    'record_updated',
    'no_show_updated'::public.booking_audit_action,
    now(),
    'webapp',
    replace(gen_random_uuid()::text, '-', ''),
    v_data,
    jsonb_build_object(
      'actor_email', p_actor_email
    )
  );

  return jsonb_build_object(
    'booking', jsonb_build_object(
      'uid', v_booking.uid,
      'no_show_host', coalesce(p_no_show_host, v_booking.no_show_host)
    ),
    'data', v_data
  );
end;
$$;

create or replace function public.request_booking_reschedule(
  p_booking_uid text,
  p_reason text default null,
  p_actor_email text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth
as $$
declare
  v_booking public.bookings%rowtype;
  v_event_settings jsonb := '{}'::jsonb;
  v_actor_id uuid;
  v_effect_payload jsonb;
  v_minimum_reschedule_notice integer := 0;
  v_allow_rescheduling_cancelled_bookings boolean := false;
  v_disable_rescheduling boolean := false;
begin
  select *
  into v_booking
  from public.bookings b
  where b.uid = p_booking_uid
  limit 1;

  if v_booking.id is null then
    raise exception 'booking_not_found';
  end if;

  if v_booking.event_type_id is not null then
    select
      jsonb_build_object(
        'minimum_reschedule_notice', coalesce(e.minimum_reschedule_notice, 0),
        'allow_rescheduling_cancelled_bookings', coalesce(e.allow_rescheduling_cancelled_bookings, false),
        'disable_rescheduling', coalesce(e.disable_rescheduling, false)
      )
    into v_event_settings
    from public.event_types e
    where e.id = v_booking.event_type_id
    limit 1;
  end if;

  v_minimum_reschedule_notice := coalesce(nullif(v_event_settings->>'minimum_reschedule_notice', '')::integer, 0);
  v_allow_rescheduling_cancelled_bookings := coalesce(
    (v_event_settings->>'allow_rescheduling_cancelled_bookings')::boolean,
    false
  );
  v_disable_rescheduling := coalesce((v_event_settings->>'disable_rescheduling')::boolean, false);

  if v_disable_rescheduling then
    raise exception 'rescheduling_disabled_for_event_type';
  end if;

  if v_booking.status = 'cancelled' and not v_allow_rescheduling_cancelled_bookings then
    raise exception 'reschedule_from_cancelled_booking_not_allowed';
  end if;

  if v_minimum_reschedule_notice > 0
    and v_booking.start_time <= now() + make_interval(mins => v_minimum_reschedule_notice) then
    raise exception 'minimum_reschedule_notice_not_met';
  end if;

  insert into public.audit_actors (
    type,
    email,
    name
  )
  values (
    'guest',
    coalesce(p_actor_email, v_booking.user_primary_email, ''),
    p_actor_email
  )
  on conflict (email) do update
  set name = coalesce(excluded.name, public.audit_actors.name)
  returning id into v_actor_id;

  update public.bookings
  set status = 'cancelled',
      rescheduled = true,
      cancellation_reason = coalesce(p_reason, cancellation_reason),
      rescheduled_by = coalesce(p_actor_email, rescheduled_by),
      updated_at = now()
  where uid = p_booking_uid
  returning * into v_booking;

  v_effect_payload := jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'reschedule_reason', p_reason,
    'actor_email', p_actor_email
  );

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
    'record_updated',
    'reschedule_requested'::public.booking_audit_action,
    now(),
    'webapp',
    replace(gen_random_uuid()::text, '-', ''),
    jsonb_build_object(
      'reschedule_reason', p_reason,
      'rescheduled', true
    ),
    jsonb_build_object(
      'actor_email', p_actor_email
    )
  );

  return jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'effects', v_effect_payload
  );
end;
$$;

create or replace function public.request_booking_cancel(
  p_booking_uid text,
  p_reason text default null,
  p_actor_email text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth
as $$
declare
  v_booking public.bookings%rowtype;
  v_event_settings jsonb := '{}'::jsonb;
  v_actor_id uuid;
  v_effect_payload jsonb;
  v_disable_cancelling boolean := false;
begin
  select *
  into v_booking
  from public.bookings b
  where b.uid = p_booking_uid
  limit 1;

  if v_booking.id is null then
    raise exception 'booking_not_found';
  end if;

  if v_booking.event_type_id is not null then
    select
      jsonb_build_object(
        'disable_cancelling', coalesce(e.disable_cancelling, false)
      )
    into v_event_settings
    from public.event_types e
    where e.id = v_booking.event_type_id
    limit 1;
  end if;

  v_disable_cancelling := coalesce((v_event_settings->>'disable_cancelling')::boolean, false);

  if v_disable_cancelling then
    raise exception 'cancelling_disabled_for_event_type';
  end if;

  insert into public.audit_actors (
    type,
    email,
    name
  )
  values (
    'guest',
    coalesce(p_actor_email, v_booking.user_primary_email, ''),
    p_actor_email
  )
  on conflict (email) do update
  set name = coalesce(excluded.name, public.audit_actors.name)
  returning id into v_actor_id;

  update public.bookings
  set status = 'cancelled',
      cancellation_reason = coalesce(p_reason, cancellation_reason),
      cancelled_by = coalesce(p_actor_email, cancelled_by),
      updated_at = now()
  where uid = p_booking_uid
  returning * into v_booking;

  v_effect_payload := jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'cancellation_reason', p_reason,
    'actor_email', p_actor_email
  );

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
    'record_updated',
    'cancelled'::public.booking_audit_action,
    now(),
    'webapp',
    replace(gen_random_uuid()::text, '-', ''),
    jsonb_build_object(
      'cancellation_reason', p_reason,
      'cancelled', true
    ),
    jsonb_build_object(
      'actor_email', p_actor_email
    )
  );

  return jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'effects', v_effect_payload
  );
end;
$$;

grant execute on function private.public_booking_event_settings(text, text) to anon, authenticated;
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
grant execute on function public.request_booking_cancel(text, text, text) to anon, authenticated;
grant execute on function public.request_booking_reschedule(text, text, text) to anon, authenticated;
grant execute on function public.update_booking_no_show_status(text, jsonb, boolean, text) to service_role;

commit;
