import { getBalances, getTransactions } from "./accounts";
import { handleAppleAuth } from "./apple-auth";
import { isAuthorized } from "./auth";
import { EnableBankingClient } from "./enablebanking";
import { GatewayError, errorResponse } from "./errors";
import { json } from "./http";
import { JwtProvider } from "./jwt";
import { privacyPage, termsPage, LEGAL_PAGE_HEADERS } from "./legal";
import { deleteLink, getLink, handleCallback, startLink } from "./links";
import type { Deps, Env } from "./types";
import { UserAccess, usesUserSessions, type UserPrincipal } from "./user-access";

export { IdentityVault } from "./identity-vault";

const jwtProviders = new Map<string, JwtProvider>();
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Shape-only checks so a misconfigured secret can be spotted without ever exposing its value.
function configDiagnostics(env: Env) {
  const pem = env.EB_PRIVATE_KEY_PEM ?? "";
  const privateKeyFormat = pem.includes("BEGIN PRIVATE KEY")
    ? "pkcs8"
    : pem.includes("BEGIN RSA PRIVATE KEY")
      ? "pkcs1"
      : pem
        ? "unrecognized"
        : "missing";
  return {
    appId: env.EB_APP_ID ? (UUID_PATTERN.test(env.EB_APP_ID.trim()) ? "uuid" : "not-a-uuid") : "missing",
    appIdShape: env.EB_APP_ID ? `${env.EB_APP_ID.replace(/[0-9a-f]/gi, "x")} (len=${env.EB_APP_ID.length})` : null,
    privateKey: privateKeyFormat,
    bearerToken: env.GATEWAY_BEARER_TOKEN ? "set" : "missing",
    accountHashSalt: env.ACCOUNT_HASH_SALT ? "set" : "missing",
    kvBinding: env.LINKS ? "bound" : "missing",
    authRateLimiter: env.AUTH_RATE_LIMITER ? "bound" : "missing",
  };
}

function clientFor(env: Env, deps: Deps): EnableBankingClient {
  let provider = jwtProviders.get(env.EB_APP_ID);
  if (!provider) {
    provider = new JwtProvider(env.EB_APP_ID, env.EB_PRIVATE_KEY_PEM, deps.now);
    jwtProviders.set(env.EB_APP_ID, provider);
  }
  return new EnableBankingClient(env.EB_BASE_URL, provider, deps.fetch);
}

export async function route(request: Request, env: Env, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const { method } = request;

  if (method === "GET" && url.pathname === "/healthz") {
    return json({ ok: true, environment: env.ENVIRONMENT });
  }
  if (method === "GET" && (url.pathname === "/privacy" || url.pathname === "/terms")) {
    const html = url.pathname === "/privacy" ? privacyPage(env.DATA_PROTECTION_EMAIL) : termsPage(env.DATA_PROTECTION_EMAIL);
    return new Response(html, { headers: LEGAL_PAGE_HEADERS });
  }
  if (segments[0] !== "v1") {
    throw new GatewayError(404, "not_found");
  }

  const client = clientFor(env, deps);
  const multiUser = usesUserSessions(env);
  const userAccess = new UserAccess(env);
  if (multiUser && method === "POST" && ["/v1/auth/apple/challenge", "/v1/auth/apple/session"].includes(url.pathname)) {
    return handleAppleAuth(request, env, deps);
  }
  if (method === "GET" && segments[1] === "links" && segments[2] === "callback" && segments.length === 3) {
    return handleCallback(request, env, client);
  }
  const diagnostics = method === "GET" && segments[1] === "diagnostics" && segments.length === 2;
  let principal: UserPrincipal | null = null;
  const authorized = multiUser && !diagnostics
    ? !!(principal = await userAccess.authenticate(request))
    : isAuthorized(request, [env.GATEWAY_BEARER_TOKEN, env.GATEWAY_BEARER_TOKEN_PREVIOUS]);
  if (!authorized) {
    // Failed attempts are throttled per client address so the static bearer cannot be brute-forced.
    const clientKey = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const verdict = await env.AUTH_RATE_LIMITER?.limit({ key: clientKey });
    if (verdict && !verdict.success) {
      throw new GatewayError(429, "too_many_requests");
    }
    throw new GatewayError(401, "unauthorized");
  }

  if (diagnostics) {
    return json({ environment: env.ENVIRONMENT, config: configDiagnostics(env) });
  }

  if (multiUser && principal && segments[1] === "session" && segments.length === 2) {
    if (method === "GET") return json({ userId: principal.userId });
    if (method === "DELETE") {
      await userAccess.revoke(principal);
      return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
    }
  }

  if (segments[1] === "links") {
    if (method === "POST" && segments.length === 2) {
      return startLink(request, env, client, deps, principal ?? undefined);
    }
    if (segments.length === 3 && segments[2]) {
      if (method === "GET") {
        return getLink(env, segments[2], deps, principal ?? undefined);
      }
      if (method === "DELETE") {
        return deleteLink(env, segments[2], client, principal ?? undefined);
      }
    }
  }
  if (method === "GET" && segments[1] === "aspsps" && segments.length === 2) {
    return json(
      await client.listAspsps({
        country: url.searchParams.get("country") ?? undefined,
        psu_type: url.searchParams.get("psu_type") ?? undefined,
      }),
    );
  }
  if (method === "GET" && segments[1] === "accounts" && segments.length === 4 && segments[2]) {
    if (multiUser) {
      if (!principal) throw new GatewayError(401, "unauthorized");
      await userAccess.requireAccount(principal.userId, segments[2]);
    }
    if (segments[3] === "balances") {
      return getBalances(request, client, segments[2]);
    }
    if (segments[3] === "transactions") {
      return getTransactions(request, client, segments[2]);
    }
  }
  throw new GatewayError(404, "not_found");
}

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  try {
    return await route(request, env, deps);
  } catch (error) {
    return errorResponse(error);
  }
}

const liveDeps: Deps = { fetch: (input, init) => fetch(input, init), now: () => Date.now() };

const worker: ExportedHandler<Env> = {
  async fetch(request, env) {
    return handle(request, env, liveDeps);
  },
};

export default worker;
