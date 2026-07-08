-- Supabase Auth mapping and first provider-facing RLS policies for the Cal.diy port.

begin;

create schema if not exists private;

create or replace function private.current_user_id()
returns bigint
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.id
  from public.users u
  where u.auth_user_id = auth.uid()
  limit 1
$$;

create or replace function private.is_team_admin(p_team_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.memberships m
    join public.users u on u.id = m.user_id
    where m.team_id = p_team_id
      and m.accepted = true
      and u.auth_user_id = auth.uid()
      and m.role in ('admin', 'owner')
  )
$$;

create or replace function private.can_manage_event_type(p_event_type_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.event_types e
    left join public.profiles p on p.id = e.profile_id
    where e.id = p_event_type_id
      and (
        e.user_id = private.current_user_id()
        or p.user_id = private.current_user_id()
        or (e.team_id is not null and private.is_team_admin(e.team_id))
      )
  )
$$;

create or replace function private.can_manage_booking_uid(p_booking_uid text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.bookings b
    left join public.event_types e on e.id = b.event_type_id
    where b.uid = p_booking_uid
      and (
        b.user_id = private.current_user_id()
        or (e.team_id is not null and private.is_team_admin(e.team_id))
      )
  )
$$;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.users (
    auth_user_id,
    username,
    name,
    email,
    email_verified,
    avatar_url,
    time_zone,
    role,
    identity_provider,
    created_at,
    updated_at,
    completed_onboarding
  )
  values (
    new.id,
    nullif(coalesce(new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'user_name'), ''),
    nullif(coalesce(new.raw_user_meta_data ->> 'name', new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'display_name'), ''),
    coalesce(new.email, ''),
    new.email_confirmed_at,
    nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'time_zone', ''), 'Europe/London'),
    'USER',
    'CAL',
    now(),
    now(),
    false
  )
  on conflict (auth_user_id) do update
  set email = excluded.email,
      email_verified = excluded.email_verified,
      username = coalesce(excluded.username, public.users.username),
      name = coalesce(excluded.name, public.users.name),
      avatar_url = coalesce(excluded.avatar_url, public.users.avatar_url),
      time_zone = coalesce(excluded.time_zone, public.users.time_zone),
      updated_at = now();

  return new;
end;
$$;

create or replace function private.handle_auth_user_update()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  update public.users u
  set email = coalesce(new.email, u.email),
      email_verified = new.email_confirmed_at,
      updated_at = now()
  where u.auth_user_id = new.id;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function private.handle_new_user();

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
after update on auth.users
for each row
execute function private.handle_auth_user_update();

grant usage on schema public to authenticated;
grant usage on schema private to authenticated;

grant select, insert, update, delete on table
  public.users,
  public.teams,
  public.profiles,
  public.memberships,
  public.credentials,
  public.event_types,
  public.schedules,
  public.availability,
  public.selected_calendars,
  public.destination_calendars,
  public.bookings,
  public.attendees,
  public.booking_references,
  public.audit_actors,
  public.booking_audits,
  public.host_groups,
  public.hosts,
  public.host_locations,
  public.video_call_guests,
  public.webhooks
to authenticated;

grant usage, select on all sequences in schema public to authenticated;

drop policy if exists "users_self_select" on public.users;
create policy "users_self_select"
on public.users
for select
to authenticated
using ((select auth.uid()) = auth_user_id);

drop policy if exists "users_self_insert" on public.users;
create policy "users_self_insert"
on public.users
for insert
to authenticated
with check ((select auth.uid()) = auth_user_id);

drop policy if exists "users_self_update" on public.users;
create policy "users_self_update"
on public.users
for update
to authenticated
using ((select auth.uid()) = auth_user_id)
with check ((select auth.uid()) = auth_user_id);

drop policy if exists "teams_member_select" on public.teams;
create policy "teams_member_select"
on public.teams
for select
to authenticated
using (
  private.is_team_admin(public.teams.id)
  or exists (
    select 1
    from public.memberships m
    join public.users u on u.id = m.user_id
    where m.team_id = public.teams.id
      and m.accepted = true
      and u.auth_user_id = auth.uid()
  )
);

