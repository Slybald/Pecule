import { beforeEach, describe, expect, it } from "vitest";
import { handle } from "../src/index";
import type { Deps, Env } from "../src/types";
import { FakeKV, type RecordedRequest, fakeFetch, gatewayRequest, jsonResponse, makeEnv } from "./helpers";

let env: Env;
let requests: RecordedRequest[];
let deps: Deps;
let upstreamStatus: number;

const call = (request: Request) => handle(request, env, deps);
const upstream = () => requests[requests.length - 1] as RecordedRequest;

beforeEach(async () => {
  upstreamStatus = 200;
  ({ env } = await makeEnv(new FakeKV()));
  const fake = fakeFetch({
    "GET /accounts/acc-1/balances": () =>
      upstreamStatus === 200
        ? jsonResponse({ balances: [{ balance_type: "CLBD", balance_amount: { amount: "1234.56", currency: "EUR" } }] })
        : jsonResponse({ error: upstreamStatus === 401 ? "EXPIRED_SESSION" : "ASPSP_RATE_LIMIT_EXCEEDED" }, upstreamStatus),
    "GET /accounts/acc-1/transactions": () => jsonResponse({ transactions: [], continuation_key: null }),
  });
  requests = fake.requests;
  deps = { fetch: fake.fetch, now: () => Date.now() };
});

describe("account proxies", () => {
  it("proxies balances without PSU headers by default", async () => {
    const response = await call(gatewayRequest("/v1/accounts/acc-1/balances"));
    expect(response.status).toBe(200);
    expect(((await response.json()) as { balances: unknown[] }).balances).toHaveLength(1);
    expect(upstream().headers["Psu-Ip-Address"]).toBeUndefined();
    expect(upstream().headers["Psu-User-Agent"]).toBeUndefined();
    expect(upstream().headers.Authorization).toMatch(/^Bearer /);
  });

  it("forwards PSU headers for attended calls when the client identity is known", async () => {
    await call(
      gatewayRequest("/v1/accounts/acc-1/balances?attended=1", {
        headers: { "CF-Connecting-IP": "203.0.113.7", "User-Agent": "Pecule/1.0 (iPhone)" },
      }),
    );
    expect(upstream().headers["Psu-Ip-Address"]).toBe("203.0.113.7");
    expect(upstream().headers["Psu-User-Agent"]).toBe("Pecule/1.0 (iPhone)");

    await call(gatewayRequest("/v1/accounts/acc-1/balances?attended=1", { headers: { "User-Agent": "Pecule/1.0" } }));
    expect(upstream().headers["Psu-Ip-Address"]).toBeUndefined();
  });

  it("sends no PSU headers unless the call is marked attended, even when IP and agent are present", async () => {
    const headers = { "CF-Connecting-IP": "203.0.113.7", "User-Agent": "Pecule/1.0 (iPhone)" };
    for (const path of ["/v1/accounts/acc-1/balances", "/v1/accounts/acc-1/transactions", "/v1/accounts/acc-1/balances?attended=0"]) {
      await call(gatewayRequest(path, { headers }));
      expect(upstream().headers["Psu-Ip-Address"]).toBeUndefined();
      expect(upstream().headers["Psu-User-Agent"]).toBeUndefined();
    }
  });

  it("whitelists transaction query parameters", async () => {
    await call(gatewayRequest("/v1/accounts/acc-1/transactions?date_from=2026-01-01&continuation_key=k1&foo=bar&attended=1"));
    const url = upstream().url;
    expect(url.searchParams.get("date_from")).toBe("2026-01-01");
    expect(url.searchParams.get("continuation_key")).toBe("k1");
    expect(url.searchParams.has("foo")).toBe(false);
    expect(url.searchParams.has("attended")).toBe(false);
  });

  it("maps expired sessions and rate limits to gateway error codes", async () => {
    upstreamStatus = 401;
    const expired = await call(gatewayRequest("/v1/accounts/acc-1/balances"));
    expect(expired.status).toBe(409);
    expect(((await expired.json()) as { error: string }).error).toBe("session_expired");

    upstreamStatus = 429;
    expect((await call(gatewayRequest("/v1/accounts/acc-1/balances"))).status).toBe(429);
  });

  it("returns 404 for unknown routes and 401 without bearer", async () => {
    expect((await call(gatewayRequest("/v1/accounts/acc-1/unknown"))).status).toBe(404);
    expect((await call(gatewayRequest("/v1/accounts/acc-1/balances", { bearer: null }))).status).toBe(401);
  });
});
