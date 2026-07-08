import { defaultResponderForAppDir } from "app/api/defaultResponderForAppDir";
import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

import { BookingEffectsTaskProcessor } from "@calcom/features/bookings/lib/tasker/BookingEffectsTaskProcessor";

async function handler(request: NextRequest) {
  const apiKey = request.headers.get("authorization") || request.nextUrl.searchParams.get("apiKey");

  if (![process.env.CRON_API_KEY, `Bearer ${process.env.CRON_SECRET}`].includes(`${apiKey}`)) {
    return NextResponse.json({ message: "Not authenticated" }, { status: 401 });
  }

  const processor = new BookingEffectsTaskProcessor();
  const summary = await processor.processQueue();

  return NextResponse.json({
    ok: true,
    ...summary,
  });
}

export const GET = defaultResponderForAppDir(handler);
export const POST = defaultResponderForAppDir(handler);
