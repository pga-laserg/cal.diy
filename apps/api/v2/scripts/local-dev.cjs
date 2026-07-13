const fs = require("node:fs");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const dotenv = require("dotenv");

// The shared root file holds AgendaCon/Supabase values; API v2 keeps its database defaults locally.
dotenv.config({ path: path.resolve(__dirname, "../../../../.env") });
dotenv.config({ path: path.resolve(__dirname, "../.env") });
dotenv.config({ path: path.resolve(__dirname, "../../../../../companion/apps/mobile/.env.local") });

const heapOption = "--max_old_space_size=8192";
const nodeOptions = process.env.NODE_OPTIONS || "";

// The fork keeps the primary connection in the shared root file. API v2 still
// expects separate read/write URLs, so local development uses that connection
// for both unless a deployment provides explicit pool URLs.
process.env.DATABASE_READ_URL ||= process.env.DATABASE_URL;
process.env.DATABASE_WRITE_URL ||= process.env.DATABASE_URL;
process.env.SUPABASE_URL ||= process.env.EXPO_PUBLIC_SUPABASE_URL;
process.env.SUPABASE_PUBLISHABLE_KEY ||= process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
// Event-type responses build public links from NEXT_PUBLIC_WEBAPP_URL. Keep it
// aligned with the Companion deployment instead of leaking the web app's stale
// localhost default into native cards, copy actions, and previews.
if (process.env.EXPO_PUBLIC_CALCOM_WEB_BASE_URL) {
  process.env.NEXT_PUBLIC_WEBAPP_URL = process.env.EXPO_PUBLIC_CALCOM_WEB_BASE_URL;
  process.env.WEB_APP_URL = process.env.EXPO_PUBLIC_CALCOM_WEB_BASE_URL;
}
process.env.REDIS_URL ||= "redis://127.0.0.1:6379";
process.env.STRIPE_API_KEY ||= "sk_test_local";
process.env.STRIPE_WEBHOOK_SECRET ||= "whsec_local";

const cwd = path.resolve(__dirname, "..");
const yarnCommand = process.env.YARN_BIN || "corepack";
const yarnArgs = yarnCommand === "corepack" ? ["yarn"] : [];
const env = {
  ...process.env,
  API_PORT: process.env.API_PORT || "5555",
  API_URL: process.env.API_URL || "http://localhost",
  NODE_ENV: process.env.NODE_ENV || "development",
  NODE_OPTIONS: nodeOptions.includes(heapOption) ? nodeOptions : `${nodeOptions} ${heapOption}`.trim(),
};

const platformBuilds = [
  "../../../packages/platform/constants/dist/index.js",
  "../../../packages/platform/enums/dist/index.js",
  "../../../packages/platform/utils/dist/index.js",
  "../../../packages/platform/types/dist/index.js",
  "../../../packages/platform/libraries/dist/index.cjs",
];
const needsPlatformBuild = platformBuilds.some((file) => !fs.existsSync(path.resolve(cwd, file)));
const commands = needsPlatformBuild ? [["dev:build"], ["copy-swagger-module"]] : [["copy-swagger-module"]];

for (const command of commands) {
  const result = spawnSync(yarnCommand, [...yarnArgs, ...command], { cwd, env, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

const child = spawn(yarnCommand, [...yarnArgs, "start"], { cwd, env, stdio: "inherit" });

child.on("exit", (code) => process.exit(code ?? 1));
