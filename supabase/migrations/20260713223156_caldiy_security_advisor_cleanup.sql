-- Pin search paths for public trigger helpers so untrusted schemas cannot
-- influence object resolution. Also repair the membership role assignments.

begin;

alter function public.calculate_is_team_booking(integer)
  set search_path = pg_catalog, public;

alter function public.refresh_booking_time_status_denormalized(integer)
  set search_path = pg_catalog, public;

alter function public.trigger_refresh_booking_time_status_denormalized()
  set search_path = pg_catalog, public;

alter function public.refresh_booking_time_status_team_id()
  set search_path = pg_catalog, public;

alter function public.refresh_booking_time_status_length()
  set search_path = pg_catalog, public;

alter function public.refresh_booking_time_status_parent_id()
  set search_path = pg_catalog, public;

alter function public.trigger_refresh_booking_time_status_denormalized_user()
  set search_path = pg_catalog, public;

create or replace function public.update_membership_custom_role()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  case new.role
    when 'OWNER' then new."customRoleId" := 'owner_role';
    when 'ADMIN' then new."customRoleId" := 'admin_role';
    when 'MEMBER' then new."customRoleId" := 'member_role';
  end case;

  return new;
end;
$$;

commit;
