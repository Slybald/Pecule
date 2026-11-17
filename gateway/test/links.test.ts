import { beforeEach, describe, expect, it } from "vitest";
import { handle } from "../src/index";
import type { Deps, Env } from "../src/types";
import { FakeKV, type RecordedRequest, fakeFetch, gatewayRequest, jsonResponse, makeEnv } from "./helpers";

const NOW = Date.parse("2026-09-14T10:00:00Z");
const MOCK_ACCOUNT = {
  uid: "acc-1",
  identification_hash: "hash-1",
  account_id: { iban: "FR7630006000011234567890189" },
  name: "Compte courant",
  currency: "EUR",
  product: "Current account",
  cash_account_type: "CACC",
  usage: "PRIV",
};

let kv: FakeKV;
let env: Env;
let requests: RecordedRequest[];
let deps: Deps;
let nowMs: number;

const call = (request: Request) => handle(request, env, deps);
const body = async (response: Response) => (await response.json()) as Record<string, any>;

beforeEach(async () => {
  nowMs = NOW;
  kv = new FakeKV(() => nowMs);
  ({ env } = await makeEnv(kv));
  const fake = fakeFetch({
    "GET /aspsps": () =>
      jsonResponse({
        aspsps: [{ name: "Mock ASPSP", country: "FR", maximum_consent_validity: 180 * 86400, psu_types: ["personal"] }],
      }),
    "POST /auth": () => jsonResponse({ url: "https://eb.test/authorize?flow=1", authorization_id: "auth-1" }),
    "POST /sessions": (request) =>
      (request.body as { code?: string } | undefined)?.code === "good-code"
        ? jsonResponse({
            session_id: "sess-1",
            accounts: [MOCK_ACCOUNT],
            access: { valid_until: "2027-03-13T10:00:00Z" },
            aspsp: { name: "Mock ASPSP", country: "FR" },
            psu_type: "personal",
          })
        : jsonResponse({ error: "INVALID_CODE" }, 400),
    "DELETE /sessions/sess-1": () => jsonResponse({}),
  });
  requests = fake.requests;
  deps = { fetch: fake.fetch, now: () => nowMs };
});

async function startMockLink(): Promise<{ linkId: string; state: string }> {
  const response = await call(
    gatewayRequest("/v1/links", { method: "POST", body: JSON.stringify({ aspspName: "mock aspsp", aspspCountry: "fr" }) }),
  );
  expect(response.status).toBe(201);
  const { linkId } = await body(response);
  const authRequest = [...requests].reverse().find((r) => r.method === "POST" && r.url.pathname === "/auth") as RecordedRequest;
  return { linkId, state: (authRequest.body as { state: string }).state };
}

