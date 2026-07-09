import process from "node:process";
import "dotenv/config";

const DEFAULT_REDIRECT_URI = "expo-wxt-app://oauth/callback";
let prisma: Awaited<typeof import("@calcom/prisma")>["prisma"] | undefined;

function getEnv(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value || undefined;
}

async function main(): Promise<void> {
  const clientId = getEnv("SEED_COMPANION_OAUTH_CLIENT_ID") || getEnv("COMPANION_OAUTH_CLIENT_ID");

  if (!clientId) {
    throw new Error(
      "Set SEED_COMPANION_OAUTH_CLIENT_ID or COMPANION_OAUTH_CLIENT_ID before running this script."
    );
  }

  const redirectUri = getEnv("SEED_COMPANION_OAUTH_REDIRECT_URI") || DEFAULT_REDIRECT_URI;
  const name = getEnv("SEED_COMPANION_OAUTH_CLIENT_NAME") || "AgendaCon Companion";
  const websiteUrl = getEnv("SEED_COMPANION_OAUTH_WEBSITE_URL") || getEnv("NEXT_PUBLIC_WEBAPP_URL");
  const ownerEmail = getEnv("SEED_COMPANION_OAUTH_OWNER_EMAIL");
  const isTrusted = getEnv("SEED_COMPANION_OAUTH_IS_TRUSTED") === "true";
  const dryRun = process.argv.includes("--dry-run") || getEnv("DRY_RUN") === "true";

  if (!websiteUrl) {
    throw new Error(
      "Set SEED_COMPANION_OAUTH_WEBSITE_URL or NEXT_PUBLIC_WEBAPP_URL before running this script."
    );
  }

  if (dryRun) {
    console.log("Companion OAuth client dry run:");
    console.log(`  clientId: ${clientId}`);
    console.log(`  redirectUri: ${redirectUri}`);
    console.log(`  websiteUrl: ${websiteUrl}`);
    console.log(`  ownerEmail: ${ownerEmail || "(first admin user)"}`);
    console.log(`  isTrusted: ${isTrusted}`);
    return;
  }

  const prismaModule = await import("@calcom/prisma");
  prisma = prismaModule.prisma;

  let owner: { id: number; email: string } | null;
  if (ownerEmail) {
    owner = await prisma.user.findUnique({ where: { email: ownerEmail } });
  } else {
    owner = await prisma.user.findFirst({
      where: { role: "ADMIN" },
      orderBy: { id: "asc" },
    });
  }

  if (!owner) {
    let message = "No admin user found. Set SEED_COMPANION_OAUTH_OWNER_EMAIL to an existing user.";
    if (ownerEmail) {
      message = `No user found with email ${ownerEmail}.`;
    }
    throw new Error(message);
  }

  await prisma.oAuthClient.upsert({
    where: { clientId },
    create: {
      clientId,
      clientType: "PUBLIC",
      isTrusted,
      name,
      purpose: "AgendaCon Companion mobile app OAuth",
      redirectUri,
      userId: owner.id,
      websiteUrl,
    },
    update: {
      clientType: "PUBLIC",
      isTrusted,
      name,
      purpose: "AgendaCon Companion mobile app OAuth",
      redirectUri,
      userId: owner.id,
      websiteUrl,
    },
  });

  console.log(`Upserted Companion OAuth client '${clientId}' for ${owner.email}.`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma?.$disconnect();
  });
