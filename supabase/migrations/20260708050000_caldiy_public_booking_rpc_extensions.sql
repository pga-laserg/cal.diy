-- Public booking RPC extensions for the Cal.diy-shaped Supabase port.
-- This keeps the public page bridge narrow while adding the first real
-- availability snapshot and a basic booking write path for the ported core.

begin;

create or replace function private.parse_public_username_list(p_username text)
returns text[]
language sql
stable
security definer
set search_path = public, auth
as $$
  select array_remove(
    regexp_split_to_array(
      replace(replace(replace(lower(coalesce(p_username, '')), '%2b', '+'), '%20', '+'), ' ', '+'),
      '\+'
    ),
    ''
  )::text[]
$$;

create or replace function private.resolve_public_booking_context(
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
  v_usernames text[] := private.parse_public_username_list(p_username);
  v_is_group boolean := cardinality(v_usernames) > 1;
  v_user_record record;
  v_profile_id bigint;
  v_profile_uid text;
  v_profile_username text;
  v_profile_org_id bigint;
  v_team_id bigint;
  v_team_slug text;
  v_team_name text;
  v_team_banner_url text;
  v_team_time_zone text;
  v_team_week_start text;
  v_team_hide_branding boolean;
  v_event_record record;
  v_users jsonb := '[]'::jsonb;
  v_user_ids bigint[] := '{}'::bigint[];
  v_kind text := 'user';
  v_synthetic_event jsonb;
begin
  select
    null::bigint as id,
    null::text as slug,
    null::text as title,
    null::text as description,
    null::text as interface_language,
    null::integer as position,
    null::jsonb as locations,
    null::integer as length,
    null::integer as offset_start,
    null::boolean as hidden
  into v_event_record;

  if v_is_group then
    select
      u.id,
      u.username,
      u.name,
      u.avatar_url,
      u.time_zone,
      u.allow_dynamic_booking,
      u.allow_seo_indexing,
      u.hide_branding
    into v_user_record
    from public.users u
    where u.username = any(v_usernames)
    order by array_position(v_usernames, u.username)
    limit 1;

    if v_user_record.id is null then
      return null;
    end if;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', u.id,
          'username', u.username,
          'name', u.name,
          'avatar_url', u.avatar_url,
          'time_zone', u.time_zone,
          'allow_dynamic_booking', u.allow_dynamic_booking,
          'allow_seo_indexing', u.allow_seo_indexing,
          'hide_branding', u.hide_branding
        )
        order by array_position(v_usernames, u.username)
      ),
      '[]'::jsonb
    )
    into v_users
    from public.users u
    where u.username = any(v_usernames);

    select array_agg((item->>'id')::bigint order by ord)
    into v_user_ids
    from jsonb_array_elements(v_users) with ordinality as user_item(item, ord);

    v_kind := 'group';
    v_synthetic_event := jsonb_build_object(
      'id', null,
      'slug', p_event_slug,
      'title', initcap(replace(p_event_slug, '-', ' ')),
      'description', null,
      'interface_language', null,
      'position', 0,
      'locations', '[]'::jsonb,
      'length', 30,
      'offset_start', 0,
      'hidden', false
    );

    return jsonb_build_object(
      'kind', v_kind,
      'usernames', to_jsonb(v_usernames),
      'user', jsonb_build_object(
        'id', v_user_record.id,
        'username', v_user_record.username,
        'name', v_user_record.name,
        'avatar_url', v_user_record.avatar_url,
        'time_zone', v_user_record.time_zone,
        'allow_dynamic_booking', v_user_record.allow_dynamic_booking,
        'allow_seo_indexing', v_user_record.allow_seo_indexing,
        'hide_branding', v_user_record.hide_branding
      ),
      'users', v_users,
      'profile', null,
      'team', null,
      'event_type', v_synthetic_event,
      'organizer_user_id', v_user_record.id,
      'user_ids', to_jsonb(coalesce(v_user_ids, '{}'::bigint[]))
    );
  end if;

  select
    u.id,
    u.username,
    u.name,
    u.avatar_url,
    u.time_zone,
    u.allow_dynamic_booking,
    u.allow_seo_indexing,
    u.hide_branding
  into v_user_record
  from public.users u
  where u.username = p_username
  limit 1;

  if v_user_record.id is not null then
    select
      p.id,
      p.uid,
      p.username,
      p.organization_id
    into
      v_profile_id,
      v_profile_uid,
      v_profile_username,
      v_profile_org_id
    from public.profiles p
    where p.user_id = v_user_record.id
      and p.username = p_username
    limit 1;

    select
      t.id,
      t.slug,
      t.name,
      t.banner_url,
      t.time_zone,
      t.week_start,
      t.hide_branding
    into
      v_team_id,
      v_team_slug,
      v_team_name,
      v_team_banner_url,
      v_team_time_zone,
      v_team_week_start,
      v_team_hide_branding
    from public.teams t
    where t.id = coalesce(
      (select u.organization_id from public.users u where u.id = v_user_record.id),
      v_profile_org_id
    )
    limit 1;
  else
    v_kind := 'team';
    select
      t.id,
      t.slug,
      t.name,
      t.banner_url,
      t.time_zone,
      t.week_start,
      t.hide_branding
    into
      v_team_id,
      v_team_slug,
      v_team_name,
      v_team_banner_url,
      v_team_time_zone,
      v_team_week_start,
      v_team_hide_branding
    from public.teams t
    where t.slug = p_username
    limit 1;
  end if;

  if v_user_record.id is not null then
    select e.id, e.slug, e.title, e.description, e.interface_language, e.position, e.locations, e.length, e.offset_start, e.hidden
    into v_event_record
    from public.event_types e
    where e.slug = p_event_slug
      and e.hidden = false
      and (
        e.user_id = v_user_record.id
        or (v_profile_id is not null and e.profile_id = v_profile_id)
        or (v_team_id is not null and e.team_id = v_team_id)
      )
    order by
      case
        when e.user_id = v_user_record.id then 0
        when v_profile_id is not null and e.profile_id = v_profile_id then 1
        when v_team_id is not null and e.team_id = v_team_id then 2
        else 3
      end
    limit 1;
  elsif v_team_id is not null then
    select e.id, e.slug, e.title, e.description, e.interface_language, e.position, e.locations, e.length, e.offset_start, e.hidden
    into v_event_record
    from public.event_types e
    where e.slug = p_event_slug
      and e.hidden = false
      and e.team_id = v_team_id
    order by e.position, e.id
    limit 1;
  end if;

  if v_event_record.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'kind', v_kind,
    'usernames', to_jsonb(v_usernames),
    'user', case
      when v_user_record.id is null then null
      else jsonb_build_object(
        'id', v_user_record.id,
        'username', v_user_record.username,
        'name', v_user_record.name,
        'avatar_url', v_user_record.avatar_url,
        'time_zone', v_user_record.time_zone,
        'allow_dynamic_booking', v_user_record.allow_dynamic_booking,
        'allow_seo_indexing', v_user_record.allow_seo_indexing,
        'hide_branding', v_user_record.hide_branding
      )
    end,
    'users', coalesce(v_users, '[]'::jsonb),
    'profile', case
      when v_profile_id is null then null
      else jsonb_build_object(
        'id', v_profile_id,
        'uid', v_profile_uid,
        'username', v_profile_username,
        'organization_id', v_profile_org_id
      )
    end,
    'team', case
      when v_team_id is null then null
      else jsonb_build_object(
        'id', v_team_id,
        'slug', v_team_slug,
        'name', v_team_name,
        'banner_url', v_team_banner_url,
        'time_zone', v_team_time_zone,
        'week_start', v_team_week_start,
        'hide_branding', v_team_hide_branding
      )
    end,
    'event_type', jsonb_build_object(
      'id', v_event_record.id,
      'slug', v_event_record.slug,
      'title', v_event_record.title,
      'description', v_event_record.description,
      'interface_language', v_event_record.interface_language,
      'position', v_event_record.position,
      'locations', coalesce(v_event_record.locations, '[]'::jsonb),
      'length', v_event_record.length,
      'offset_start', v_event_record.offset_start,
      'hidden', v_event_record.hidden
    ),
    'organizer_user_id', v_user_record.id,
    'user_ids', case
      when v_user_ids is null then '[]'::jsonb
      else to_jsonb(v_user_ids)
    end
  );
