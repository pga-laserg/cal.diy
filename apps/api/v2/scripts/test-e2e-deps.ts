import { execSync } from "node:child_process";
import path from "node:path";

function hasCommand(command: string) {
  try {
    execSync(`${command} --version`, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function composeCommand() {
  if (hasCommand("docker")) {
    try {
      execSync("docker compose version", { stdio: "ignore" });
      return "docker compose";
    } catch {
      // Fall through to docker-compose.
    }
  }

  if (hasCommand("docker-compose")) {
    return "docker-compose";
  }

  throw new Error(
    "Docker is required for API v2 e2e tests. Install Docker Desktop or make docker/docker-compose visible on PATH."
  );
}

try {
  const root = path.resolve(__dirname, "../../../..");
  const compose = composeCommand();
  const postgresCompose = path.join(root, "packages/prisma/docker-compose.yml");
  const redisCompose = path.join(root, "apps/api/v2/docker-compose.yaml");

  execSync(`${compose} -f "${postgresCompose}" up -d`, { cwd: root, stdio: "inherit" });
  execSync(`${compose} -f "${redisCompose}" up -d`, { cwd: root, stdio: "inherit" });
  execSync("yarn workspace @calcom/prisma db-deploy", { cwd: root, stdio: "inherit" });
} catch (error) {
  console.error(error instanceof Error ? error.message : "Unable to start API v2 e2e dependencies.");
  process.exit(1);
}
