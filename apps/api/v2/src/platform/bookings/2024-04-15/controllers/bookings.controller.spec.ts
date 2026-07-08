jest.mock("@calcom/platform-libraries", () => ({
  handleMarkNoShow: jest.fn(),
}));

import { handleMarkNoShow } from "@calcom/platform-libraries";

import { markNoShowForBooking_2024_04_15 } from "./mark-no-show.adapter";

const mockedHandleMarkNoShow = handleMarkNoShow as jest.MockedFunction<typeof handleMarkNoShow>;

describe("BookingsController_2024_04_15 no-show route adapter", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it("routes the companion-facing mark-absent body through the Cal.diy no-show handler", async () => {
    const body = {
      attendees: [{ email: "guest@example.com", noShow: true }],
      noShowHost: true,
    };
    const response = {
      message: "Booking no-show updated",
      attendees: body.attendees,
      noShowHost: true,
    };
    mockedHandleMarkNoShow.mockResolvedValue(response);

    const result = await markNoShowForBooking_2024_04_15({
      bookingUid: "booking_uid_123",
      body,
      userId: 42,
    });

    expect(mockedHandleMarkNoShow).toHaveBeenCalledWith({
      bookingUid: "booking_uid_123",
      attendees: body.attendees,
      noShowHost: true,
      userId: 42,
    });
    expect(result).toEqual(response);
  });

  it("keeps the legacy mark-no-show body compatible with the same handler", async () => {
    const response = {
      message: "Booking no-show updated",
      attendees: [],
      noShowHost: false,
    };
    mockedHandleMarkNoShow.mockResolvedValue(response);

    const result = await markNoShowForBooking_2024_04_15({
      bookingUid: "booking_uid_456",
      body: { noShowHost: false },
      userId: 43,
    });

    expect(mockedHandleMarkNoShow).toHaveBeenCalledWith({
      bookingUid: "booking_uid_456",
      attendees: undefined,
      noShowHost: false,
      userId: 43,
    });
    expect(result).toEqual(response);
  });
});
