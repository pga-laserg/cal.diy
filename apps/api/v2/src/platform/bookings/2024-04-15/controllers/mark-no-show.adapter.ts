import { handleMarkNoShow } from "@calcom/platform-libraries";

import type { MarkNoShowInput_2024_04_15 } from "@/platform/bookings/2024-04-15/inputs/mark-no-show.input";

export const markNoShowForBooking_2024_04_15 = async ({
  bookingUid,
  body,
  userId,
}: {
  bookingUid: string;
  body: MarkNoShowInput_2024_04_15;
  userId: number;
}) =>
  handleMarkNoShow({
    bookingUid,
    attendees: body.attendees,
    noShowHost: body.noShowHost,
    userId,
  });
