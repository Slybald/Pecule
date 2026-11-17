import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { exportJWK, generateKeyPair, SignJWT, type JWTPayload } from "jose";
import { verifyAppleIdentity } from "../src/apple-auth";
import type { Deps } from "../src/types";

const NOW = Date.parse("2026-09-15T10:00:00Z");
const CLIENT = "com.pecule.test";
const NONCE = "a".repeat(64);
let keys: Awaited<ReturnType<typeof generateKeyPair>>;
let jwks: unknown;
let deps: Deps;
let fetchedURLs: string[];

beforeAll(async () => {
  keys = await generateKeyPair("RS256");
  jwks = { keys: [{ ...await exportJWK(keys.publicKey), kid: "test-key", use: "sig", alg: "RS256" }] };
});

beforeEach(() => {
  fetchedURLs = [];
  deps = {
    now: () => NOW,
    fetch: async input => {
      fetchedURLs.push(String(input));
      return new Response(JSON.stringify(jwks), { headers: { "Content-Type": "application/json" } });
    },
  };
});

const claims = (): JWTPayload => ({
  iss: "https://appleid.apple.com", aud: CLIENT, sub: "signed-apple-subject", nonce: NONCE,
  iat: NOW / 1000, exp: NOW / 1000 + 600,
});

const token = (overrides: JWTPayload = {}, header: Record<string, string> = {}) => new SignJWT({ ...claims(), ...overrides })
  .setProtectedHeader({ alg: "RS256", kid: "test-key", ...header }).sign(keys.privateKey);

describe("Apple identity verification", () => {
  it("derives a stable user identity from signed issuer/audience/subject, not email", async () => {
    const first = await verifyAppleIdentity(await token({ email: "one@example.test" }), NONCE, CLIENT, deps);
    const second = await verifyAppleIdentity(await token({ email: "two@example.test" }), NONCE, CLIENT, deps);
    expect(first).toMatch(/^apple_[a-f0-9]{64}$/);
    expect(first).toBe(second);
    expect(first).not.toContain("signed-apple-subject");
    expect(fetchedURLs).toEqual(["https://appleid.apple.com/auth/keys"]);
  });

  it.each([
    ["wrong issuer", { iss: "https://attacker.test" }],
    ["wrong audience", { aud: "com.someone.else" }],
    ["wrong nonce", { nonce: "b".repeat(64) }],
    ["expired at exact deadline", { exp: NOW / 1000 }],
    ["issued in the future", { iat: NOW / 1000 + 60 }],
    ["too old", { iat: NOW / 1000 - 601 }],
    ["missing subject", { sub: undefined }],
    ["empty subject", { sub: "" }],
    ["missing nonce", { nonce: undefined }],
    ["missing expiry", { exp: undefined }],
    ["missing issued-at", { iat: undefined }],
  ] satisfies Array<[string, JWTPayload]>)("rejects %s", async (_name, override) => {
    await expect(verifyAppleIdentity(await token(override), NONCE, CLIENT, deps)).rejects.toMatchObject({ status: 401, code: "invalid_identity" });
  });

  it("rejects a validly shaped token signed with an attacker's key", async () => {
    const attacker = await generateKeyPair("RS256");
    const forged = await new SignJWT(claims()).setProtectedHeader({ alg: "RS256", kid: "test-key" }).sign(attacker.privateKey);
    await expect(verifyAppleIdentity(forged, NONCE, CLIENT, deps)).rejects.toMatchObject({ status: 401 });
  });

  it("refuses symmetric algorithms and does not fetch a key from token-supplied URLs", async () => {
    const forged = await new SignJWT(claims()).setProtectedHeader({ alg: "HS256", kid: "test-key" })
      .sign(new TextEncoder().encode("not-an-apple-key-not-an-apple-key-12"));
    await expect(verifyAppleIdentity(forged, NONCE, CLIENT, deps)).rejects.toMatchObject({ status: 401 });
    expect(fetchedURLs).toHaveLength(0);
    await verifyAppleIdentity(await token({}, { jku: "https://attacker.test/keys" }), NONCE, CLIENT, deps);
    expect(fetchedURLs).toEqual(["https://appleid.apple.com/auth/keys"]);
  });

  it("fails safely when the identity provider cannot be reached", async () => {
    deps.fetch = async () => { throw new Error("private upstream diagnostic"); };
    await expect(verifyAppleIdentity(await token(), NONCE, CLIENT, deps))
      .rejects.toMatchObject({ status: 503, code: "identity_provider_unavailable" });
  });

  it("refuses malformed and oversized tokens before key retrieval", async () => {
    await expect(verifyAppleIdentity("x".repeat(17000), NONCE, CLIENT, deps)).rejects.toMatchObject({ status: 401 });
    await expect(verifyAppleIdentity("not-a-token", NONCE, CLIENT, deps)).rejects.toMatchObject({ status: 401 });
    expect(fetchedURLs).toHaveLength(0);
  });
});
