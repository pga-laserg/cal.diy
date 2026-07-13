import { parseBearerToken } from "./parse-bearer-token";

describe("parseBearerToken", () => {
  it.each([
    ["Bearer token", "token"],
    ["bearer token", "token"],
    ["  Bearer\ttoken  ", "token"],
  ])("parses %j", (header, expected) => {
    expect(parseBearerToken(header)).toBe(expected);
  });

  it.each([undefined, null, "", "Basic token", "Bearer", "Bearer token extra"])("rejects %j", (header) => {
    expect(parseBearerToken(header)).toBeNull();
  });
});
