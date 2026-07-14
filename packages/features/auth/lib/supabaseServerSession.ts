import { createHash } from "node:crypto";
import process from "node:process";
import prisma from "@calcom/prisma";
import { userMetadata } from "@calcom/prisma/zod-utils";
import { createServerClient } from "@supabase/ssr";
import type { User as SupabaseUser } from "@supabase/supabase-js";
import { LRUCache } from "lru-cache";
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

type CalUserIdentity = {
  id: number;
  sessionTimeout?: number;
};

export function invalidateSupabaseSessionIdentitiesForUser(userId: number): void {
  for (const [cacheKey, identity] of SESSION_IDENTITY_CACHE) {
    if (identity.calUserId === userId) {
      SESSION_IDENTITY_CACHE.delete(cacheKey);
    }
  }
}

// `getUser()` validates the access token with Supabase over the network. A single
// dashboard render can invoke it through several tRPC procedures, so cache the
// resolved identity briefly without retaining the raw session cookie.
const SESSION_IDENTITY_CACHE: LRUCache<string, SupabaseSessionIdentity> = new LRUCache({
  max: 1_000,
  ttl: 30_000,
});

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

function getSessionCacheKey(cookies: Record<string, string | undefined>): string | null {
  const authCookieEntries = Object.entries(cookies)
    .filter(([name, value]) => name.includes("-auth-token") && value)
    .sort(([left], [right]) => left.localeCompare(right));

  if (authCookieEntries.length === 0) {
    return null;
  }

  return createHash("sha256").update(JSON.stringify(authCookieEntries)).digest("hex");
}

async function resolveCalUserIdentity(supabaseUser: SupabaseUser): Promise<CalUserIdentity | null> {
  try {
    const rows = await prisma.$queryRaw<Array<{ id: bigint | number; metadata: unknown }>>`
      select id, metadata
      from public.users
      where auth_user_id = cast(${supabaseUser.id} as uuid)
      limit 1
    `;
    const id = Number(rows[0]?.id);

    if (id > 0) {
      const metadata = userMetadata.safeParse(rows[0]?.metadata);
      return { id, sessionTimeout: metadata.success ? metadata.data.sessionTimeout : undefined };
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
  const cacheKey = getSessionCacheKey(cookies);

  if (!cacheKey) {
    return null;
  }

  const cachedIdentity = SESSION_IDENTITY_CACHE.get(cacheKey);
  if (cachedIdentity) {
    return cachedIdentity;
  }

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

  const calUser = await resolveCalUserIdentity(supabaseUser);

  if (!calUser) {
    return null;
  }

  const sessionTimeoutMs = calUser.sessionTimeout ? calUser.sessionTimeout * 60 * 1000 : null;
  const signedInAt = supabaseUser.last_sign_in_at ? new Date(supabaseUser.last_sign_in_at).getTime() : NaN;
  if (sessionTimeoutMs && Number.isFinite(signedInAt) && Date.now() >= signedInAt + sessionTimeoutMs) {
    return null;
  }

  const { data: sessionData } = await supabase.auth.getSession();
  let expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  if (sessionData.session?.expires_at) {
    expiresAt = new Date(sessionData.session.expires_at * 1000).toISOString();
  }

  const identity = {
    cacheKey: `supabase:${supabaseUser.id}:${sessionData.session?.expires_at ?? "session"}`,
    calUserId: calUser.id,
    email: supabaseUser.email,
    expires: expiresAt,
    supabaseUserId: supabaseUser.id,
  };

  SESSION_IDENTITY_CACHE.set(cacheKey, identity);

  return identity;
}

export type { SupabaseSessionIdentity };
