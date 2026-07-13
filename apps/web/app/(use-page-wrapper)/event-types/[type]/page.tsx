import { getServerSession } from "@calcom/features/auth/lib/getServerSession";
import { eventTypesRouter } from "@calcom/trpc/server/routers/viewer/eventTypes/_router";
import { EventTypeWebWrapper } from "@calcom/web/modules/event-types/components/EventTypeWebWrapper";
import { buildLegacyRequest } from "@lib/buildLegacyCtx";
import { createRouterCaller, getTRPCContext } from "app/_trpc/context";
import type { PageProps } from "app/_types";
import { _generateMetadata } from "app/_utils";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { z } from "zod";

const querySchema = z.object({
  type: z
    .string()
    .refine((val) => !Number.isNaN(Number(val)), {
      message: "event-type id must be a string that can be cast to a number",
    })
    .transform((val) => Number(val)),
});

export const generateMetadata = async () => {
  return await _generateMetadata(
    (t) => `${t("event_type")}`,
    () => "",
    undefined,
    undefined,
    "/event-types"
  );
};

const ServerPage = async ({ params }: PageProps) => {
  const session = await getServerSession({ req: buildLegacyRequest(await headers(), await cookies()) });
  if (!session?.user?.id) {
    return redirect("/auth/login");
  }

  const parsed = querySchema.safeParse(await params);
  if (!parsed.success) {
    throw new Error("Invalid Event Type id");
  }
  const eventTypeId = parsed.data.type;
  const _headers = await headers();
  const _cookies = await cookies();

  // Event type settings are edited from this page, so always read the current
  // user-scoped record instead of serving a stale server-cache entry.
  const caller = await createRouterCaller(eventTypesRouter, await getTRPCContext(_headers, _cookies));
  const data = await caller.get({ id: eventTypeId });
  if (!data?.eventType) {
    throw new Error("This event type does not exist");
  }

  // Fetch permissions for the event type's team
  const permissions = {
    eventTypes: { canRead: true, canCreate: true, canUpdate: true, canDelete: true },
  };

  return <EventTypeWebWrapper data={data} id={eventTypeId} permissions={permissions} />;
};

export default ServerPage;
