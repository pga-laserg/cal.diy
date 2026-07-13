import { ErrorCode } from "@calcom/features/auth/lib/ErrorCode";
import { authorizeCredentials } from "@calcom/features/auth/lib/next-auth-options";
import { type NextResponse, NextResponse as Response } from "next/server";

type CredentialBody = {
  backupCode?: unknown;
  email?: unknown;
  password?: unknown;
  totpCode?: unknown;
};

function getCredentialValue(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }

  return "";
}

function getAuthErrorCode(error: unknown): ErrorCode {
  if (!(error instanceof Error)) {
    return ErrorCode.InternalServerError;
  }

  if (Object.values(ErrorCode).includes(error.message as ErrorCode)) {
    return error.message as ErrorCode;
  }

  return ErrorCode.InternalServerError;
}

export async function POST(request: Request): Promise<NextResponse> {
  const body = (await request.json().catch(() => ({}))) as CredentialBody;

  try {
    await authorizeCredentials({
      backupCode: getCredentialValue(body.backupCode),
      email: getCredentialValue(body.email),
      password: getCredentialValue(body.password),
      totpCode: getCredentialValue(body.totpCode),
    });
  } catch (error) {
    return Response.json({ error: getAuthErrorCode(error), ok: false }, { status: 401 });
  }

  return Response.json({ error: null, ok: true });
}
