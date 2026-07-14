import { middleware } from "../trpc";
import logger from "@calcom/lib/logger";

const perfMiddleware = middleware(async ({ path, type, next }) => {
  const startedAt = performance.now();
  const result = await next();
  const durationMs = performance.now() - startedAt;

  if (durationMs >= 1000) {
    logger.warn("Slow tRPC procedure", {
      path,
      type,
      durationMs: Math.round(durationMs),
      ok: result.ok,
    });
  }

  return result;
});

export default perfMiddleware;
