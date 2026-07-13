-- Restore the one user-facing read policy after direct Data API writes were
-- revoked, and finish pinning the legacy booking-denormalization triggers.

begin;

drop policy if exists "users_self_select" on public.users;
create policy "users_self_select"
  on public.users
  for select
  to authenticated
  using ((select auth.uid()) = auth_user_id);

alter function public.trigger_delete_booking_time_status_denormalized()
  set search_path = pg_catalog, public;

commit;
