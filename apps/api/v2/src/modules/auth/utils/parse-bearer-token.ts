export function parseBearerToken(headerValue: string | undefined | null): string | null {
  if (!headerValue) {
    return null;
  }

  const match = /^Bearer[\t ]+(\S+)$/i.exec(headerValue.trim());
  return match?.[1] ?? null;
}
