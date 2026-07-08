-- Booking effects, payment summary, and reschedule state-machine support.
-- This is the next layer after the public booking write path:
-- - carry confirmation flags from the Cal.diy-shaped event type
-- - enqueue calendar/email/webhook/payment effects in an outbox table
-- - add a reschedule request RPC that flips the original booking state cleanly

begin;

alter table public.event_types
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists scheduling_type public.scheduling_type not null default 'collective',
  add column if not exists requires_confirmation boolean not null default false,
  add column if not exists requires_confirmation_for_free_email boolean not null default false,
  add column if not exists requires_confirmation_will_block_slot boolean not null default true,
  add column if not exists requires_booker_email_verification boolean not null default false,
  add column if not exists seats_per_time_slot integer,
  add column if not exists minimum_reschedule_notice integer,
  add column if not exists allow_rescheduling_cancelled_bookings boolean not null default false,
  add column if not exists before_event_buffer integer not null default 0,
  add column if not exists after_event_buffer integer not null default 0,
  add column if not exists booking_limits jsonb,
  add column if not exists duration_limits jsonb,
  add column if not exists use_booker_timezone boolean not null default false,
  add column if not exists only_show_first_available_slot boolean not null default false,
  add column if not exists hide_calendar_notes boolean not null default false,
  add column if not exists hide_calendar_event_details boolean not null default false,
  add column if not exists can_send_cal_video_transcription_emails boolean not null default false;

create type public.booking_effect_kind as enum (
  'calendar_create',
  'calendar_reschedule',
  'calendar_cancel',
  'email_requested',
  'email_confirmed',
  'email_rescheduled',
  'webhook_booking_created',
  'webhook_booking_requested',
  'webhook_booking_rescheduled',
  'payment_initiated',
  'payment_required'
);

create type public.booking_effect_status as enum ('pending', 'done', 'failed');

create table if not exists public.booking_effects (
  id uuid primary key default gen_random_uuid(),
  booking_uid text not null references public.bookings(uid) on delete cascade,
  booking_id bigint not null references public.bookings(id) on delete cascade,
  effect_kind public.booking_effect_kind not null,
  status public.booking_effect_status not null default 'pending',
  payload jsonb not null default '{}'::jsonb,
  error text,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (booking_uid, effect_kind)
);

alter table public.booking_effects enable row level security;

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
    null::boolean as hidden,
    null::jsonb as metadata,
    null::public.scheduling_type as scheduling_type,
    null::boolean as requires_confirmation,
    null::boolean as requires_confirmation_for_free_email,
    null::boolean as requires_confirmation_will_block_slot,
    null::boolean as requires_booker_email_verification,
    null::integer as seats_per_time_slot,
    null::integer as minimum_reschedule_notice,
    null::boolean as allow_rescheduling_cancelled_bookings,
    null::integer as before_event_buffer,
    null::integer as after_event_buffer,
    null::jsonb as booking_limits,
    null::jsonb as duration_limits,
    null::boolean as use_booker_timezone,
    null::boolean as only_show_first_available_slot,
    null::boolean as hide_calendar_notes,
    null::boolean as hide_calendar_event_details,
    null::boolean as can_send_cal_video_transcription_emails
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
      'hidden', false,
      'metadata', '{}'::jsonb,
      'scheduling_type', 'collective',
      'requires_confirmation', false,
      'requires_confirmation_for_free_email', false,
      'requires_confirmation_will_block_slot', true,
      'requires_booker_email_verification', false,
      'seats_per_time_slot', null,
      'minimum_reschedule_notice', null,
      'allow_rescheduling_cancelled_bookings', false,
      'before_event_buffer', 0,
      'after_event_buffer', 0,
      'booking_limits', null,
      'duration_limits', null,
      'use_booker_timezone', false,
      'only_show_first_available_slot', false,
      'hide_calendar_notes', false,
      'hide_calendar_event_details', false,
      'can_send_cal_video_transcription_emails', false
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
    select
      e.id,
      e.slug,
      e.title,
      e.description,
      e.interface_language,
      e.position,
      e.locations,
      e.length,
      e.offset_start,
      e.hidden,
      e.metadata,
      e.scheduling_type,
      e.requires_confirmation,
      e.requires_confirmation_for_free_email,
      e.requires_confirmation_will_block_slot,
      e.requires_booker_email_verification,
      e.seats_per_time_slot,
      e.minimum_reschedule_notice,
      e.allow_rescheduling_cancelled_bookings,
      e.before_event_buffer,
      e.after_event_buffer,
      e.booking_limits,
      e.duration_limits,
      e.use_booker_timezone,
      e.only_show_first_available_slot,
      e.hide_calendar_notes,
      e.hide_calendar_event_details,
      e.can_send_cal_video_transcription_emails
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
    select
      e.id,
      e.slug,
      e.title,
      e.description,
      e.interface_language,
      e.position,
      e.locations,
      e.length,
      e.offset_start,
      e.hidden,
      e.metadata,
      e.scheduling_type,
      e.requires_confirmation,
      e.requires_confirmation_for_free_email,
      e.requires_confirmation_will_block_slot,
      e.requires_booker_email_verification,
      e.seats_per_time_slot,
      e.minimum_reschedule_notice,
      e.allow_rescheduling_cancelled_bookings,
      e.before_event_buffer,
      e.after_event_buffer,
      e.booking_limits,
      e.duration_limits,
      e.use_booker_timezone,
      e.only_show_first_available_slot,
      e.hide_calendar_notes,
      e.hide_calendar_event_details,
      e.can_send_cal_video_transcription_emails
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
      'hidden', v_event_record.hidden,
      'metadata', coalesce(v_event_record.metadata, '{}'::jsonb),
      'scheduling_type', v_event_record.scheduling_type,
      'requires_confirmation', coalesce(v_event_record.requires_confirmation, false),
      'requires_confirmation_for_free_email', coalesce(v_event_record.requires_confirmation_for_free_email, false),
      'requires_confirmation_will_block_slot', coalesce(v_event_record.requires_confirmation_will_block_slot, true),
      'requires_booker_email_verification', coalesce(v_event_record.requires_booker_email_verification, false),
      'seats_per_time_slot', v_event_record.seats_per_time_slot,
      'minimum_reschedule_notice', v_event_record.minimum_reschedule_notice,
      'allow_rescheduling_cancelled_bookings', coalesce(v_event_record.allow_rescheduling_cancelled_bookings, false),
      'before_event_buffer', coalesce(v_event_record.before_event_buffer, 0),
      'after_event_buffer', coalesce(v_event_record.after_event_buffer, 0),
      'booking_limits', v_event_record.booking_limits,
      'duration_limits', v_event_record.duration_limits,
      'use_booker_timezone', coalesce(v_event_record.use_booker_timezone, false),
      'only_show_first_available_slot', coalesce(v_event_record.only_show_first_available_slot, false),
      'hide_calendar_notes', coalesce(v_event_record.hide_calendar_notes, false),
      'hide_calendar_event_details', coalesce(v_event_record.hide_calendar_event_details, false),
      'can_send_cal_video_transcription_emails', coalesce(v_event_record.can_send_cal_video_transcription_emails, false)
    ),
    'organizer_user_id', v_user_record.id,
    'user_ids', case
      when v_user_ids is null then '[]'::jsonb
      else to_jsonb(v_user_ids)
    end
  );
