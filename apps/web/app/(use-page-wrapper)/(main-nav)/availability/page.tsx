import { getServerSession } from "@calcom/features/auth/lib/getServerSession";
import { getScheduleListItemData } from "@calcom/lib/schedules/transformers/getScheduleListItemData";
import { availabilityRouter } from "@calcom/trpc/server/routers/viewer/availability/_router";
import { buildLegacyRequest } from "@lib/buildLegacyCtx";
import { createRouterCaller, getTRPCContext } from "app/_trpc/context";
import { _generateMetadata, getTranslate } from "app/_utils";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { AvailabilityCTA, AvailabilityList } from "~/availability/availability-view";
import { ShellMainAppDir } from "../ShellMainAppDir";

export const generateMetadata = async () => {
  return await _generateMetadata(
    (t) => t("availability"),
    (t) => t("configure_availability"),
    undefined,
    undefined,
    "/availability"
  );
};

const Page = async () => {
  const t = await getTranslate();
  const _headers = await headers();
  const _cookies = await cookies();
  const session = await getServerSession({ req: buildLegacyRequest(_headers, _cookies) });
  if (!session?.user?.id) {
    return redirect("/auth/login");
  }

  // Schedules are edited directly from this dashboard. Avoid serving stale
  // user-scoped rows after a successful create, update, or delete.
  const availabilityCaller = await createRouterCaller(
    availabilityRouter,
    await getTRPCContext(_headers, _cookies)
  );
  const availabilitiesData = await availabilityCaller.list();

  // Transform the data to ensure startTime, endTime, and date are Date objects
  // when the schedule data crosses the server/client boundary.
  const availabilities = {
    ...availabilitiesData,
    schedules: availabilitiesData.schedules.map((schedule) => getScheduleListItemData(schedule)),
  };

  return (
    <ShellMainAppDir
      heading={t("availability")}
      subtitle={t("configure_availability")}
      CTA={<AvailabilityCTA />}>
      <AvailabilityList availabilities={availabilities ?? { schedules: [] }} />
    </ShellMainAppDir>
  );
};

export default Page;
