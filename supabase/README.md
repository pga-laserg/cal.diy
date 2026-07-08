# Supabase port scaffold

This folder is the starting point for the Cal.diy-shaped Supabase port.

The first migration keeps the upstream domain names intact as much as possible so later upstream syncs stay readable:

- core identity and org tables
- scheduling tables
- booking and audit tables
- calendar sync tables
- host and webhook tables

RLS is enabled in the bootstrap migration. Policies are intentionally deferred to the next pass once the access model is pinned down.

## Live cloud verification

The linked `agenda-cl` project currently has:

- `public.booking_effects` present with RLS enabled and no table-specific policies yet
- the `bookings_capture_effects` and `bookings_capture_deleted_access` triggers installed
- no seeded booking data in the live project, so the booking smoke test had to be created in a rollback transaction

That smoke test surfaced one live bug in `public.create_public_booking`: the `booking_audits.action` value needed to be cast to `public.booking_audit_action`. The migration files now reflect that fix.
