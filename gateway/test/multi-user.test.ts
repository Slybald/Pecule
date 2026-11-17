import { beforeEach, describe, expect, it } from "vitest";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { IdentityVault, type OwnedLink } from "../src/identity-vault";
import { handle } from "../src/index";
import { UserAccess } from "../src/user-access";
import type { Deps, Env } from "../src/types";
import { FakeKV, fakeFetch, gatewayRequest, jsonResponse, makeEnv, type RecordedRequest } from "./helpers";

// Models the transaction contract, not Cloudflare's runtime. A real workerd check
// remains required before provisioning/deployment; no shared KV is used here.
class AtomicMemoryStorage {
  readonly entries = new Map<string, unknown>();
  private tail: Promise<unknown> = Promise.resolve();
  async get<T>(key: string): Promise<T | undefined> { return structuredClone(this.entries.get(key)) as T | undefined; }
  async put(key: string, value: unknown): Promise<void> { this.entries.set(key, structuredClone(value)); }
  async delete(keys: string | string[]): Promise<void> { for (const key of Array.isArray(keys) ? keys : [keys]) this.entries.delete(key); }
  async list<T>({ prefix }: { prefix: string }): Promise<Map<string, T>> {
    return new Map([...this.entries].filter(([key]) => key.startsWith(prefix)).map(([key, value]) => [key, structuredClone(value) as T]));
  }
  transaction<T>(work: (storage: AtomicMemoryStorage) => Promise<T>): Promise<T> {
    const result = this.tail.then(async () => {
      const snapshot = structuredClone(this.entries);
      try { return await work(this); }
      catch (error) { this.entries.clear(); for (const [key, value] of snapshot) this.entries.set(key, value); throw error; }
    });
    this.tail = result.catch(() => undefined);
    return result;
  }
}

const NOW = Date.parse("2026-09-15T10:00:00Z");
let now: number;
let env: Env;
let access: UserAccess;
let deps: Deps;
let storage: AtomicMemoryStorage;
let requests: RecordedRequest[];
let alice: string;
let bob: string;

const call = (path: string, bearer: string, init: RequestInit = {}) => handle(gatewayRequest(path, { ...init, bearer }), env, deps);

beforeEach(async () => {
  now = NOW;
  ({ env } = await makeEnv(new FakeKV(() => now)));
  storage = new AtomicMemoryStorage();
  const vault = new IdentityVault({ storage } as unknown as DurableObjectState, undefined, () => now);
  env.AUTH_MODE = "multi_user";
  env.IDENTITY_VAULT = {
    idFromName: (name: string) => name,
    get: () => ({ fetch: (request: Request) => vault.fetch(request) }),
  } as unknown as DurableObjectNamespace;
  access = new UserAccess(env);
  // Internal verified identities, not credentials supplied by an HTTP request.
  alice = (await access.issueVerifiedSession("alice")).token;
  bob = (await access.issueVerifiedSession("bob")).token;
  const upstream = fakeFetch({
    "GET /aspsps": () => jsonResponse({ aspsps: [{ name: "Mock", country: "FR", psu_types: ["personal"] }] }),
    "POST /auth": () => jsonResponse({ url: "https://bank.test/auth" }),
    "POST /sessions": () => jsonResponse({ session_id: "bank-session", access: { valid_until: "2026-12-15T10:00:00Z" },
      accounts: [{ uid: "account-a", identification_hash: "hash-a", name: "Account A", currency: "EUR" }] }),
    "GET /accounts/account-a/balances": () => jsonResponse({ balances: [{ amount: "42.00" }] }),
    "GET /accounts/account-a/transactions": () => jsonResponse({ transactions: [] }),
    "DELETE /sessions/bank-session": () => jsonResponse({}),
  });
  requests = upstream.requests;
  deps = { fetch: upstream.fetch, now: () => now };
});

async function startAliceLink(): Promise<OwnedLink> {
  const response = await call("/v1/links", alice, { method: "POST",
    body: JSON.stringify({ aspspName: "Mock", aspspCountry: "FR", userId: "bob", ownerUserID: "bob" }) });
  expect(response.status).toBe(201);
  const { linkId } = await response.json() as { linkId: string };
  return access.getLink("alice", linkId);
}

