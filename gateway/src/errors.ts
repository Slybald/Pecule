import { json } from "./http";

const RATE_LIMIT_RETRY_SECONDS = 6 * 3600;

export class EnableBankingError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly upstream: unknown,
  ) {
    super(`Enable Banking ${status} ${code}`);
  }

  static fromResponse(status: number, body: unknown): EnableBankingError {
    let code = `HTTP_${status}`;
    if (body && typeof body === "object") {
      const record = body as Record<string, unknown>;
      if (typeof record.error === "string") {
        code = record.error;
      } else if (typeof record.code === "string" || typeof record.code === "number") {
        code = String(record.code);
      }
    }
    return new EnableBankingError(status, code, body);
  }
}

export class GatewayError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly detail?: unknown,
  ) {
    super(code);
  }
}

export function errorResponse(error: unknown): Response {
  if (error instanceof GatewayError) {
    return json({ error: error.code, detail: error.detail ?? null }, error.status);
  }
  // Upstream bodies stay server-side: they can carry account identifiers and provider internals.
  if (error instanceof EnableBankingError) {
    // A session revoked or closed on the bank side is as dead as an expired one: the app offers a new authorization.
    if (error.status === 401 && ["EXPIRED_SESSION", "REVOKED_SESSION", "CLOSED_SESSION"].includes(error.code)) {
      return json({ error: "session_expired" }, 409);
    }
    if (error.status === 429) {
      return json({ error: "rate_limited", retryAfterSeconds: RATE_LIMIT_RETRY_SECONDS }, 429);
    }
    if (error.status === 422) {
      return json({ error: "bad_request", upstreamCode: error.code }, 400);
    }
    return json({ error: "upstream_error", upstreamStatus: error.status, upstreamCode: error.code }, 502);
  }
  console.error("Unhandled gateway error", error instanceof Error ? error.message : String(error));
  return json({ error: "internal_error" }, 500);
}
