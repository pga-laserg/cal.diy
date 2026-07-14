import { describe, expect, it, vi } from "vitest";

vi.mock("next-auth/jwt", () => ({ getToken: vi.fn() }));

import { getToken } from "next-auth/jwt";
import { getLocale } from "./getLocale";

describe("getLocale", () => {
  it("prefers the locale selected in General settings over browser language", async () => {
    vi.mocked(getToken).mockResolvedValue(null);

    const locale = await getLocale({
      cookies: { calNewLocale: "es-419" },
      headers: { "accept-language": "en-US,en;q=0.9" },
    } as never);

    expect(locale).toBe("es");
  });

  it("falls back safely when a saved locale is unsupported", async () => {
    vi.mocked(getToken).mockResolvedValue(null);

    const locale = await getLocale({
      cookies: { calNewLocale: "not-a-locale" },
      headers: { "accept-language": "en-US,en;q=0.9" },
    } as never);

    expect(locale).toBe("en");
  });
});
