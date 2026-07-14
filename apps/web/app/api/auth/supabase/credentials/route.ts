import { ErrorCode } from "@calcom/features/auth/lib/ErrorCode";
import prisma from "@calcom/prisma";
import { type NextResponse, NextResponse as Response } from "next/server";

type CredentialBody = { email?: unknown };

function getCredentialValue(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }

  return "";
}

export async function POST(request: Request): Promise<NextResponse> {
  const body = (await request.json().catch(() => ({}))) as CredentialBody;

  const email = getCredentialValue(body.email);
  const user = email
    ? await prisma.user.findUnique({ where: { email }, select: { id: true, locked: true } })
    : null;
  const authUserRows = user
    ? await prisma.$queryRaw<Array<{ auth_user_id: string | null }>>`
        select auth_user_id::text
        from public.users
        where id = ${user.id}
        limit 1
      `
    : [];

  // Password and MFA verification happen in the Supabase browser client. This
  // endpoint only preserves Cal.diy's local account lock and identity mapping.
  if (!user || user.locked || !authUserRows[0]?.auth_user_id) {
    return Response.json({ error: ErrorCode.IncorrectEmailPassword, ok: false }, { status: 401 });
  }

  return Response.json({ error: null, ok: true });
}
