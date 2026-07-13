begin;

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

revoke execute on function public.update_booking_no_show_status(text, jsonb, boolean, text) from public, anon, authenticated;
grant execute on function public.update_booking_no_show_status(text, jsonb, boolean, text) to service_role;

commit;
