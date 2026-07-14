import { validPassword } from "@calcom/features/auth/lib/validPassword";
import { hashPassword } from "@calcom/lib/auth/hashPassword";
import { getSupabaseAdminClient, updateSupabasePasswordForCalUser } from "@calcom/lib/server/supabaseAdmin";
import { prisma } from "@calcom/prisma";
import { IdentityProvider } from "@calcom/prisma/enums";
import { TRPCError } from "@trpc/server";
import type { TrpcSessionUser } from "../../../types";
import type { TChangePasswordInputSchema } from "./changePassword.schema";

type ChangePasswordOptions = {
  ctx: {
    user: NonNullable<TrpcSessionUser>;
  };
  input: TChangePasswordInputSchema;
};

export const changePasswordHandler = async ({ input, ctx }: ChangePasswordOptions) => {
  const { oldPassword, newPassword } = input;

  const { user } = ctx;

  if (user.identityProvider !== IdentityProvider.CAL) {
    const userWithPassword = await prisma.user.findUnique({
      where: {
        id: user.id,
      },
      select: {
        password: true,
      },
    });
    if (!userWithPassword?.password?.hash) {
      throw new TRPCError({ code: "FORBIDDEN", message: "THIRD_PARTY_IDENTITY_PROVIDER_ENABLED" });
    }
  }

  const authUserIdRows = await prisma.$queryRaw<Array<{ auth_user_id: string | null }>>`
    select auth_user_id::text
    from public.users
    where id = ${user.id}
    limit 1
  `;
  const authUserId = authUserIdRows[0]?.auth_user_id;

  if (!authUserId) {
    throw new TRPCError({ code: "NOT_FOUND", message: "SUPABASE_AUTH_MAPPING_MISSING" });
  }

  // Supabase remains the credential authority. Checking the supplied password
  // against its hash prevents a stale legacy hash from authorizing a change.
  const { data: authUser, error: authUserError } =
    await getSupabaseAdminClient().auth.admin.getUserById(authUserId);
  if (authUserError || !authUser.user?.email) {
    throw new TRPCError({
      cause: authUserError,
      code: "INTERNAL_SERVER_ERROR",
      message: "SUPABASE_PASSWORD_VERIFICATION_FAILED",
    });
  }

  const supabaseUrl = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const supabasePublishableKey =
    process.env.SUPABASE_PUBLISHABLE_KEY ??
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
    process.env.SUPABASE_ANON_PUBLIC_KEY ??
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !supabasePublishableKey) {
    throw new TRPCError({ code: "INTERNAL_SERVER_ERROR", message: "SUPABASE_PASSWORD_VERIFICATION_FAILED" });
  }

  const { createClient } = await import("@supabase/supabase-js");
  const supabase = createClient(supabaseUrl, supabasePublishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: passwordLogin, error: passwordLoginError } = await supabase.auth.signInWithPassword({
    email: authUser.user.email,
    password: oldPassword,
  });

  if (passwordLoginError || passwordLogin.user?.id !== authUserId) {
    throw new TRPCError({ code: "BAD_REQUEST", message: "incorrect_password" });
  }

  if (oldPassword === newPassword) {
    throw new TRPCError({ code: "BAD_REQUEST", message: "new_password_matches_old_password" });
  }

  if (!validPassword(newPassword)) {
    throw new TRPCError({ code: "BAD_REQUEST", message: "password_hint_min" });
  }

  const hashedPassword = await hashPassword(newPassword);
  try {
    await updateSupabasePasswordForCalUser({ calUserId: user.id, password: newPassword });
  } catch (error) {
    throw new TRPCError({
      cause: error,
      code: "INTERNAL_SERVER_ERROR",
      message: "SUPABASE_PASSWORD_UPDATE_FAILED",
    });
  }

  await prisma.userPassword.upsert({
    where: {
      userId: user.id,
    },
    create: {
      hash: hashedPassword,
      userId: user.id,
    },
    update: {
      hash: hashedPassword,
    },
  });
};