drop policy if exists "teams_authenticated_insert" on public.teams;
create policy "teams_authenticated_insert"
on public.teams
for insert
to authenticated
with check ((select auth.uid()) is not null);

drop policy if exists "teams_admin_update" on public.teams;
create policy "teams_admin_update"
on public.teams
for update
to authenticated
using (private.is_team_admin(public.teams.id))
with check (private.is_team_admin(public.teams.id));

drop policy if exists "teams_admin_delete" on public.teams;
create policy "teams_admin_delete"
on public.teams
for delete
to authenticated
using (private.is_team_admin(public.teams.id));

drop policy if exists "profiles_owner_or_team_select" on public.profiles;
create policy "profiles_owner_or_team_select"
on public.profiles
for select
to authenticated
using (
  user_id = private.current_user_id()
  or private.is_team_admin(organization_id)
  or exists (
    select 1
    from public.memberships m
    join public.users u on u.id = m.user_id
    where m.team_id = organization_id
      and m.accepted = true
      and u.auth_user_id = auth.uid()
  )
);

drop policy if exists "profiles_owner_or_team_insert" on public.profiles;
create policy "profiles_owner_or_team_insert"
on public.profiles
for insert
to authenticated
with check (
  user_id = private.current_user_id()
  or private.is_team_admin(organization_id)
);

drop policy if exists "profiles_owner_or_team_update" on public.profiles;
create policy "profiles_owner_or_team_update"
on public.profiles
for update
to authenticated
using (
  user_id = private.current_user_id()
  or private.is_team_admin(organization_id)
)
with check (
  user_id = private.current_user_id()
  or private.is_team_admin(organization_id)
);

drop policy if exists "profiles_owner_or_team_delete" on public.profiles;
create policy "profiles_owner_or_team_delete"
on public.profiles
for delete
to authenticated
using (
  user_id = private.current_user_id()
  or private.is_team_admin(organization_id)
);

drop policy if exists "memberships_owner_or_admin_select" on public.memberships;
create policy "memberships_owner_or_admin_select"
on public.memberships
for select
to authenticated
using (
  user_id = private.current_user_id()
  or private.is_team_admin(team_id)
);

drop policy if exists "memberships_owner_or_admin_insert" on public.memberships;
create policy "memberships_owner_or_admin_insert"
on public.memberships
for insert
to authenticated
with check (private.is_team_admin(team_id));

drop policy if exists "memberships_admin_update" on public.memberships;
create policy "memberships_admin_update"
on public.memberships
for update
to authenticated
using (private.is_team_admin(team_id))
with check (private.is_team_admin(team_id));

drop policy if exists "memberships_admin_delete" on public.memberships;
create policy "memberships_admin_delete"
on public.memberships
for delete
to authenticated
using (private.is_team_admin(team_id));

drop policy if exists "credentials_owner_or_team_select" on public.credentials;
create policy "credentials_owner_or_team_select"
on public.credentials
for select
to authenticated
using (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
);

drop policy if exists "credentials_owner_or_team_insert" on public.credentials;
create policy "credentials_owner_or_team_insert"
on public.credentials
for insert
to authenticated
with check (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
);

drop policy if exists "credentials_owner_or_team_update" on public.credentials;
create policy "credentials_owner_or_team_update"
on public.credentials
for update
to authenticated
using (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
)
with check (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
);

drop policy if exists "credentials_owner_or_team_delete" on public.credentials;
create policy "credentials_owner_or_team_delete"
on public.credentials
for delete
to authenticated
using (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
);

drop policy if exists "event_types_owner_or_team_select" on public.event_types;
create policy "event_types_owner_or_team_select"
on public.event_types
for select
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_event_type(public.event_types.id)
);

