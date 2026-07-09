# Booking Suite Hardening Map

This is the return map for the cloud-backed booking E2E hardening lane. The branch
currently has a green `E2E API v2 Cloud` run on commit `63cf204`, so the next pass
should be targeted at remaining risk rather than reworking the already-stable
setup.

## Verified Baseline

- Cloud run `28991929882` passed on `codex/e2e-api-v2-cloud`.
- The slow booking suites now use explicit 60 second Jest timeouts.
- `add-guests`, `variable-length-bookings`, `update-booking-location`, and
  `recurring-bookings` have cloud-backed local passes after isolation fixes.
- `user-bookings` no longer depends on globally static attendee emails in the
  high-churn paths; attendee-email filtering follows the created booking's
  attendee identity.

## Remaining Hardening Targets

1. `apps/api/v2/src/platform/bookings/2024-08-13/controllers/e2e/user-bookings.e2e-spec.ts`
   - Split the largest stateful suite into smaller scenario files once behavior
     is stable enough to avoid losing cross-test fixture intent.
   - Keep converting literal attendee emails and fixed time slots to per-scenario
     values when they are not intentionally reused inside one test.
   - Add focused coverage for max-active-bookings reuse so duplicate-attendee
     behavior remains intentional after isolation.

2. `apps/api/v2/src/platform/bookings/2024-04-15/controllers/bookings.controller.e2e-spec.ts`
   - Re-run with the current timeout baseline and inspect any remaining recurring
     booking or invalid-time cascades.
   - Compare request bodies against the 2024-08-13 behavior where failures look
     like shared fixture conflicts rather than endpoint regressions.

3. Email suites under
   `apps/api/v2/src/platform/bookings/2024-08-13/controllers/e2e/emails/`
   - Confirm cloud timing after timeout baseline.
   - Randomize attendee addresses that are not part of email de-duplication
     assertions.
   - Keep snapshots/assertions tied to body values rather than literal addresses
     where possible.

4. Create-booking 400 cascades
   - Group remaining expected-400 tests by domain: metadata, availability,
     duplicate attendee, invalid location, and max-active-bookings.
   - Ensure each negative test has its own event type or isolated booking window
     unless the point of the test is to collide with a prior booking.

5. Booking mutation suites
   - Re-check `remove-attendee`, `reschedule-bookings`, `seated-bookings`, and
     `api-key-bookings` after the current cloud baseline.
   - Prefer per-test booking factories for tests that mutate guests, seats,
     attendees, or location state.

## Suggested Return Order

1. Run the full `E2E API v2 Cloud` workflow after any Supabase/Core booking
   change and use the failed log as the source of truth.
2. If the workflow fails, fix the first failing suite only and rerun that suite
   locally against the cloud database before another full workflow.
3. If `user-bookings` fails again, split the specific failing scenario out or
   isolate its fixture before touching shared helpers.
4. Once the full workflow is green twice on separate commits, consider this lane
   stable enough to move deeper into Companion/mobile contract integration.

## Useful Commands

```sh
gh run view <run-id> --log-failed > /tmp/run-<run-id>.log
rg -n "FAIL src/platform/bookings|Exceeded timeout|expected 201|expected 200|expected 400|TypeError|Http Exception Filter" /tmp/run-<run-id>.log
```

```sh
set -a
[ -f .env ] && . ./.env
set +a
export DATABASE_READ_URL="${DATABASE_READ_URL:-$DATABASE_URL}"
export DATABASE_WRITE_URL="${DATABASE_WRITE_URL:-$DATABASE_URL}"
export DATABASE_DIRECT_URL="${DATABASE_DIRECT_URL:-$DATABASE_URL}"
corepack yarn workspace @calcom/api-v2 test:e2e:ci src/platform/bookings/2024-08-13/controllers/e2e/<suite>.e2e-spec.ts --runInBand
```