describe("link flow", () => {
  it("rejects unauthenticated calls except the callback", async () => {
    expect((await call(gatewayRequest("/v1/links", { method: "POST", bearer: null }))).status).toBe(401);
    expect((await call(gatewayRequest("/v1/links", { method: "POST", bearer: "wrong" }))).status).toBe(401);
    expect((await call(gatewayRequest("/healthz", { bearer: null }))).status).toBe(200);
  });

  it("throttles repeated failed authentications per client address", async () => {
    const keys: string[] = [];
    let allowed = true;
    env.AUTH_RATE_LIMITER = { limit: async ({ key }) => { keys.push(key); return { success: allowed }; } };

    const first = await call(gatewayRequest("/v1/links/x", { bearer: "wrong", headers: { "CF-Connecting-IP": "198.51.100.9" } }));
    expect(first.status).toBe(401);
    allowed = false;
    const throttled = await call(gatewayRequest("/v1/links/x", { bearer: "wrong", headers: { "CF-Connecting-IP": "198.51.100.9" } }));
    expect(throttled.status).toBe(429);
    expect(keys).toEqual(["198.51.100.9", "198.51.100.9"]);

    const legit = await call(gatewayRequest("/v1/diagnostics"));
    expect(legit.status).toBe(200);
    expect(keys, "successful authentications never touch the limiter").toHaveLength(2);
  });

  it("accepts the previous bearer during a rotation", async () => {
    env.GATEWAY_BEARER_TOKEN_PREVIOUS = "old-token";
    expect((await call(gatewayRequest("/v1/diagnostics", { bearer: "old-token" }))).status).toBe(200);
    expect((await call(gatewayRequest("/v1/diagnostics", { bearer: "older-token" }))).status).toBe(401);
  });

  it("keeps configuration diagnostics behind the bearer", async () => {
    const health = await body(await call(gatewayRequest("/healthz", { bearer: null })));
    expect(health).toEqual({ ok: true, environment: "test" });

    expect((await call(gatewayRequest("/v1/diagnostics", { bearer: null }))).status).toBe(401);
    const diagnostics = await body(await call(gatewayRequest("/v1/diagnostics")));
    expect(diagnostics.config.appId).toBe("uuid");
    expect(diagnostics.config.privateKey).toBe("pkcs8");
    expect(diagnostics.config.accountHashSalt).toBe("set");
  });

  it("uses GATEWAY_PUBLIC_URL for the bank redirect when configured", async () => {
    env.GATEWAY_PUBLIC_URL = "https://public.example";
    const response = await call(
      gatewayRequest("/v1/links", { method: "POST", body: JSON.stringify({ aspspName: "Mock ASPSP", aspspCountry: "FR" }) }),
    );
    expect((await body(response)).redirectUrl).toBe("https://public.example/v1/links/callback");
    const authRequest = [...requests].reverse().find((r) => r.url.pathname === "/auth") as RecordedRequest;
    expect((authRequest.body as { redirect_url: string }).redirect_url).toBe("https://public.example/v1/links/callback");
  });

  it("serves public privacy and terms pages with the contact address and hardened headers", async () => {
    for (const path of ["/privacy", "/terms"]) {
      const response = await call(new Request(`https://gateway.test${path}`));
      expect(response.status).toBe(200);
      expect(response.headers.get("Content-Type")).toContain("text/html");
      expect(response.headers.get("X-Frame-Options")).toBe("DENY");
      expect(response.headers.get("Content-Security-Policy")).toContain("default-src 'none'");
      expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
      const html = await response.text();
      expect(html).toContain("privacy@example.test");
    }
    const privacy = await (await call(new Request("https://gateway.test/privacy"))).text();
    // The page must state what KV really holds and for how long.
    expect(privacy).toContain("IBAN masqué");
    expect(privacy).toContain("empreinte salée");
    expect(privacy).toContain("24 heures");
    expect(privacy).toContain("lifeos://");
  });

  it("starts an authorization with the bank's maximum consent validity and the worker callback URL", async () => {
    const response = await call(
      gatewayRequest("/v1/links", { method: "POST", body: JSON.stringify({ aspspName: "Mock ASPSP", aspspCountry: "FR" }) }),
    );
    const payload = await body(response);
    expect(payload.authUrl).toBe("https://eb.test/authorize?flow=1");
    expect(payload.redirectUrl).toBe("https://gw.test/v1/links/callback");
    expect(payload.validUntil).toBe(new Date(NOW + 180 * 86400 * 1000).toISOString());

    const authRequest = requests.find((r) => r.url.pathname === "/auth") as RecordedRequest;
    expect(authRequest.headers.Authorization).toMatch(/^Bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(authRequest.body).toMatchObject({
      access: { valid_until: payload.validUntil },
      aspsp: { name: "Mock ASPSP", country: "FR" },
      redirect_url: "https://gw.test/v1/links/callback",
      psu_type: "personal",
    });
    expect((authRequest.body as { state: string }).state).toMatch(/^[0-9a-f-]{36}$/);

    const pending = await body(await call(gatewayRequest(`/v1/links/${payload.linkId}`)));
    expect(pending.status).toBe("pending");
    expect(pending.accounts).toEqual([]);
  });

  it("caps the validity at the requested number of days", async () => {
    const response = await call(
      gatewayRequest("/v1/links", {
        method: "POST",
        body: JSON.stringify({ aspspName: "Mock ASPSP", aspspCountry: "FR", validityDays: 30 }),
      }),
    );
    expect((await body(response)).validUntil).toBe(new Date(NOW + 30 * 86400 * 1000).toISOString());
  });

  it("returns 404 with the available banks when the ASPSP is unknown", async () => {
    const response = await call(
      gatewayRequest("/v1/links", { method: "POST", body: JSON.stringify({ aspspName: "Nope", aspspCountry: "FR" }) }),
    );
    expect(response.status).toBe(404);
    const payload = await body(response);
    expect(payload.error).toBe("aspsp_not_found");
    expect(payload.detail.available).toEqual(["Mock ASPSP"]);
  });

  it("validates input", async () => {
    const response = await call(gatewayRequest("/v1/links", { method: "POST", body: JSON.stringify({ aspspName: "x" }) }));
    expect(response.status).toBe(400);
  });

  it("completes the callback, stores the session server-side and redirects into the app", async () => {
    const { linkId, state } = await startMockLink();
    const callback = await call(gatewayRequest(`/v1/links/callback?code=good-code&state=${state}`, { bearer: null }));
    expect(callback.status).toBe(302);
    expect(callback.headers.get("Location")).toBe(`lifeos://link/done?linkId=${linkId}`);

    const sessionRequest = requests.find((r) => r.url.pathname === "/sessions") as RecordedRequest;
    expect(sessionRequest.body).toEqual({ code: "good-code" });

    const response = await call(gatewayRequest(`/v1/links/${linkId}`));
    const text = await response.text();
    expect(text).not.toContain("sess-1");
    const payload = JSON.parse(text);
    expect(payload.status).toBe("authorized");
    expect(payload.validUntil).toBe("2027-03-13T10:00:00Z");
    expect(payload.accounts).toEqual([
      {
        uid: "acc-1",
        identificationHash: "hash-1",
        iban: "FR76…0189",
        name: "Compte courant",
        currency: "EUR",
        product: "Current account",
        cashAccountType: "CACC",
        usage: "PRIV",
      },
    ]);
    const stored = kv.store.get(`link:${linkId}`)?.value ?? "";
    expect(stored).not.toContain("FR7630006000011234567890189");
    expect(stored).toContain("hash-1");

    const replay = await call(gatewayRequest(`/v1/links/callback?code=good-code&state=${state}`, { bearer: null }));
    expect(replay.headers.get("Location")).toBe("lifeos://link/error?code=invalid_state");
  });

  it("derives a salted hash when the bank omits identification_hash and keeps the IBAN out of KV", async () => {
    const { linkId, state } = await startMockLink();
    const bare = { uid: "acc-2", account_id: { iban: "FR76 3000 6000 0112 3456 7890 189" }, name: "Sans hash", currency: "EUR" };
    const noIban = { uid: "acc-3", name: "Carte", currency: "EUR", cash_account_type: "CARD" };
    const sessionAccounts = [bare, noIban];
    const originalHandler = requests;
    void originalHandler;
    const fake = fakeFetch({
      "GET /aspsps": () => jsonResponse({ aspsps: [{ name: "Mock ASPSP", country: "FR", maximum_consent_validity: 100, psu_types: ["personal"] }] }),
      "POST /sessions": () => jsonResponse({ session_id: "sess-2", accounts: sessionAccounts, access: { valid_until: "2027-03-13T10:00:00Z" } }),
    });
    deps = { fetch: fake.fetch, now: () => nowMs };

    await call(gatewayRequest(`/v1/links/callback?code=good-code&state=${state}`, { bearer: null }));
    const payload = await body(await call(gatewayRequest(`/v1/links/${linkId}`)));

    const expectedDigest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("test-salt|FR7630006000011234567890189"));
    const expectedHex = Array.from(new Uint8Array(expectedDigest), (b) => b.toString(16).padStart(2, "0")).join("");
    expect(payload.accounts[0].identificationHash).toBe(`lifeos-sha256:${expectedHex}`);
    expect(payload.accounts[0].iban).toBe("FR76…0189");
    expect(payload.accounts[1].identificationHash).toBeNull();
    expect(payload.accounts[1].iban).toBeNull();
    expect(kv.store.get(`link:${linkId}`)?.value).not.toContain("3456");
  });

  it("still serves links stored in the legacy raw shape, with the IBAN masked", async () => {
    const legacy = {
      id: "0d2d3f0e-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
      status: "authorized",
      aspsp: { name: "Mock ASPSP", country: "FR" },
      psuType: "personal",
      state: "s",
      createdAt: "2026-09-14T07:39:07.434Z",
      sessionId: "sess-legacy",
      validUntil: "2027-03-13T10:00:00Z",
      accounts: [{ uid: "acc-legacy", identification_hash: "legacy-hash", account_id: { iban: "FR7630006000011234567890189" }, name: "Legacy", currency: "EUR" }],
    };
    await kv.put(`link:${legacy.id}`, JSON.stringify(legacy));

    const payload = await body(await call(gatewayRequest(`/v1/links/${legacy.id}`)));
    expect(payload.accounts).toEqual([
      expect.objectContaining({ uid: "acc-legacy", identificationHash: "legacy-hash", iban: "FR76…0189", name: "Legacy" }),
    ]);
  });

  it("expires failed links after a day", async () => {
    const { linkId, state } = await startMockLink();
    await call(gatewayRequest(`/v1/links/callback?error=access_denied&state=${state}`, { bearer: null }));
    expect((await call(gatewayRequest(`/v1/links/${linkId}`))).status).toBe(200);

    nowMs += 25 * 3600 * 1000;
    expect((await call(gatewayRequest(`/v1/links/${linkId}`))).status).toBe(404);
  });

  it("reports an authorized link as expired once valid_until has passed", async () => {
    const { linkId, state } = await startMockLink();
    await call(gatewayRequest(`/v1/links/callback?code=good-code&state=${state}`, { bearer: null }));
    nowMs = Date.parse("2027-03-14T00:00:00Z");
    expect((await body(await call(gatewayRequest(`/v1/links/${linkId}`)))).status).toBe("expired");
  });

  it("rejects unknown or expired states", async () => {
    const unknown = await call(gatewayRequest(`/v1/links/callback?code=x&state=${crypto.randomUUID()}`, { bearer: null }));
    expect(unknown.headers.get("Location")).toBe("lifeos://link/error?code=invalid_state");

    const { state } = await startMockLink();
    nowMs += 16 * 60 * 1000;
    const late = await call(gatewayRequest(`/v1/links/callback?code=good-code&state=${state}`, { bearer: null }));
    expect(late.headers.get("Location")).toBe("lifeos://link/error?code=invalid_state");
  });

  it("refuses a malformed state with 400 before any KV read", async () => {
    const reads: string[] = [];
    const realGet = kv.get.bind(kv);
    kv.get = async (key: string, type?: "text" | "json") => { reads.push(key); return realGet(key, type); };
    for (const state of [null, "", "../x", "a".repeat(500), "nope"]) {
      const query = state === null ? "code=x" : `code=x&state=${encodeURIComponent(state)}`;
      const response = await call(gatewayRequest(`/v1/links/callback?${query}`, { bearer: null }));
      expect(response.status, String(state)).toBe(400);
    }
    expect(reads).toEqual([]);
  });

  it("throttles the anonymous callback per client address", async () => {
    const keys: string[] = [];
    let allowed = true;
    env.AUTH_RATE_LIMITER = { limit: async ({ key }) => { keys.push(key); return { success: allowed }; } };
    const url = `/v1/links/callback?code=x&state=${crypto.randomUUID()}`;
    const headers = { "CF-Connecting-IP": "198.51.100.7" };
    expect((await call(gatewayRequest(url, { bearer: null, headers }))).status).toBe(302);
    allowed = false;
    expect((await call(gatewayRequest(url, { bearer: null, headers }))).status).toBe(429);
    expect(keys).toEqual(["callback:198.51.100.7", "callback:198.51.100.7"]);
  });

  it("ignores a callback replayed on a link that is no longer pending", async () => {
    const { linkId, state } = await startMockLink();
    const first = await call(gatewayRequest(`/v1/links/callback?code=good-code&state=${state}`, { bearer: null }));
    expect(first.headers.get("Location")).toBe(`lifeos://link/done?linkId=${linkId}`);
    // Simulate the race where the state key is still readable when the replay arrives.
    await kv.put(`state:${state}`, linkId);
    const before = requests.filter((r) => r.url.pathname === "/sessions").length;
    const replay = await call(gatewayRequest(`/v1/links/callback?code=bad-code&state=${state}`, { bearer: null }));
    expect(replay.headers.get("Location")).toBe(`lifeos://link/done?linkId=${linkId}`);
    expect(requests.filter((r) => r.url.pathname === "/sessions")).toHaveLength(before);
    expect((await body(await call(gatewayRequest(`/v1/links/${linkId}`)))).status).toBe("authorized");
  });

  it("marks the link failed when the bank returns an error or the session cannot be created", async () => {
    const denied = await startMockLink();
    const deniedCallback = await call(
      gatewayRequest(`/v1/links/callback?error=access_denied&state=${denied.state}`, { bearer: null }),
    );
    expect(deniedCallback.headers.get("Location")).toBe(`lifeos://link/error?linkId=${denied.linkId}&code=access_denied`);
    expect((await body(await call(gatewayRequest(`/v1/links/${denied.linkId}`)))).status).toBe("failed");

    const bad = await startMockLink();
    const badCallback = await call(gatewayRequest(`/v1/links/callback?code=bad-code&state=${bad.state}`, { bearer: null }));
    expect(badCallback.headers.get("Location")).toBe(`lifeos://link/error?linkId=${bad.linkId}&code=INVALID_CODE`);
  });

  it("deletes the bank session and the stored link", async () => {
    const { linkId, state } = await startMockLink();
    await call(gatewayRequest(`/v1/links/callback?code=good-code&state=${state}`, { bearer: null }));
    const response = await call(gatewayRequest(`/v1/links/${linkId}`, { method: "DELETE" }));
    expect(response.status).toBe(204);
    expect(requests.some((r) => r.method === "DELETE" && r.url.pathname === "/sessions/sess-1")).toBe(true);
    expect((await call(gatewayRequest(`/v1/links/${linkId}`))).status).toBe(404);
    expect((await call(gatewayRequest("/v1/links/not-a-uuid"))).status).toBe(404);
  });
});