end;
$$;

create or replace function private.booking_payment_summary(p_event_type_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(
    jsonb_build_object(
      'enabled', coalesce(sum(
        case
          when coalesce((app.value->>'enabled')::boolean, true)
            and nullif(app.value->>'price', '') is not null
          then 1
          else 0
        end
      ), 0) > 0,
      'price', coalesce(sum(
        case
          when coalesce((app.value->>'enabled')::boolean, true)
            then coalesce(nullif(app.value->>'price', '')::numeric, 0)
          else 0
        end
      ), 0),
      'currency', coalesce(
        (array_agg(nullif(app.value->>'currency', '') order by app.key) filter (where nullif(app.value->>'currency', '') is not null))[1],
        'USD'
      ),
      'payment_option', coalesce(
        (array_agg(nullif(app.value->>'paymentOption', '') order by app.key) filter (where nullif(app.value->>'paymentOption', '') is not null))[1],
        'ON_BOOKING'
      )
    ),
    jsonb_build_object(
      'enabled', false,
      'price', 0,
      'currency', 'USD',
      'payment_option', 'ON_BOOKING'
    )
  )
  from public.event_types e
  left join lateral jsonb_each(coalesce(e.metadata->'apps', '{}'::jsonb)) as app(key, value) on true
  where e.id = p_event_type_id
  group by e.id;
$$;

create or replace function private.queue_booking_effect(
  p_booking_uid text,
  p_booking_id bigint,
  p_effect_kind public.booking_effect_kind,
  p_payload jsonb
)
returns void
language sql
volatile
security definer
set search_path = public, auth
as $$
  insert into public.booking_effects (
    booking_uid,
    booking_id,
    effect_kind,
    status,
    payload,
    updated_at
  )
  values (
    p_booking_uid,
    p_booking_id,
    p_effect_kind,
    'pending',
    coalesce(p_payload, '{}'::jsonb),
    now()
  )
  on conflict (booking_uid, effect_kind) do update
  set status = 'pending',
      payload = excluded.payload,
      error = null,
      processed_at = null,
      updated_at = now();
$$;

create or replace function private.capture_booking_effects()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_event_type_id bigint := coalesce(new.event_type_id, old.event_type_id);
  v_payment_summary jsonb := private.booking_payment_summary(v_event_type_id);
  v_booking_payload jsonb;
  v_is_reschedule boolean := coalesce(new.rescheduled, false) or nullif(coalesce(new.from_reschedule, ''), '') is not null;
begin
  if tg_op = 'INSERT' then
    v_booking_payload := jsonb_build_object(
      'booking', to_jsonb(new),
      'event_type_id', v_event_type_id,
      'payment', v_payment_summary
    );

    if new.status = 'accepted' then
      perform private.queue_booking_effect(new.uid, new.id, 'calendar_create', v_booking_payload);
      perform private.queue_booking_effect(new.uid, new.id, 'email_confirmed', v_booking_payload);
      perform private.queue_booking_effect(new.uid, new.id, 'webhook_booking_created', v_booking_payload);
    elsif new.status = 'pending' then
      perform private.queue_booking_effect(new.uid, new.id, 'email_requested', v_booking_payload);
      perform private.queue_booking_effect(new.uid, new.id, 'webhook_booking_requested', v_booking_payload);
    end if;

    if coalesce((v_payment_summary->>'enabled')::boolean, false)
      and coalesce((v_payment_summary->>'price')::numeric, 0) > 0 then
      perform private.queue_booking_effect(
        new.uid,
        new.id,
        case when new.status = 'pending' then 'payment_required' else 'payment_initiated' end,
        v_booking_payload
      );
    end if;
  elsif tg_op = 'UPDATE' then
    v_booking_payload := jsonb_build_object(
      'booking', to_jsonb(new),
      'previous_booking', to_jsonb(old),
      'event_type_id', v_event_type_id,
      'payment', v_payment_summary
    );

    if new.status = 'cancelled' and old.status is distinct from new.status then
      perform private.queue_booking_effect(new.uid, new.id, 'calendar_cancel', v_booking_payload);
      if v_is_reschedule then
        perform private.queue_booking_effect(new.uid, new.id, 'email_rescheduled', v_booking_payload);
        perform private.queue_booking_effect(new.uid, new.id, 'webhook_booking_rescheduled', v_booking_payload);
      end if;
    elsif new.status = 'accepted' and old.status is distinct from new.status then
      perform private.queue_booking_effect(new.uid, new.id, 'calendar_create', v_booking_payload);
      perform private.queue_booking_effect(new.uid, new.id, 'email_confirmed', v_booking_payload);
      perform private.queue_booking_effect(new.uid, new.id, 'webhook_booking_created', v_booking_payload);
    elsif new.status = 'pending' and old.status is distinct from new.status then
      perform private.queue_booking_effect(new.uid, new.id, 'email_requested', v_booking_payload);
      perform private.queue_booking_effect(new.uid, new.id, 'webhook_booking_requested', v_booking_payload);
    end if;

    if coalesce((v_payment_summary->>'enabled')::boolean, false)
      and coalesce((v_payment_summary->>'price')::numeric, 0) > 0 then
      perform private.queue_booking_effect(
        new.uid,
        new.id,
        case when new.status = 'pending' then 'payment_required' else 'payment_initiated' end,
        v_booking_payload
      );
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists bookings_capture_effects on public.bookings;
create trigger bookings_capture_effects
after insert or update on public.bookings
for each row
execute function private.capture_booking_effects();

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
  v_booking_uid text := replace(gen_random_uuid()::text, '-', '');
  v_i_cal_uid text := replace(gen_random_uuid()::text, '-', '');
  v_actor_id uuid;
  v_booking public.bookings%rowtype;
  v_available_user_count integer := coalesce(array_length(v_available_user_ids, 1), 0);
  v_dynamic_group_slug text := lower(p_username);
  v_attendee_rows integer := 0;
  v_booking_status public.booking_status := 'accepted';
  v_requires_confirmation boolean := coalesce((v_context->'event_type'->>'requires_confirmation')::boolean, false);
  v_requires_booker_email_verification boolean := coalesce(
    (v_context->'event_type'->>'requires_booker_email_verification')::boolean,
    false
  );
  v_payment_summary jsonb := private.booking_payment_summary(v_event_type_id);
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

  if v_requires_confirmation or v_requires_booker_email_verification then
    v_booking_status := 'pending';
  end if;

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
      'selected_user_id', v_available_user_ids[1],
      'payment', v_payment_summary
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
    'available_user_ids', to_jsonb(v_available_user_ids),
    'payment', v_payment_summary
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
  v_actor_id uuid;
  v_effect_payload jsonb;
begin
  select *
  into v_booking
  from public.bookings b
  where b.uid = p_booking_uid
  limit 1;

  if v_booking.id is null then
    raise exception 'booking_not_found';
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

grant execute on function private.booking_payment_summary(bigint) to anon, authenticated;
grant execute on function private.queue_booking_effect(text, bigint, public.booking_effect_kind, jsonb) to anon, authenticated;
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
grant execute on function public.request_booking_reschedule(text, text, text) to anon, authenticated;

commit;