async function authorizeAliceLink(): Promise<OwnedLink> {
  const link = await startAliceLink();
  const response = await handle(gatewayRequest(`/v1/links/callback?state=${link.state}&code=ok`, { bearer: null }), env, deps);
  expect(response.headers.get("Location")).toContain("/done?");
  return access.getLink("alice", link.id);
}

describe("multi-user access boundary", () => {
  it("resolves separate sessions and stores only token digests", async () => {
    expect(alice).not.toBe(bob);
    expect(alice).toMatch(/^[a-f0-9]{64}$/);
    expect(await (await call("/v1/session", alice)).json()).toEqual({ userId: "alice" });
    expect(await (await call("/v1/session", bob)).json()).toEqual({ userId: "bob" });
    const persisted = JSON.stringify([...storage.entries]);
    expect(persisted).not.toContain(alice);
    expect(persisted).not.toContain(bob);
  });

  it("refuses the admin bearer on user routes and user sessions on diagnostics", async () => {
    expect((await call("/v1/links", env.GATEWAY_BEARER_TOKEN, { method: "POST" })).status).toBe(401);
    expect((await call("/v1/diagnostics", alice)).status).toBe(401);
    expect((await call("/v1/diagnostics", env.GATEWAY_BEARER_TOKEN)).status).toBe(200);
    expect(requests).toHaveLength(0);
  });

  it("refuses the admin bearer on account routes in multi-user mode", async () => {
    for (const suffix of ["balances", "transactions"]) {
      expect((await call(`/v1/accounts/acc-1/${suffix}`, env.GATEWAY_BEARER_TOKEN)).status).toBe(401);
    }
    expect(requests).toHaveLength(0);
  });

  it("does not provide an HTTP endpoint to issue sessions from a submitted identity", async () => {
    expect((await call("/v1/session", alice, { method: "POST", body: JSON.stringify({ userId: "bob" }) })).status).toBe(404);
    expect((await call("/session.issue", alice, { method: "POST" })).status).toBe(404);
  });

  it("expires sessions at the exact deadline and revokes immediately", async () => {
    now += 3600 * 1000;
    expect((await call("/v1/session", alice)).status).toBe(401);
    now = NOW;
    expect((await call("/v1/session", bob, { method: "DELETE" })).status).toBe(204);
    expect((await call("/v1/session", bob)).status).toBe(401);
  });

  it("fails closed when the binding or auth mode is invalid", async () => {
    env.IDENTITY_VAULT = undefined;
    expect((await call("/v1/session", alice)).status).toBe(503);
    expect((await call("/v1/links", env.GATEWAY_BEARER_TOKEN, { method: "POST" })).status).toBe(503);
    env.AUTH_MODE = "typo" as Env["AUTH_MODE"];
    expect((await call("/v1/session", alice)).status).toBe(503);
    expect(requests).toHaveLength(0);
  });

  it("sets ownership from the session, ignores forged owners, and hides another user's link", async () => {
    const link = await startAliceLink();
    expect(link.ownerUserID).toBe("alice");
    const initialRequests = requests.length;
    expect((await call(`/v1/links/${link.id}`, alice)).status).toBe(200);
    const foreign = await call(`/v1/links/${link.id}`, bob);
    const missing = await call(`/v1/links/${crypto.randomUUID()}`, bob);
    expect(foreign.status).toBe(404);
    expect(await foreign.json()).toEqual(await missing.json());
    expect((await call(`/v1/links/${link.id}`, bob, { method: "DELETE" })).status).toBe(404);
    expect(requests).toHaveLength(initialRequests);
    const publicLink = await (await call(`/v1/links/${link.id}`, alice)).text();
    expect(publicLink).not.toContain("ownerUserID");
    expect(publicLink).not.toContain(link.state);
  });

  it("checks account ownership before either bank proxy is called", async () => {
    await authorizeAliceLink();
    for (const endpoint of ["balances", "transactions"]) {
      const before = requests.length;
      expect((await call(`/v1/accounts/account-a/${endpoint}`, bob)).status).toBe(404);
      expect(requests).toHaveLength(before);
      expect((await call(`/v1/accounts/account-a/${endpoint}`, alice)).status).toBe(200);
    }
  });

  it("does not claim ownerless legacy KV links on first login", async () => {
    const legacyId = crypto.randomUUID();
    await env.LINKS.put(`link:${legacyId}`, JSON.stringify({ id: legacyId, status: "authorized", accounts: [{ uid: "account-a" }] }));
    expect((await call(`/v1/links/${legacyId}`, alice)).status).toBe(404);
    expect((await call("/v1/accounts/account-a/balances", alice)).status).toBe(404);
    expect(requests).toHaveLength(0);
  });

  it("consumes a bank callback once even when two requests arrive together", async () => {
    const link = await startAliceLink();
    const callback = () => handle(gatewayRequest(`/v1/links/callback?state=${link.state}&code=ok`, { bearer: null }), env, deps);
    const results = await Promise.all([callback(), callback()]);
    const redirects = results.map(response => response.headers.get("Location") ?? "");
    expect(redirects.filter(value => value.includes("/done?"))).toHaveLength(1);
    expect(redirects.filter(value => value.includes("invalid_state"))).toHaveLength(1);
    expect(requests.filter(request => request.method === "POST" && request.url.pathname === "/sessions")).toHaveLength(1);
  });

  it("expires callbacks at 15 minutes and rejects cancelled pending links", async () => {
    const expired = await startAliceLink();
    now += 15 * 60 * 1000;
    expect(await access.consumeCallback(expired.state)).toBeNull();
    now = NOW;
    const cancelled = await startAliceLink();
    expect((await call(`/v1/links/${cancelled.id}`, alice, { method: "DELETE" })).status).toBe(204);
    expect(await access.consumeCallback(cancelled.state)).toBeNull();
  });

  it("does not resurrect a deleted link from a callback already in flight", async () => {
    const link = await startAliceLink();
    expect(await access.consumeCallback(link.state)).not.toBeNull();
    await access.deleteLink("alice", link.id);
    await expect(access.updateLink({ ...link, status: "authorized", sessionId: "late" })).rejects.toMatchObject({ status: 404 });
    expect((await call(`/v1/links/${link.id}`, alice)).status).toBe(404);
  });

  it("revokes a bank session returned after its pending link was deleted", async () => {
    const link = await startAliceLink();
    let signalStarted!: () => void;
    let finishBankResponse!: () => void;
    const started = new Promise<void>(resolve => { signalStarted = resolve; });
    const bankResponse = new Promise<void>(resolve => { finishBankResponse = resolve; });
    const originalFetch = deps.fetch;
    deps.fetch = async (input, init) => {
      if (init?.method === "POST" && String(input).endsWith("/sessions")) {
        signalStarted();
        await bankResponse;
      }
      return originalFetch(input, init);
    };
    const callback = handle(gatewayRequest(`/v1/links/callback?state=${link.state}&code=ok`, { bearer: null }), env, deps);
    await started;
    expect((await call(`/v1/links/${link.id}`, alice, { method: "DELETE" })).status).toBe(204);
    finishBankResponse();
    expect((await callback).headers.get("Location")).toContain("invalid_state");
    expect((await call(`/v1/links/${link.id}`, alice)).status).toBe(404);
    expect(requests.filter(request => request.method === "DELETE" && request.url.pathname === "/sessions/bank-session")).toHaveLength(1);
  });

  it("denies account access after consent expires or its link is deleted", async () => {
    const link = await authorizeAliceLink();
    expect((await call(`/v1/links/${link.id}`, alice, { method: "DELETE" })).status).toBe(204);
    const before = requests.length;
    expect((await call("/v1/accounts/account-a/balances", alice)).status).toBe(404);
    expect(requests).toHaveLength(before);

    await authorizeAliceLink();
    now = Date.parse("2026-12-15T10:00:00Z");
    alice = (await access.issueVerifiedSession("alice")).token;
    expect((await call("/v1/accounts/account-a/balances", alice)).status).toBe(404);
  });

  it("refuses excessive session lifetime and namespace injection", async () => {
    await expect(access.issueVerifiedSession("alice", 86401)).rejects.toMatchObject({ status: 400 });
    await expect(access.issueVerifiedSession("bob:link:alice")).rejects.toMatchObject({ status: 400 });
  });
});

