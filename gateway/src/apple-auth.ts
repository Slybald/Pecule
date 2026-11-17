import { createRemoteJWKSet, customFetch, jwtVerify } from "jose";
import { GatewayError } from "./errors";
import { json } from "./http";
import type { Deps, Env } from "./types";
import { tokenDigest, UserAccess } from "./user-access";

const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_KEYS_URL = new URL("https://appleid.apple.com/auth/keys");
const keyResolvers = new WeakMap<typeof fetch, ReturnType<typeof createRemoteJWKSet>>();
const MAX_BODY_BYTES = 16 * 1024;

function appleKeys(deps: Deps): ReturnType<typeof createRemoteJWKSet> {
  let resolver = keyResolvers.get(deps.fetch);
  if (!resolver) {
    resolver = createRemoteJWKSet(APPLE_KEYS_URL, {
      timeoutDuration: 5000, cooldownDuration: 30000, cacheMaxAge: 10 * 60 * 1000,
      [customFetch]: async (url, options) => {
        try {
          const response = await deps.fetch(url, options);
          if (response.status !== 200) throw new GatewayError(503, "identity_provider_unavailable");
          return response;
        } catch { throw new GatewayError(503, "identity_provider_unavailable"); }
      },
    });
    keyResolvers.set(deps.fetch, resolver);
  }
  return resolver;
}

export async function verifyAppleIdentity(identityToken: string, expectedNonce: string, clientId: string, deps: Deps): Promise<string> {
  if (!identityToken || identityToken.length > MAX_BODY_BYTES || !/^[a-f0-9]{64}$/.test(expectedNonce)) {
    throw new GatewayError(401, "invalid_identity");
  }
  try {
    const { payload, protectedHeader } = await jwtVerify(identityToken, appleKeys(deps), {
      issuer: APPLE_ISSUER, audience: clientId, algorithms: ["RS256"],
      requiredClaims: ["sub", "exp", "iat", "nonce"], maxTokenAge: "10m", currentDate: new Date(deps.now()),
    });
    if (typeof payload.sub !== "string" || !payload.sub || payload.sub.length > 255
      || payload.nonce !== expectedNonce || typeof protectedHeader.kid !== "string" || !protectedHeader.kid) {
      throw new GatewayError(401, "invalid_identity");
    }
    // Stable identity comes exclusively from signed claims; email/name are not identifiers.
    return `apple_${await tokenDigest(JSON.stringify([APPLE_ISSUER, clientId, payload.sub]))}`;
  } catch (error) {
    if (error instanceof GatewayError) throw error;
    // Never return or log an identity token, claims or the verifier's detailed error.
    throw new GatewayError(401, "invalid_identity");
  }
}

async function boundedJsonBody(request: Request): Promise<Record<string, unknown>> {
  if (request.headers.get("Content-Type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") {
    throw new GatewayError(415, "unsupported_media_type");
  }
  const reader = request.body?.getReader();
  if (!reader) throw new GatewayError(400, "invalid_request");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      size += result.value.byteLength;
      if (size > MAX_BODY_BYTES) {
        await reader.cancel();
        throw new GatewayError(413, "request_too_large");
      }
      chunks.push(result.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch { throw new GatewayError(400, "invalid_request"); }
}

export async function handleAppleAuth(request: Request, env: Env, deps: Deps): Promise<Response> {
  const clientId = env.APPLE_CLIENT_ID?.trim();
  if (!clientId || !env.IDENTITY_VAULT || !env.AUTH_RATE_LIMITER) throw new GatewayError(503, "authentication_unavailable");
  // This is mandatory for the public challenge/login endpoints, including failed logins.
  const verdict = await env.AUTH_RATE_LIMITER.limit({ key: `apple-login:${request.headers.get("CF-Connecting-IP") ?? "unknown"}` });
  if (!verdict.success) throw new GatewayError(429, "too_many_requests");
  const access = new UserAccess(env);
  if (new URL(request.url).pathname === "/v1/auth/apple/challenge") {
    return json(await access.issueChallenge(), 201);
  }
  const body = await boundedJsonBody(request);
  if (typeof body.challengeId !== "string" || typeof body.identityToken !== "string") throw new GatewayError(400, "invalid_request");
  // Consume before verification: a failed login must start a fresh challenge.
  const challenge = await access.consumeChallenge(body.challengeId);
  if (!challenge) throw new GatewayError(401, "invalid_identity");
  const verifiedId = await verifyAppleIdentity(body.identityToken, challenge.nonce, clientId, deps);
  const issued = await access.issueVerifiedSession(verifiedId);
  return json({ token: issued.token, userId: verifiedId, expiresAt: issued.session.expiresAt }, 201);
}
