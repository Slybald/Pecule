import { describe, expect, it } from "vitest";
import { EnableBankingError, GatewayError, errorResponse } from "../src/errors";

const bodyOf = async (response: Response) => (await response.json()) as Record<string, unknown>;

describe("errorResponse", () => {
  it("maps an expired Enable Banking session to 409 session_expired without the upstream body", async () => {
    const response = errorResponse(EnableBankingError.fromResponse(401, { error: "EXPIRED_SESSION", message: "IBAN FR76…" }));
    expect(response.status).toBe(409);
    const body = await bodyOf(response);
    expect(body.error).toBe("session_expired");
    expect(body.upstream).toBeUndefined();
    expect(JSON.stringify(body)).not.toContain("FR76");
  });

  it.each(["REVOKED_SESSION", "CLOSED_SESSION"])("maps %s like an expired session: the only way out is a new authorization", async (code) => {
    const response = errorResponse(EnableBankingError.fromResponse(401, { error: code }));
    expect(response.status).toBe(409);
    expect((await bodyOf(response)).error).toBe("session_expired");
  });

  it("maps bank rate limiting to 429 with a retry hint", async () => {
    const response = errorResponse(EnableBankingError.fromResponse(429, { error: "ASPSP_RATE_LIMIT_EXCEEDED" }));
    expect(response.status).toBe(429);
    const body = await bodyOf(response);
    expect(body.error).toBe("rate_limited");
    expect(body.retryAfterSeconds).toBe(6 * 3600);
  });

  it("maps upstream validation errors to 400 and other failures to 502", async () => {
    const validation = errorResponse(EnableBankingError.fromResponse(422, { error: "PSU_HEADER_NOT_PROVIDED" }));
    expect(validation.status).toBe(400);
    expect((await bodyOf(validation)).upstreamCode).toBe("PSU_HEADER_NOT_PROVIDED");
    const upstream = errorResponse(EnableBankingError.fromResponse(503, { raw: "down" }));
    expect(upstream.status).toBe(502);
    const upstreamBody = await bodyOf(upstream);
    expect(upstreamBody.upstreamCode).toBe("HTTP_503");
    expect(upstreamBody.upstream).toBeUndefined();
  });

  it("derives the code from 'error' or numeric 'code' fields", () => {
    expect(EnableBankingError.fromResponse(400, { code: 400, message: "bad" }).code).toBe("400");
    expect(EnableBankingError.fromResponse(401, null).code).toBe("HTTP_401");
  });

  it("serialises gateway errors and hides unexpected ones", async () => {
    const gateway = errorResponse(new GatewayError(404, "link_not_found"));
    expect(gateway.status).toBe(404);
    expect((await bodyOf(gateway)).error).toBe("link_not_found");
    const unexpected = errorResponse(new Error("boom"));
    expect(unexpected.status).toBe(500);
    expect(await bodyOf(unexpected)).toEqual({ error: "internal_error" });
  });
});