describe("public Apple authentication boundary", () => {
  beforeEach(() => {
    env.APPLE_CLIENT_ID = "com.pecule.test";
    env.AUTH_RATE_LIMITER = { limit: async () => ({ success: true }) };
  });

  const publicCall = (path: string, body?: unknown) => handle(gatewayRequest(path, {
    method: "POST", bearer: null, body: body === undefined ? undefined : JSON.stringify(body),
  }), env, deps);

  it("issues one session from a signed identity and prevents a concurrent replay", async () => {
    const challenge = await (await publicCall("/v1/auth/apple/challenge")).json() as { challengeId: string; nonce: string };
    const key = await generateKeyPair("RS256");
    const publicKey = { ...await exportJWK(key.publicKey), kid: "apple-test", use: "sig", alg: "RS256" };
    deps.fetch = async input => {
      expect(String(input)).toBe("https://appleid.apple.com/auth/keys");
      return jsonResponse({ keys: [publicKey] });
    };
    const identityToken = await new SignJWT({ nonce: challenge.nonce }).setProtectedHeader({ alg: "RS256", kid: "apple-test" })
      .setIssuer("https://appleid.apple.com").setAudience(env.APPLE_CLIENT_ID!).setSubject("verified-person")
      .setIssuedAt(now / 1000).setExpirationTime(now / 1000 + 600).sign(key.privateKey);
    const body = { challengeId: challenge.challengeId, identityToken, userId: "alice", ownerUserID: "bob" };
    const results = await Promise.all([publicCall("/v1/auth/apple/session", body), publicCall("/v1/auth/apple/session", body)]);
    expect(results.map(result => result.status).sort()).toEqual([201, 401]);
    const payload = await results.find(result => result.status === 201)!.json() as { token: string; userId: string; expiresAt: number };
    expect(payload.userId).toMatch(/^apple_[a-f0-9]{64}$/);
    expect(payload.expiresAt).toBe(now + 3600 * 1000);
    expect(await (await call("/v1/session", payload.token)).json()).toEqual({ userId: payload.userId });
    expect(JSON.stringify([...storage.entries])).not.toContain(identityToken);
  });

  it("requires configured identity verification and rate limiting", async () => {
    env.APPLE_CLIENT_ID = undefined;
    expect((await publicCall("/v1/auth/apple/challenge")).status).toBe(503);
    env.APPLE_CLIENT_ID = "com.pecule.test";
    env.AUTH_RATE_LIMITER = undefined;
    expect((await publicCall("/v1/auth/apple/challenge")).status).toBe(503);
    env.AUTH_RATE_LIMITER = { limit: async () => ({ success: false }) };
    expect((await publicCall("/v1/auth/apple/challenge")).status).toBe(429);
    expect((await publicCall("/v1/auth/apple/session", {})).status).toBe(429);
  });

  it("expires challenges after five minutes and burns a failed login's challenge", async () => {
    const first = await (await publicCall("/v1/auth/apple/challenge")).json() as { challengeId: string };
    expect((await publicCall("/v1/auth/apple/session", { challengeId: first.challengeId, identityToken: "invalid" })).status).toBe(401);
    expect(await access.consumeChallenge(first.challengeId)).toBeNull();
    const second = await (await publicCall("/v1/auth/apple/challenge")).json() as { challengeId: string };
    now += 5 * 60 * 1000;
    expect((await publicCall("/v1/auth/apple/session", { challengeId: second.challengeId, identityToken: "invalid" })).status).toBe(401);
  });

  it("bounds input size without trusting Content-Length and validates JSON shape", async () => {
    expect((await publicCall("/v1/auth/apple/session", { identityToken: "x".repeat(17000) })).status).toBe(413);
    expect((await publicCall("/v1/auth/apple/session", [])).status).toBe(400);
    expect((await publicCall("/v1/auth/apple/session", { userId: "alice" })).status).toBe(400);
    const response = await handle(gatewayRequest("/v1/auth/apple/session", {
      method: "POST", bearer: null, headers: { "Content-Type": "text/plain" }, body: "{}",
    }), env, deps);
    expect(response.status).toBe(415);
  });

  it("does not expose Apple login in the legacy personal mode", async () => {
    env.AUTH_MODE = "single_user";
    expect((await publicCall("/v1/auth/apple/challenge")).status).toBe(401);
  });
});
