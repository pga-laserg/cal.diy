const path = require("node:path");
const dotenv = require("dotenv");

dotenv.config({ path: path.resolve(__dirname, "../../../../.env") });
dotenv.config({ path: path.resolve(__dirname, "../.env") });

const accessToken = process.env.SUPABASE_AUTH_SMOKE_TOKEN;
if (!accessToken) {
  console.error("SUPABASE_AUTH_SMOKE_TOKEN is required. The script never stores or prints it.");
  process.exit(1);
}

if (accessToken.split(".").length !== 3) {
  console.error(
    "SUPABASE_AUTH_SMOKE_TOKEN must be a Supabase Auth user session JWT, not a Supabase personal access token."
  );
  process.exit(1);
}

const apiOrigin = (process.env.SUPABASE_AUTH_SMOKE_API_URL || "http://127.0.0.1:5555/v2").replace(/\/$/, "");
const checks = [
  { name: "profile", path: "/me", version: "2024-08-13" },
  { name: "event types", path: "/event-types?sortCreatedAt=desc", version: "2024-06-14" },
  { name: "schedules", path: "/schedules", version: "2024-06-11" },
  { name: "bookings", path: "/bookings?status=upcoming&limit=1", version: "2024-08-13" },
  { name: "conferencing", path: "/conferencing", version: "2024-08-13" },
  { name: "calendars", path: "/calendars", version: "2024-08-13" },
];

async function run() {
  let failed = false;

  for (const check of checks) {
    try {
      const response = await fetch(`${apiOrigin}${check.path}`, {
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "cal-api-version": check.version,
        },
      });
      const passed = response.ok;
      console.log(`${passed ? "PASS" : "FAIL"} ${check.name}: ${response.status}`);
      failed ||= !passed;
    } catch {
      console.log(`FAIL ${check.name}: request error`);
      failed = true;
    }
  }

  process.exitCode = failed ? 1 : 0;
}

run();
