import type { NextApiRequest } from "next";
import type { Session } from "next-auth";
import type { GetSessionParams } from "next-auth/react";
import { getSession as getSessionInner } from "next-auth/react";
import { getServerSession } from "./getServerSession";

type ServerSessionParams =
  | (GetSessionParams & { req?: NextApiRequest })
  | (GetSessionParams & { ctx?: { req?: NextApiRequest } });

function getRequest(options: ServerSessionParams): NextApiRequest | null {
  if ("req" in options && options.req) {
    return options.req;
  }

  if ("ctx" in options && options.ctx?.req) {
    return options.ctx.req;
  }

  return null;
}

export async function getSession(options: GetSessionParams): Promise<Session | null> {
  const req = getRequest(options as ServerSessionParams);

  if (req) {
    return getServerSession({ req });
  }

  const session = await getSessionInner(options);

  return session as Session | null;
}
