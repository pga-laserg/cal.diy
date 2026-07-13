import { getServerSession } from "@calcom/features/auth/lib/getServerSession";
import type { NextApiRequest, NextApiResponse } from "next";

const providers = {
  "azure-ad": {
    callbackUrl: "/auth/login",
    id: "azure-ad",
    name: "Microsoft",
    signinUrl: "/auth/login",
    type: "oauth",
  },
  google: {
    callbackUrl: "/auth/login",
    id: "google",
    name: "Google",
    signinUrl: "/auth/login",
    type: "oauth",
  },
};

const handler = async (req: NextApiRequest, res: NextApiResponse): Promise<void> => {
  let action = req.query.nextauth;
  if (Array.isArray(action)) {
    action = action[0];
  }

  res.setHeader("Cache-Control", "no-store, max-age=0");

  if (action === "session") {
    const session = await getServerSession({ req });
    return res.status(200).json(session);
  }

  if (action === "csrf") {
    return res.status(200).json({ csrfToken: "supabase" });
  }

  if (action === "providers") {
    return res.status(200).json(providers);
  }

  return res.status(410).json({
    message: "NextAuth routes have been retired. Use Supabase Auth.",
  });
};

export default handler;