end;
$$;

create or replace function public.get_public_booking_page(
  p_username text,
  p_event_slug text
)
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select private.resolve_public_booking_context(p_username, p_event_slug);
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
  v_user_ids bigint[] := '{}';
  v_event_type_id bigint := nullif(v_context->'event_type'->>'id', '')::bigint;
  v_dynamic_group_slug text := lower(p_username);
  v_bookings jsonb := '[]'::jsonb;
  v_availability jsonb := '[]'::jsonb;
begin
  if v_context is null then
    return null;
  end if;

  select coalesce(array_agg((item->>'id')::bigint), '{}'::bigint[])
  into v_user_ids
  from jsonb_array_elements(coalesce(v_context->'users', '[]'::jsonb)) as item;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'user_id', a.user_id,
        'event_type_id', a.event_type_id,
        'days', a.days,
        'start_time', a.start_time,
        'end_time', a.end_time,
        'date', a.date,
        'schedule_id', a.schedule_id
      )
      order by a.user_id, a.date nulls first, a.start_time
    ),
    '[]'::jsonb
  )
  into v_availability
  from public.availability a
  where a.user_id = any(v_user_ids)
    and (
      v_event_type_id is null
      or a.event_type_id = v_event_type_id
      or a.event_type_id is null
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
  v_event_type_id bigint := nullif(v_context->'event_type'->>'id', '')::bigint;
  v_organizer_user_id bigint := nullif(v_context->>'organizer_user_id', '')::bigint;
  v_booking_uid text := replace(gen_random_uuid()::text, '-', '');
  v_i_cal_uid text := replace(gen_random_uuid()::text, '-', '');
  v_actor_id uuid;
  v_booking public.bookings%rowtype;
  v_overlap_count integer := 0;
  v_dynamic_group_slug text := lower(p_username);
  v_guest_count integer := 0;
  v_attendee_rows integer := 0;
begin
  if v_context is null then
    raise exception 'public_booking_context_not_found';
  end if;

  if p_end_time <= p_start_time then
    raise exception 'invalid_booking_window';
  end if;

  perform pg_advisory_xact_lock(hashtext(
    coalesce(v_event_type_id::text, v_dynamic_group_slug || ':' || p_event_slug)
  ));

  select count(*)
  into v_overlap_count
  from public.bookings b
  where b.status in ('accepted', 'pending')
    and (
      (v_event_type_id is not null and b.event_type_id = v_event_type_id)
      or (
        v_event_type_id is null
        and b.dynamic_event_slug_ref = p_event_slug
        and b.dynamic_group_slug_ref = v_dynamic_group_slug
      )
      or (v_organizer_user_id is not null and b.user_id = v_organizer_user_id)
    )
    and tstzrange(b.start_time, b.end_time, '[)') && tstzrange(p_start_time, p_end_time, '[)');

  if v_overlap_count > 0 then
    raise exception 'public_booking_conflict';
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
      'organizer_user_id', v_organizer_user_id
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
    'page', v_context
  );
end;
$$;

grant execute on function private.parse_public_username_list(text) to anon, authenticated;
grant execute on function private.resolve_public_booking_context(text, text) to anon, authenticated;
grant execute on function public.get_public_booking_page(text, text) to anon, authenticated;
grant execute on function public.get_public_booking_availability(text, text, timestamptz, timestamptz) to anon, authenticated;
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
