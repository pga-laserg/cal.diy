import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { getTranslation } from "@calcom/i18n/server";
import { DEFAULT_SCHEDULE, getAvailabilityFromSchedule } from "@calcom/lib/availability";
import { isPrismaError } from "@calcom/lib/server/getServerErrorFromUnknown";
import prisma from "@calcom/prisma";
import type { Prisma } from "@calcom/prisma/client";
import type { CreationSource, IdentityProvider, UserPermissionRole } from "@calcom/prisma/enums";
import { createClient } from "@supabase/supabase-js";

type SupabaseBackedCalUserInput = {
  email: string;
  emailVerified?: Date | null;
  hashedPassword?: string;
  identityProvider: IdentityProvider;
  locked?: boolean;
  locale?: string;
  metadata?: Prisma.InputJsonValue;
  name?: string | null;
  organizationId?: number | null;
  password: string;
  role?: UserPermissionRole;
  username: string | null;
  creationSource: CreationSource;
};

type SupabaseAdminConfig = {
  serviceRoleKey: string;
  url: string;
};

function parseEnvValue(rawValue: string): string {
  const value = rawValue.trim();

  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1);
  }

  return value;
}

function loadEnvFile(filePath: string): void {
  if (!fs.existsSync(filePath)) {
    return;
  }

  const content = fs.readFileSync(filePath, "utf8");

  for (const line of content.split(/\r?\n/)) {
    const trimmedLine = line.trim();

    if (!trimmedLine || trimmedLine.startsWith("#") || trimmedLine.startsWith("//")) {
      continue;
    }

    const separatorIndex = trimmedLine.indexOf("=");

    if (separatorIndex === -1) {
      continue;
    }

    const key = trimmedLine
      .slice(0, separatorIndex)
      .replace(/^export\s+/, "")
      .trim();
    const value = parseEnvValue(trimmedLine.slice(separatorIndex + 1));

    if (key && process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

function loadLocalSupabaseEnv(): void {
  if (process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SECRET_KEY) {
    return;
  }

  const cwd = process.cwd();
  const candidates = [
    path.join(cwd, ".env.local"),
    path.join(cwd, "env.local"),
    path.join(cwd, "../.env.local"),
    path.join(cwd, "../env.local"),
    path.join(cwd, ".env"),
  ];

  for (const candidate of candidates) {
    loadEnvFile(candidate);
  }
}

function getSupabaseAdminConfig(): SupabaseAdminConfig | null {
  loadLocalSupabaseEnv();

  const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SUPABASE_SECRET_KEY;

  if (!url || !serviceRoleKey) {
    return null;
  }

  return { serviceRoleKey, url };
}

function createSupabaseAdminClient() {
  const config = getSupabaseAdminConfig();

  if (!config) {
    return null;
  }

  return createClient(config.url, config.serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}

async function waitForCalUser({ authUserId, email }: { authUserId: string; email: string }) {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const rows = await prisma.$queryRaw<Array<{ id: bigint | number }>>`
      select id
      from public.users
      where auth_user_id = cast(${authUserId} as uuid)
      limit 1
    `;

    if (rows[0]) {
      return Number(rows[0].id);
    }

    const userByEmail = await prisma.user.findUnique({
      where: { email },
      select: { id: true },
    });

    if (userByEmail) {
      return userByEmail.id;
    }

    await new Promise((resolve) => setTimeout(resolve, 150));
  }

  return null;
}

async function ensureDefaultSchedule(userId: number) {
  try {
    const existingSchedule = await prisma.schedule.findFirst({
      where: { userId },
      select: { id: true },
    });

    if (existingSchedule) {
      return existingSchedule;
    }

    const t = await getTranslation("en", "common");
    const availability = getAvailabilityFromSchedule(DEFAULT_SCHEDULE);

    return prisma.schedule.create({
      data: {
        name: t("default_schedule_name"),
        userId,
        availability: {
          createMany: {
            data: availability.map((schedule) => ({
              days: schedule.days,
              endTime: schedule.endTime,
              startTime: schedule.startTime,
            })),
          },
        },
      },
      select: { id: true },
    });
  } catch (error) {
    if (!isPrismaError(error) || error.code !== "P2021") {
      throw error;
    }

    console.warn("Schedule tables missing during Supabase user provisioning; skipping default schedule creation.", {
      userId,
      error,
    });
    return null;
  }
}

export async function createSupabaseBackedCalUser(input: SupabaseBackedCalUserInput) {
  const supabaseAdmin = createSupabaseAdminClient();

  if (!supabaseAdmin) {
    throw new Error("Supabase admin client is not configured");
  }

  const { data, error } = await supabaseAdmin.auth.admin.createUser({
    email: input.email,
    email_confirm: true,
    password: input.password,
    user_metadata: {
      full_name: input.name ?? undefined,
      name: input.name ?? undefined,
      username: input.username ?? undefined,
    },
  });

  if (error) {
    throw error;
  }

  const authUserId = data.user?.id;

  if (!authUserId) {
    throw new Error("Supabase Auth did not return a user id");
  }

  try {
    const userId = await waitForCalUser({ authUserId, email: input.email });

    if (!userId) {
      throw new Error("Supabase Auth user was created but no mapped Cal user was found");
    }

    await ensureDefaultSchedule(userId);

    return prisma.user.update({
      where: { id: userId },
      data: {
        emailVerified: input.emailVerified,
        locale: input.locale,
        metadata: input.metadata,
        name: input.name,
        username: input.username,
      },
      select: { id: true },
    });
  } catch (error) {
    await supabaseAdmin.auth.admin.deleteUser(authUserId);
    throw error;
  }
}

export function isSupabaseAuthUserConflict(error: unknown): boolean {
  if (!error || typeof error !== "object") {
    return false;
  }

  const maybeAuthError = error as { message?: unknown; status?: unknown };
  const message = typeof maybeAuthError.message === "string" ? maybeAuthError.message.toLowerCase() : "";

  return (
    maybeAuthError.status === 422 ||
    message.includes("already registered") ||
    message.includes("already exists") ||
    message.includes("duplicate key")
  );
}