drop policy if exists "event_types_owner_or_team_insert" on public.event_types;
create policy "event_types_owner_or_team_insert"
on public.event_types
for insert
to authenticated
with check (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
  or (
    profile_id is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = profile_id
        and p.user_id = private.current_user_id()
    )
  )
);

drop policy if exists "event_types_owner_or_team_update" on public.event_types;
create policy "event_types_owner_or_team_update"
on public.event_types
for update
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_event_type(public.event_types.id)
)
with check (
  user_id = private.current_user_id()
  or private.can_manage_event_type(public.event_types.id)
);

drop policy if exists "event_types_owner_or_team_delete" on public.event_types;
create policy "event_types_owner_or_team_delete"
on public.event_types
for delete
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_event_type(public.event_types.id)
);

drop policy if exists "schedules_owner_select" on public.schedules;
create policy "schedules_owner_select"
on public.schedules
for select
to authenticated
using (user_id = private.current_user_id());

drop policy if exists "schedules_owner_insert" on public.schedules;
create policy "schedules_owner_insert"
on public.schedules
for insert
to authenticated
with check (user_id = private.current_user_id());

drop policy if exists "schedules_owner_update" on public.schedules;
create policy "schedules_owner_update"
on public.schedules
for update
to authenticated
using (user_id = private.current_user_id())
with check (user_id = private.current_user_id());

drop policy if exists "schedules_owner_delete" on public.schedules;
create policy "schedules_owner_delete"
on public.schedules
for delete
to authenticated
using (user_id = private.current_user_id());

