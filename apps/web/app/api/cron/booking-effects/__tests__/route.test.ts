import { NextRequest } from "next/server";
import { beforeEach, describe, expect, test, vi } from "vitest";

import { BookingEffectsTaskProcessor } from "@calcom/features/bookings/lib/tasker/BookingEffectsTaskProcessor";

vi.mock("next/server", () => ({
  NextRequest: class MockNextRequest {
    url: string;
    method: string;
    nextUrl: { searchParams: URLSearchParams };
    private _headers: Map<string, string>;

    constructor(url: string, options: { method?: string } = {}) {
      this.url = url;
      this.method = options.method || "GET";
      this._headers = new Map();
      this.nextUrl = { searchParams: new URLSearchParams(url.split("?")[1] || "") };
    }

    headers = {
      get: (key: string): string | null => this._headers.get(key.toLowerCase()) || null,
      set: (key: string, value: string): void => {
        this._headers.set(key.toLowerCase(), value);
      },
    };
  },
  NextResponse: {
    json: vi.fn((body, init) => ({
      json: vi.fn().mockResolvedValue(body),
      status: init?.status || 200,
    })),
  },
}));

vi.mock("@calcom/features/bookings/lib/tasker/BookingEffectsTaskProcessor");
vi.mock("app/api/defaultResponderForAppDir", () => ({
  defaultResponderForAppDir: vi.fn((handler) => handler),
}));

const mockBookingEffectsTaskProcessor = vi.mocked(BookingEffectsTaskProcessor);

describe("/api/cron/booking-effects", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.resetModules();
    vi.stubEnv("CRON_API_KEY", "test-cron-key");
    vi.stubEnv("CRON_SECRET", "test-cron-secret");
  });

  test("rejects unauthorized requests", async () => {
    const request = new NextRequest("http://localhost/api/cron/booking-effects");

    const { GET } = await import("../route");
    const response = await GET(request, { params: Promise.resolve({}) });

    expect(response.status).toBe(401);
    const body = await response.json();
    expect(body.message).toBe("Not authenticated");
  });

  test("accepts CRON_API_KEY and runs the processor", async () => {
    const request = new NextRequest("http://localhost/api/cron/booking-effects");
    request.headers.set("authorization", "test-cron-key");

    const mockProcessQueue = vi.fn().mockResolvedValue({
      claimed: 1,
      processedBookings: 1,
      succeeded: 1,
      failed: 0,
    });
    mockBookingEffectsTaskProcessor.prototype.processQueue = mockProcessQueue;

    const { GET, POST } = await import("../route");
    const response = await GET(request, { params: Promise.resolve({}) });

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.ok).toBe(true);
    expect(body.claimed).toBe(1);
    expect(mockProcessQueue).toHaveBeenCalledOnce();

    const postResponse = await POST(request, { params: Promise.resolve({}) });
    expect(postResponse.status).toBe(200);
    expect(mockProcessQueue).toHaveBeenCalledTimes(2);
  });
});
