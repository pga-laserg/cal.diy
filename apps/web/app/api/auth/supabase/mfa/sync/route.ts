import { getServerSession } from "@calcom/features/auth/lib/getServerSession";
import { syncSupabaseMfaStatusForCalUser } from "@calcom/lib/server/supabaseAdmin";
import { cookies, headers } from "next/headers";
import { NextResponse } from "next/server";

import { buildLegacyRequest } from "@lib/buildLegacyCtx";

export async function POST() {
  const session = await getServerSession({ req: buildLegacyRequest(await headers(), await cookies()) });

  if (!session?.user?.id) {
    return NextResponse.json({ message: "Not authenticated" }, { status: 401 });
  }

  try {
    return NextResponse.json(await syncSupabaseMfaStatusForCalUser(session.user.id));
  } catch (error) {
    console.error("Unable to synchronize Supabase MFA status", error);
    return NextResponse.json({ message: "Unable to synchronize MFA status" }, { status: 500 });
  }
}