drop policy if exists "availability_owner_select" on public.availability;
create policy "availability_owner_select"
on public.availability
for select
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "availability_owner_insert" on public.availability;
create policy "availability_owner_insert"
on public.availability
for insert
to authenticated
with check (
  user_id = private.current_user_id()
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "availability_owner_update" on public.availability;
create policy "availability_owner_update"
on public.availability
for update
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_event_type(event_type_id)
)
with check (
  user_id = private.current_user_id()
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "availability_owner_delete" on public.availability;
create policy "availability_owner_delete"
on public.availability
for delete
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "selected_calendars_owner_select" on public.selected_calendars;
create policy "selected_calendars_owner_select"
on public.selected_calendars
for select
to authenticated
using (user_id = private.current_user_id());

drop policy if exists "selected_calendars_owner_insert" on public.selected_calendars;
create policy "selected_calendars_owner_insert"
on public.selected_calendars
for insert
to authenticated
with check (user_id = private.current_user_id());

drop policy if exists "selected_calendars_owner_update" on public.selected_calendars;
create policy "selected_calendars_owner_update"
on public.selected_calendars
for update
to authenticated
using (user_id = private.current_user_id())
with check (user_id = private.current_user_id());

drop policy if exists "selected_calendars_owner_delete" on public.selected_calendars;
create policy "selected_calendars_owner_delete"
on public.selected_calendars
for delete
to authenticated
using (user_id = private.current_user_id());

drop policy if exists "destination_calendars_owner_or_team_select" on public.destination_calendars;
create policy "destination_calendars_owner_or_team_select"
on public.destination_calendars
for select
to authenticated
using (
  user_id = private.current_user_id()
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "destination_calendars_owner_or_team_insert" on public.destination_calendars;
create policy "destination_calendars_owner_or_team_insert"
on public.destination_calendars
for insert
to authenticated
with check (
  user_id = private.current_user_id()
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "destination_calendars_owner_or_team_update" on public.destination_calendars;
create policy "destination_calendars_owner_or_team_update"
on public.destination_calendars
for update
to authenticated
using (
  user_id = private.current_user_id()
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
)
with check (
  user_id = private.current_user_id()
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "destination_calendars_owner_or_team_delete" on public.destination_calendars;
create policy "destination_calendars_owner_or_team_delete"
on public.destination_calendars
for delete
to authenticated
using (
  user_id = private.current_user_id()
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "bookings_owner_or_team_select" on public.bookings;
create policy "bookings_owner_or_team_select"
on public.bookings
for select
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_booking_uid(uid)
);

drop policy if exists "bookings_owner_or_team_insert" on public.bookings;
create policy "bookings_owner_or_team_insert"
on public.bookings
for insert
to authenticated
with check (
  user_id = private.current_user_id()
  or private.can_manage_booking_uid(uid)
);

drop policy if exists "bookings_owner_or_team_update" on public.bookings;
create policy "bookings_owner_or_team_update"
on public.bookings
for update
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_booking_uid(uid)
)
with check (
  user_id = private.current_user_id()
  or private.can_manage_booking_uid(uid)
);

drop policy if exists "bookings_owner_or_team_delete" on public.bookings;
create policy "bookings_owner_or_team_delete"
on public.bookings
for delete
to authenticated
using (
  user_id = private.current_user_id()
  or private.can_manage_booking_uid(uid)
);

drop policy if exists "attendees_owner_or_team_select" on public.attendees;
create policy "attendees_owner_or_team_select"
on public.attendees
for select
to authenticated
using (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "attendees_owner_or_team_insert" on public.attendees;
create policy "attendees_owner_or_team_insert"
on public.attendees
for insert
to authenticated
with check (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "attendees_owner_or_team_update" on public.attendees;
create policy "attendees_owner_or_team_update"
on public.attendees
for update
to authenticated
using (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
)
with check (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "attendees_owner_or_team_delete" on public.attendees;
create policy "attendees_owner_or_team_delete"
on public.attendees
for delete
to authenticated
using (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "booking_references_owner_or_team_select" on public.booking_references;
create policy "booking_references_owner_or_team_select"
on public.booking_references
for select
to authenticated
using (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "booking_references_owner_or_team_insert" on public.booking_references;
create policy "booking_references_owner_or_team_insert"
on public.booking_references
for insert
to authenticated
with check (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "booking_references_owner_or_team_update" on public.booking_references;
create policy "booking_references_owner_or_team_update"
on public.booking_references
for update
to authenticated
using (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
)
with check (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "booking_references_owner_or_team_delete" on public.booking_references;
create policy "booking_references_owner_or_team_delete"
on public.booking_references
for delete
to authenticated
using (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_id
      and (
        b.user_id = private.current_user_id()
        or private.can_manage_booking_uid(b.uid)
      )
  )
);

drop policy if exists "audit_actors_owner_or_team_select" on public.audit_actors;
create policy "audit_actors_owner_or_team_select"
on public.audit_actors
for select
to authenticated
using (
  exists (
    select 1
    from public.booking_audits ba
    where ba.actor_id = audit_actors.id
      and private.can_manage_booking_uid(ba.booking_uid)
  )
);

drop policy if exists "booking_audits_owner_or_team_select" on public.booking_audits;
create policy "booking_audits_owner_or_team_select"
on public.booking_audits
for select
to authenticated
using (private.can_manage_booking_uid(booking_uid));

drop policy if exists "booking_audits_owner_or_team_insert" on public.booking_audits;
create policy "booking_audits_owner_or_team_insert"
on public.booking_audits
for insert
to authenticated
with check (private.can_manage_booking_uid(booking_uid));

drop policy if exists "host_groups_owner_or_team_select" on public.host_groups;
create policy "host_groups_owner_or_team_select"
on public.host_groups
for select
to authenticated
using (
  event_type_id is null
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "host_groups_owner_or_team_insert" on public.host_groups;
create policy "host_groups_owner_or_team_insert"
on public.host_groups
for insert
to authenticated
with check (
  event_type_id is null
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "host_groups_owner_or_team_update" on public.host_groups;
create policy "host_groups_owner_or_team_update"
on public.host_groups
for update
to authenticated
using (
  event_type_id is null
  or private.can_manage_event_type(event_type_id)
)
with check (
  event_type_id is null
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "host_groups_owner_or_team_delete" on public.host_groups;
create policy "host_groups_owner_or_team_delete"
on public.host_groups
for delete
to authenticated
using (
  event_type_id is null
  or private.can_manage_event_type(event_type_id)
);

drop policy if exists "hosts_owner_or_team_select" on public.hosts;
create policy "hosts_owner_or_team_select"
on public.hosts
for select
to authenticated
using (private.can_manage_event_type(event_type_id));

drop policy if exists "hosts_owner_or_team_insert" on public.hosts;
create policy "hosts_owner_or_team_insert"
on public.hosts
for insert
to authenticated
with check (private.can_manage_event_type(event_type_id));

drop policy if exists "hosts_owner_or_team_update" on public.hosts;
create policy "hosts_owner_or_team_update"
on public.hosts
for update
to authenticated
using (private.can_manage_event_type(event_type_id))
with check (private.can_manage_event_type(event_type_id));

drop policy if exists "hosts_owner_or_team_delete" on public.hosts;
create policy "hosts_owner_or_team_delete"
on public.hosts
for delete
to authenticated
using (private.can_manage_event_type(event_type_id));

drop policy if exists "host_locations_owner_or_team_select" on public.host_locations;
create policy "host_locations_owner_or_team_select"
on public.host_locations
for select
to authenticated
using (private.can_manage_event_type(event_type_id));

drop policy if exists "host_locations_owner_or_team_insert" on public.host_locations;
create policy "host_locations_owner_or_team_insert"
on public.host_locations
for insert
to authenticated
with check (private.can_manage_event_type(event_type_id));

drop policy if exists "host_locations_owner_or_team_update" on public.host_locations;
create policy "host_locations_owner_or_team_update"
on public.host_locations
for update
to authenticated
using (private.can_manage_event_type(event_type_id))
with check (private.can_manage_event_type(event_type_id));

drop policy if exists "host_locations_owner_or_team_delete" on public.host_locations;
create policy "host_locations_owner_or_team_delete"
on public.host_locations
for delete
to authenticated
using (private.can_manage_event_type(event_type_id));

drop policy if exists "webhooks_owner_or_team_select" on public.webhooks;
create policy "webhooks_owner_or_team_select"
on public.webhooks
for select
to authenticated
using (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "webhooks_owner_or_team_insert" on public.webhooks;
create policy "webhooks_owner_or_team_insert"
on public.webhooks
for insert
to authenticated
with check (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "webhooks_owner_or_team_update" on public.webhooks;
create policy "webhooks_owner_or_team_update"
on public.webhooks
for update
to authenticated
using (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
)
with check (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "webhooks_owner_or_team_delete" on public.webhooks;
create policy "webhooks_owner_or_team_delete"
on public.webhooks
for delete
to authenticated
using (
  user_id = private.current_user_id()
  or (team_id is not null and private.is_team_admin(team_id))
  or (event_type_id is not null and private.can_manage_event_type(event_type_id))
);

drop policy if exists "video_call_guests_owner_or_team_select" on public.video_call_guests;
create policy "video_call_guests_owner_or_team_select"
on public.video_call_guests
for select
to authenticated
using (
  private.can_manage_booking_uid(booking_uid)
);

drop policy if exists "video_call_guests_owner_or_team_insert" on public.video_call_guests;
create policy "video_call_guests_owner_or_team_insert"
on public.video_call_guests
for insert
to authenticated
with check (
  private.can_manage_booking_uid(booking_uid)
);

drop policy if exists "video_call_guests_owner_or_team_update" on public.video_call_guests;
create policy "video_call_guests_owner_or_team_update"
on public.video_call_guests
for update
to authenticated
using (
  private.can_manage_booking_uid(booking_uid)
)
with check (
  private.can_manage_booking_uid(booking_uid)
);

drop policy if exists "video_call_guests_owner_or_team_delete" on public.video_call_guests;
create policy "video_call_guests_owner_or_team_delete"
on public.video_call_guests
for delete
to authenticated
using (
  private.can_manage_booking_uid(booking_uid)
);

commit;
