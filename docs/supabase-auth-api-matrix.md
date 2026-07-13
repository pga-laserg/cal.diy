# Supabase Auth API Matrix

The Companion sends a Supabase access token to the existing Cal.diy API. The API verifies the token with Supabase Auth, maps `auth.users.id` to `public.users.auth_user_id`, and then applies the normal Cal authorization checks.

## Read smoke coverage

| Surface | API endpoint | Companion consumer | Check |
| --- | --- | --- | --- |
| Profile | `GET /v2/me` | `services/calcom/user.ts` | `yarn smoke:supabase-auth` |
| Event types | `GET /v2/event-types` | `services/calcom/event-types.ts` | `yarn smoke:supabase-auth` |
| Schedules | `GET /v2/schedules` | `services/calcom/schedules.ts` | `yarn smoke:supabase-auth` |
| Bookings | `GET /v2/bookings` | `services/calcom/bookings.ts` | `yarn smoke:supabase-auth` |
| Conferencing | `GET /v2/conferencing` | event editor location loading | `yarn smoke:supabase-auth` |
| Calendars | `GET /v2/calendars` | future native calendar setup | `yarn smoke:supabase-auth` |

## Write coverage before release

1. Create, update, and delete an event type through `/v2/event-types`.
2. Create, update, duplicate, and delete a schedule through `/v2/schedules`.
3. Cover cancel, reschedule, confirm, decline, guest, and location booking actions with an owned fixture.
4. Cover calendar connection lifecycle with a test credential rather than a personal provider account.
5. Cover private-link and webhook ownership guards with two mapped Supabase users.

The smoke script is deliberately read-only. It accepts `SUPABASE_ACCESS_TOKEN` from the shell, never writes it to disk, and never prints it.
