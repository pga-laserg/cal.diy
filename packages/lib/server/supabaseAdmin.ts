import process from "node:process";
import prisma from "@calcom/prisma";
import { createClient } from "@supabase/supabase-js";

type SupabaseAdminClient = ReturnType<typeof createClient>;

let supabaseAdminClient: SupabaseAdminClient | null = null;

export function getSupabaseAdminClient(): SupabaseAdminClient {
  if (supabaseAdminClient) {
    return supabaseAdminClient;
  }

  const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SUPABASE_SECRET_KEY;

  if (!url || !serviceRoleKey) {
    throw new Error("Supabase admin credentials are not configured");
  }

  supabaseAdminClient = createClient(url, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  return supabaseAdminClient;
}

async function getSupabaseAuthUserId(calUserId: number): Promise<string> {
  const rows = await prisma.$queryRaw<Array<{ auth_user_id: string | null }>>`
    select auth_user_id::text
    from public.users
    where id = ${calUserId}
    limit 1
  `;
  const authUserId = rows[0]?.auth_user_id;

  if (!authUserId) {
    throw new Error("SUPABASE_AUTH_MAPPING_MISSING");
  }

  return authUserId;
}

export async function updateSupabasePasswordForCalUser({
  calUserId,
  password,
}: {
  calUserId: number;
  password: string;
}) {
  const authUserId = await getSupabaseAuthUserId(calUserId);

  const { error } = await getSupabaseAdminClient().auth.admin.updateUserById(authUserId, { password });

  if (error) {
    throw error;
  }
}

export async function syncSupabaseMfaStatusForCalUser(calUserId: number) {
  const authUserId = await getSupabaseAuthUserId(calUserId);
  const { data, error } = await getSupabaseAdminClient().auth.admin.mfa.listFactors({ userId: authUserId });

  if (error) {
    throw error;
  }

  const twoFactorEnabled = data.factors.some((factor) => factor.status === "verified");

  await prisma.user.update({
    where: { id: calUserId },
    data: { twoFactorEnabled },
  });

  return { twoFactorEnabled };
}
