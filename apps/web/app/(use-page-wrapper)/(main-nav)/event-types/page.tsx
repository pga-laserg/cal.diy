import { getServerSession } from "@calcom/features/auth/lib/getServerSession";
import { checkOnboardingRedirect } from "@calcom/features/auth/lib/onboardingUtils";
import { getTeamsFiltersFromQuery } from "@calcom/features/filters/lib/getTeamsFiltersFromQuery";
import { eventTypesRouter } from "@calcom/trpc/server/routers/viewer/eventTypes/_router";
import { buildLegacyRequest } from "@lib/buildLegacyCtx";
import { createRouterCaller, getTRPCContext } from "app/_trpc/context";
import type { PageProps } from "app/_types";
import { _generateMetadata } from "app/_utils";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import type { ReactElement } from "react";
import { EventTypesWrapper } from "./EventTypesWrapper";

const Page = async ({ searchParams }: PageProps): Promise<ReactElement> => {
  const _searchParams = await searchParams;
  const _headers = await headers();
  const _cookies = await cookies();

  const session = await getServerSession({
    req: buildLegacyRequest(_headers, _cookies),
  });
  if (!session?.user?.id) {
    return redirect("/auth/login");
  }

  // Completed users cannot be redirected by the onboarding flow. Avoid its
  // extra user and feature-flag queries on every authenticated dashboard load.
  if (!session.user.completedOnboarding) {
    const organizationId = session.user.profile?.organizationId ?? null;
    const onboardingPath = await checkOnboardingRedirect(session.user.id, {
      checkEmailVerification: true,
      organizationId,
    });
    if (onboardingPath) {
      return redirect(onboardingPath);
    }
  }

  const filters = getTeamsFiltersFromQuery(_searchParams);
  // This is authenticated, user-scoped data. Fetch it per request so changes made
  // in the dashboard cannot remain hidden behind a shared server cache.
  const eventTypesCaller = await createRouterCaller(
    eventTypesRouter,
    await getTRPCContext(_headers, _cookies)
  );
  const userEventGroupsData = await eventTypesCaller.getUserEventGroups({ filters });

  return <EventTypesWrapper userEventGroupsData={userEventGroupsData} user={session.user} />;
};

export const generateMetadata = async (): Promise<ReturnType<typeof _generateMetadata>> =>
  await _generateMetadata(
    (t) => t("event_types_page_title"),
    (t) => t("event_types_page_subtitle"),
    undefined,
    undefined,
    "/event-types"
  );

export default Page;
