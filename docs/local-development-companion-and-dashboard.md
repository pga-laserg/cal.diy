# Local Companion And Cal.diy

This runbook covers the local development setup for the AgendaCon Companion iOS app and the Cal.diy dashboard fork.

## Repository Paths

```text
Companion: /Users/pablogallardo/Development/agendacon-vnext/companion
Mobile app: /Users/pablogallardo/Development/agendacon-vnext/companion/apps/mobile
Cal.diy:   /Users/pablogallardo/Development/agendacon-vnext/cal.diy
```

## Port Contract

| Service | URL/port |
| --- | --- |
| Cal.diy dashboard | `http://localhost:3001` |
| Cal.diy API v2 | `http://localhost:5555` |
| Companion Metro | `http://localhost:8082` |
| Dashboard event types | `http://localhost:3001/event-types` |

## Start Cal.diy Dashboard

Open a terminal:

```bash
cd /Users/pablogallardo/Development/agendacon-vnext/cal.diy
PORT=3001 corepack yarn workspace @calcom/web dev
```

Then open the dashboard:

```bash
open http://localhost:3001/event-types
```

Use `http://localhost:3001/auth/login` when starting from the login screen.

The root `.env` supplies the dashboard Supabase and database configuration. Do not copy service-role, secret, personal, or experimental Supabase tokens into browser-facing environment variables.

## Start API v2

The Companion uses API v2 for authenticated event types, schedules, bookings, and profile operations. Keep this process running in a second terminal:

```bash
cd /Users/pablogallardo/Development/agendacon-vnext/cal.diy
corepack yarn workspace @calcom/api-v2 dev:local
```

This loads the shared root environment, builds missing platform artifacts, and starts API v2 on port `5555`.

## Companion Environment

The mobile environment file is:

```text
/Users/pablogallardo/Development/agendacon-vnext/companion/apps/mobile/.env.local
```

If it does not exist:

```bash
cd /Users/pablogallardo/Development/agendacon-vnext/companion
cp apps/mobile/.env.example apps/mobile/.env.local
```

For the iOS simulator, the local target values should resolve to the services above:

```dotenv
EXPO_PUBLIC_CALCOM_APP_BASE_URL=http://localhost:3001
EXPO_PUBLIC_CALCOM_API_BASE_URL=http://localhost:5555
EXPO_PUBLIC_CALCOM_WEB_BASE_URL=http://localhost:3001
```

Keep `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` populated. Only the publishable key belongs in this file.

If the simulator cannot reach the host through `localhost`, replace the three local URLs with the Mac's LAN address, for example `http://192.168.x.x:3001` and `http://192.168.x.x:5555`.

## Build And Run Companion On iOS Simulator

The current app bundle ID is `com.cal.companion`. The current simulator used for development is `iPhone 17`.

First native build, install, and launch:

```bash
cd /Users/pablogallardo/Development/agendacon-vnext/companion/apps/mobile
pnpm install
pnpm exec expo run:ios --device "iPhone 17" --port 8082
```

The repository prefers Bun, so the equivalent command is:

```bash
cd /Users/pablogallardo/Development/agendacon-vnext/companion
bun install
bun run mobile:ios -- --device "iPhone 17" --port 8082
```

For subsequent JavaScript-only changes, keep the installed native app and start Metro separately:

```bash
cd /Users/pablogallardo/Development/agendacon-vnext/companion/apps/mobile
pnpm exec expo start --dev-client --port 8082
```

In another terminal, launch the installed app if necessary:

```bash
xcrun simctl launch booted com.cal.companion
```

To boot the named simulator first:

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
open -a Simulator
```

## Useful Checks

Check that the dashboard and API ports are occupied:

```bash
lsof -nP -iTCP:3001 -sTCP:LISTEN
lsof -nP -iTCP:5555 -sTCP:LISTEN
```

Run mobile type checking and focused tests:

```bash
cd /Users/pablogallardo/Development/agendacon-vnext/companion/apps/mobile
pnpm exec tsc --noEmit --pretty false -p tsconfig.json --ignoreDeprecations 6.0
pnpm exec jest utils/landing-page-navigation.test.js utils/region.test.js --runInBand
```

Inspect recent simulator JavaScript/runtime failures:

```bash
xcrun simctl spawn booted log show --style compact --last 3m \
  --predicate 'process == "AgendaCon"' 2>/dev/null \
  | rg -i 'failed to compile|syntax error|javascript error|invariant|fatal|unable to load|failed to load'
```

## Troubleshooting

- `P1001` for `localhost:5450`: the optional local Postgres helper is not running. The current Supabase-backed setup uses the configured remote Supabase database; do not apply Supabase Auth migrations to a vanilla Postgres instance without the `auth` schema.
- API requests fail from the simulator: confirm API v2 is running on `5555`, then try the Mac LAN address in `EXPO_PUBLIC_CALCOM_API_BASE_URL`.
- The app opens an old screen or stale bundle: stop Metro, restart with `pnpm exec expo start --dev-client --clear --port 8082`, then relaunch `com.cal.companion`.
- Native build errors after dependency changes: run `pnpm exec expo run:ios --device "iPhone 17" --no-build-cache --port 8082`.
