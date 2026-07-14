import { expect } from "@playwright/test";

import { createSupabaseBackedCalUser } from "@lib/auth/supabaseUserProvisioning";
import { getSupabaseAdminClient } from "@calcom/lib/server/supabaseAdmin";
import { prisma } from "@calcom/prisma";
import { CreationSource, IdentityProvider } from "@calcom/prisma/enums";

import { login } from "./fixtures/users";
import { test } from "./lib/fixtures";

const settingsRoutes = [
  "/settings/my-account/profile",
  "/settings/my-account/general",
  "/settings/my-account/calendars",
  "/settings/my-account/conferencing",
  "/settings/my-account/appearance",
  "/settings/my-account/out-of-office",
  "/settings/my-account/push-notifications",
  "/settings/security/password",
  "/settings/security/two-factor-auth",
  "/settings/developer/webhooks",
  "/settings/developer/oauth",
  "/settings/developer/api-keys",
] as const;

test.describe("Settings navigation", () => {
  test("every visible settings menu reaches a ready page without a runtime error", async ({ page }) => {
    const username = `settings-nav-${Date.now()}`;
    const email = `${username}@example.com`;
    const password = "SettingsNav1!";
    const user = await createSupabaseBackedCalUser({
      email,
      password,
      username,
      name: "Settings navigation",
      completedOnboarding: true,
      creationSource: CreationSource.WEBAPP,
      identityProvider: IdentityProvider.CAL,
    });
    const authUser = await prisma.$queryRaw<Array<{ auth_user_id: string | null }>>`
      select auth_user_id::text
      from public.users
      where id = ${user.id}
      limit 1
    `;

    try {
      expect(authUser[0]?.auth_user_id).toBe(user.authUserId);

      await login({ email, password, username }, page);
      await expect
        .poll(
          () => page.context().cookies().then((cookies) => cookies.some((cookie) => cookie.name.includes("-auth-token"))),
          { timeout: 30_000 }
        )
        .toBe(true);
      await expect
        .poll(
          () =>
            page.evaluate(async () => {
              const response = await fetch("/api/auth/session", { credentials: "include" });
              const session = response.ok ? await response.json() : null;
              return session?.user?.id ? String(session.user.id) : null;
            }),
          { timeout: 30_000 }
        )
        .toBe(String(user.id));

      const pageErrors: Error[] = [];
      page.on("pageerror", (error) => pageErrors.push(error));

      await page.goto(settingsRoutes[0]);
      await expect(page.getByTestId("settings-page-ready")).toHaveAttribute(
        "data-pathname",
        settingsRoutes[0]
      );

      for (const route of settingsRoutes.slice(1)) {
        await page.getByTestId(`vertical-tab-${route}`).click();
        await expect(page).toHaveURL(new RegExp(`${route}$`));
        await expect(page.getByTestId("settings-page-ready")).toHaveAttribute("data-pathname", route);
      }

      expect(pageErrors).toEqual([]);
    } finally {
      await getSupabaseAdminClient().auth.admin.deleteUser(user.authUserId);
    }
  });
});
