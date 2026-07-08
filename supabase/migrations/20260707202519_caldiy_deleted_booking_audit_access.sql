-- Preserve audit-log access after a booking row is deleted.

begin;

create schema if not exists private;

create table if not exists private.booking_access_snapshots (
  booking_uid text primary key,
  owner_user_id bigint,
  team_id bigint,
  event_type_id bigint,
  captured_at timestamptz not null default now()
);

create or replace function private.capture_deleted_booking_access()
returns trigger
language plpgsql
security definer
set search_path = public, auth, private
as $$
declare
  v_team_id bigint;
begin
  select e.team_id
  into v_team_id
  from public.event_types e
  where e.id = old.event_type_id;

  insert into private.booking_access_snapshots (
    booking_uid,
    owner_user_id,
    team_id,
    event_type_id,
    captured_at
  )
  values (
    old.uid,
    old.user_id,
    v_team_id,
    old.event_type_id,
    now()
  )
  on conflict (booking_uid) do update
  set owner_user_id = excluded.owner_user_id,
      team_id = excluded.team_id,
      event_type_id = excluded.event_type_id,
      captured_at = excluded.captured_at;

  return old;
end;
$$;

drop trigger if exists bookings_capture_deleted_access on public.bookings;
create trigger bookings_capture_deleted_access
before delete on public.bookings
for each row
execute function private.capture_deleted_booking_access();

create or replace function private.can_manage_booking_uid(p_booking_uid text)
returns boolean
language sql
stable
security definer
set search_path = public, auth, private
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
  or exists (
    select 1
    from private.booking_access_snapshots s
    where s.booking_uid = p_booking_uid
      and (
        s.owner_user_id = private.current_user_id()
        or (s.team_id is not null and private.is_team_admin(s.team_id))
      )
  )
$$;

commit;
