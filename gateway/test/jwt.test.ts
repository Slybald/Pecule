import { describe, expect, it } from "vitest";
import { JWT_TTL_SECONDS, JwtProvider, importPrivateKey, signEnableBankingJwt } from "../src/jwt";
import { TEST_APP_ID, generateTestKey } from "./helpers";

function decodeSegment(segment: string): Record<string, unknown> {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(segment.length / 4) * 4, "=");
  return JSON.parse(atob(padded)) as Record<string, unknown>;
}

function base64UrlToBytes(segment: string): Uint8Array {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(segment.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

describe("jwt", () => {
  it("produces an RS256 JWT with the Enable Banking header and claims", async () => {
    const { privatePem, publicKey } = await generateTestKey();
    const key = await importPrivateKey(privatePem);
    const now = 1_800_000_000;
    const token = await signEnableBankingJwt(TEST_APP_ID, key, now);
    const [headerSegment, claimsSegment, signatureSegment] = token.split(".") as [string, string, string];

    expect(decodeSegment(headerSegment)).toEqual({ typ: "JWT", alg: "RS256", kid: TEST_APP_ID });
    expect(decodeSegment(claimsSegment)).toEqual({
      iss: "enablebanking.com",
      aud: "api.enablebanking.com",
      iat: now,
      exp: now + JWT_TTL_SECONDS,
    });
    const verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      base64UrlToBytes(signatureSegment),
      new TextEncoder().encode(`${headerSegment}.${claimsSegment}`),
    );
    expect(verified).toBe(true);
  });

  it("caches the token and renews it shortly before expiry", async () => {
    const { privatePem } = await generateTestKey();
    let nowMs = 1_800_000_000_000;
    const provider = new JwtProvider(TEST_APP_ID, privatePem, () => nowMs);

    const first = await provider.token();
    nowMs += 10 * 60 * 1000;
    expect(await provider.token()).toBe(first);

    nowMs += (JWT_TTL_SECONDS - 10 * 60 - 30) * 1000;
    const renewed = await provider.token();
    expect(renewed).not.toBe(first);
    expect(decodeSegment(renewed.split(".")[1] as string).iat).toBe(Math.floor(nowMs / 1000));
  });
});
