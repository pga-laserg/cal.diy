import { Injectable, UnauthorizedException } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import type { AppConfig } from "@/config/type";

@Injectable()
export class SupabaseAuthService {
  private readonly supabaseUrl: string | undefined;
  private readonly client: SupabaseClient | null;

  constructor(config: ConfigService<AppConfig, true>) {
    const url = config.get("supabase.url", { infer: true });
    const publishableKey = config.get("supabase.publishableKey", { infer: true });
    this.supabaseUrl = url?.replace(/\/$/, "");

    this.client =
      url && publishableKey
        ? createClient(url, publishableKey, {
            auth: {
              autoRefreshToken: false,
              detectSessionInUrl: false,
              persistSession: false,
            },
          })
        : null;
  }

  /**
   * Route Supabase JWTs before legacy token decoders run. This only inspects
   * the untrusted issuer claim; auth.getUser below remains the authority.
   */
  isSupabaseAccessToken(accessToken: string): boolean {
    if (!this.supabaseUrl) return false;

    const payload = accessToken.split(".")[1];
    if (!payload) return false;

    try {
      const claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as { iss?: unknown };
      return claims.iss === `${this.supabaseUrl}/auth/v1`;
    } catch {
      return false;
    }
  }

  async getAuthenticatedUser(accessToken: string) {
    if (!this.client) {
      throw new UnauthorizedException("Supabase authentication is not configured for this API instance.");
    }

    const { data, error } = await this.client.auth.getUser(accessToken);
    if (error || !data.user?.id) {
      throw new UnauthorizedException("Supabase access token is invalid or expired.");
    }

    return data.user;
  }
}
