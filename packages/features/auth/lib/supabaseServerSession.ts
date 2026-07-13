import process from "node:process";
import prisma from "@calcom/prisma";
import { createServerClient } from "@supabase/ssr";
import type { User as SupabaseUser } from "@supabase/supabase-js";
import type { GetServerSidePropsContext, NextApiRequest } from "next";

type RequestLike = (NextApiRequest | GetServerSidePropsContext["req"]) & {
  cookies?: Partial<Record<string, string>>;
};

type SupabaseSessionIdentity = {
  cacheKey: string;
  calUserId: number;
  email: string;
  expires: string;
  supabaseUserId: string;
};

type SupabaseConfig = {
  publishableKey: string;
  url: string;
};

function getSupabaseConfig(): SupabaseConfig | null {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? process.env.SUPABASE_URL;
  const publishableKey =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
    process.env.SUPABASE_PUBLISHABLE_KEY ??
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ??
    process.env.SUPABASE_ANON_PUBLIC_KEY ??
    process.env.SUPABASE_ANON_KEY;

  if (!url || !publishableKey) {
    return null;
  }

  return { publishableKey, url };
}

function parseCookieHeader(cookieHeader: string | undefined): Record<string, string> {
  if (!cookieHeader) {
    return {};
  }

  return cookieHeader.split(";").reduce<Record<string, string>>((cookies, part) => {
    const [rawName, ...rawValue] = part.trim().split("=");
    const name = rawName?.trim();

    if (!name) {
      return cookies;
    }

    cookies[name] = decodeURIComponent(rawValue.join("="));
    return cookies;
  }, {});
}

function getRequestCookies(req: RequestLike): Record<string, string | undefined> {
  let headerCookies: Record<string, string> = {};
  if (typeof req.headers.cookie === "string") {
    headerCookies = parseCookieHeader(req.headers.cookie);
  }

  return {
    ...headerCookies,
    ...(req.cookies ?? {}),
  };
}

async function resolveCalUserId(supabaseUser: SupabaseUser): Promise<number | null> {
  try {
    const rows = await prisma.$queryRaw<Array<{ id: bigint | number }>>`
      select id
      from public.users
      where auth_user_id = cast(${supabaseUser.id} as uuid)
      limit 1
    `;
    const id = Number(rows[0]?.id);

    if (id > 0) {
      return id;
    }
  } catch {
    // A missing mapping is an authentication provisioning failure, not a reason
    // to attach the Supabase identity to a user by email.
  }
  return null;
}

export async function getSupabaseSessionIdentity(req: RequestLike): Promise<SupabaseSessionIdentity | null> {
  const config = getSupabaseConfig();

  if (!config) {
    return null;
  }

  const cookies = getRequestCookies(req);
  const supabase = createServerClient(config.url, config.publishableKey, {
    cookies: {
      getAll(): Array<{ name: string; value: string }> {
        return Object.entries(cookies).map(([name, value]) => ({ name, value: value ?? "" }));
      },
      setAll(): void {
        // This compatibility bridge only reads existing cookies. Next middleware can refresh them later.
      },
    },
  });

  const { data: userData, error } = await supabase.auth.getUser();
  const supabaseUser = userData.user;

  if (error || !supabaseUser?.id || !supabaseUser.email) {
    return null;
  }

  const calUserId = await resolveCalUserId(supabaseUser);

  if (!calUserId) {
    return null;
  }

  const { data: sessionData } = await supabase.auth.getSession();
  let expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  if (sessionData.session?.expires_at) {
    expiresAt = new Date(sessionData.session.expires_at * 1000).toISOString();
  }

  return {
    cacheKey: `supabase:${supabaseUser.id}:${sessionData.session?.expires_at ?? "session"}`,
    calUserId,
    email: supabaseUser.email,
    expires: expiresAt,
    supabaseUserId: supabaseUser.id,
  };
}

export type { SupabaseSessionIdentity };
