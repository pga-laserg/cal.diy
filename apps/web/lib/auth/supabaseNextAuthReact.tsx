"use client";

import { ErrorCode } from "@calcom/features/auth/lib/ErrorCode";
import { createBrowserClient } from "@supabase/ssr";
import type { Provider, SupabaseClient } from "@supabase/supabase-js";
import type { Session } from "next-auth";
import type { Context, ReactNode } from "react";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";

type SessionStatus = "authenticated" | "loading" | "unauthenticated";

export type SessionContextValue = {
  data: Session | null;
  status: SessionStatus;
  update: (data?: unknown) => Promise<Session | null>;
};

type SessionProviderProps = {
  basePath?: string;
  baseUrl?: string;
  children: ReactNode;
  refetchInterval?: number;
  refetchOnWindowFocus?: boolean;
  session?: Session | null;
};

type SignInOptions = Record<string, unknown> & {
  callbackUrl?: string;
  email?: string;
  password?: string;
  redirect?: boolean;
};

type SignInResponse = {
  error: string | null;
  ok: boolean;
  status: number;
  url: string | null;
};

type SignOutOptions = {
  callbackUrl?: string;
  redirect?: boolean;
};

const SessionContext: Context<SessionContextValue | undefined> = createContext<
  SessionContextValue | undefined
>(undefined);

let supabaseBrowserClient: SupabaseClient | null = null;

function getSupabaseBrowserClient(): SupabaseClient | null {
  if (supabaseBrowserClient) {
    return supabaseBrowserClient;
  }

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const supabaseKey =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !supabaseKey) {
    return null;
  }

  supabaseBrowserClient = createBrowserClient(supabaseUrl, supabaseKey);
  return supabaseBrowserClient;
}

function getRedirectUrl(callbackUrl?: string | null): string {
  if (callbackUrl) {
    return callbackUrl;
  }

  if (typeof window !== "undefined") {
    return window.location.href;
  }

  return "/";
}

function getOAuthProvider(provider?: string): Provider | null {
  if (provider === "google") {
    return "google";
  }

  if (provider === "azure-ad" || provider === "azure") {
    return "azure";
  }

  return null;
}

async function fetchSession(): Promise<Session | null> {
  const response = await fetch("/api/auth/session", {
    credentials: "include",
    headers: {
      Accept: "application/json",
    },
  });

  if (!response.ok) {
    return null;
  }

  return (await response.json()) as Session | null;
}

export function SessionProvider({ children, session: initialSession }: SessionProviderProps) {
  const [session, setSession] = useState<Session | null>(initialSession ?? null);
  const [status, setStatus] = useState<SessionStatus>(initialSession ? "authenticated" : "loading");
  const mountedRef = useRef(false);

  const refreshSession = useCallback(async () => {
    const nextSession = await fetchSession();

    if (!mountedRef.current) {
      return nextSession;
    }

    setSession(nextSession);
    setStatus(nextSession ? "authenticated" : "unauthenticated");
    return nextSession;
  }, []);

  useEffect(() => {
    mountedRef.current = true;
    refreshSession().catch(() => {
      if (mountedRef.current) {
        setSession(null);
        setStatus("unauthenticated");
      }
    });

    const supabase = getSupabaseBrowserClient();
    const subscription = supabase?.auth.onAuthStateChange(() => {
      refreshSession().catch(() => {
        if (mountedRef.current) {
          setSession(null);
          setStatus("unauthenticated");
        }
      });
    }).data.subscription;

    return () => {
      mountedRef.current = false;
      subscription?.unsubscribe();
    };
  }, [refreshSession]);

  const value = useMemo(
    () => ({
      data: session,
      status,
      update: refreshSession,
    }),
    [refreshSession, session, status]
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession() {
  const value = useContext(SessionContext);

  if (value) {
    return value;
  }

  return {
    data: null,
    status: "unauthenticated" as const,
    update: async () => null,
  };
}

export async function getSession() {
  return fetchSession();
}

export async function getCsrfToken(_options?: unknown) {
  return "supabase";
}

export async function getProviders() {
  return {
    "azure-ad": {
      callbackUrl: "/auth/login",
      id: "azure-ad",
      name: "Microsoft",
      signinUrl: "/auth/login",
      type: "oauth",
    },
    google: {
      callbackUrl: "/auth/login",
      id: "google",
      name: "Google",
      signinUrl: "/auth/login",
      type: "oauth",
    },
  };
}

async function verifyCalCredentials(options: SignInOptions) {
  const response = await fetch("/api/auth/supabase/credentials", {
    body: JSON.stringify({
      backupCode: options.backupCode,
      email: options.email,
      password: options.password,
      totpCode: options.totpCode,
    }),
    credentials: "include",
    headers: {
      "Content-Type": "application/json",
    },
    method: "POST",
  });

  const body = (await response.json().catch(() => null)) as { error?: string | null } | null;

  if (!response.ok || body?.error) {
    return body?.error ?? ErrorCode.InternalServerError;
  }

  return null;
}

export async function signIn<ProviderId extends string = string>(
  provider?: ProviderId,
  options: SignInOptions = {}
): Promise<SignInResponse | undefined> {
  const supabase = getSupabaseBrowserClient();
  const callbackUrl = getRedirectUrl(options.callbackUrl);

  if (!supabase) {
    return {
      error: "Supabase is not configured",
      ok: false,
      status: 500,
      url: null,
    };
  }

  if (provider === "credentials") {
    const email = typeof options.email === "string" ? options.email : "";
    const password = typeof options.password === "string" ? options.password : "";

    const credentialError = await verifyCalCredentials(options);
    if (credentialError) {
      return {
        error: credentialError,
        ok: false,
        status: 401,
        url: null,
      };
    }

    const { error } = await supabase.auth.signInWithPassword({ email, password });

    if (error) {
      return {
        error: ErrorCode.IncorrectEmailPassword,
        ok: false,
        status: error.status || 401,
        url: null,
      };
    }

    if (options.redirect !== false && typeof window !== "undefined") {
      window.location.assign(callbackUrl);
    }

    return {
      error: null,
      ok: true,
      status: 200,
      url: callbackUrl,
    };
  }

  if (provider === "email") {
    const email = typeof options.email === "string" ? options.email : "";
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: callbackUrl,
      },
    });

    return {
      error: error?.message ?? null,
      ok: !error,
      status: error?.status ?? 200,
      url: null,
    };
  }

  const oauthProvider = getOAuthProvider(provider);

  if (oauthProvider) {
    const { data, error } = await supabase.auth.signInWithOAuth({
      provider: oauthProvider,
      options: {
        redirectTo: callbackUrl,
      },
    });

    return {
      error: error?.message ?? null,
      ok: !error,
      status: error?.status ?? 200,
      url: data.url,
    };
  }

  return {
    error: `Unsupported auth provider: ${provider ?? "unknown"}`,
    ok: false,
    status: 400,
    url: null,
  };
}

export async function signOut(options: SignOutOptions = {}) {
  const supabase = getSupabaseBrowserClient();
  await supabase?.auth.signOut();

  const callbackUrl = options.callbackUrl ?? "/auth/login";

  if (options.redirect !== false && typeof window !== "undefined") {
    window.location.assign(callbackUrl);
  }

  return {
    url: callbackUrl,
  };
}
