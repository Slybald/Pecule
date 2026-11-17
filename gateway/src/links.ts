import type { EnableBankingClient } from "./enablebanking";
import { EnableBankingError, GatewayError } from "./errors";
import { json, readJsonBody, redirect } from "./http";
import type { Deps, Env, StoredLink } from "./types";
import type { OwnedLink } from "./identity-vault";
import { UserAccess, usesUserSessions, type UserPrincipal } from "./user-access";

const STATE_TTL_SECONDS = 15 * 60;
const PENDING_LINK_TTL_SECONDS = 60 * 60;
const FAILED_LINK_TTL_SECONDS = 24 * 60 * 60;
const DEFAULT_CONSENT_SECONDS = 90 * 24 * 3600;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const linkKey = (id: string) => `link:${id}`;
const stateKey = (state: string) => `state:${state}`;

export interface NormalizedAccount {
  uid: string | null;
  identificationHash: string | null;
  iban: string | null;
  name: string | null;
  currency: string | null;
  product: string | null;
  cashAccountType: string | null;
  usage: string | null;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

export function maskIBAN(iban: string | null): string | null {
  if (!iban) {
    return null;
  }
  const compact = iban.replace(/\s+/g, "").toUpperCase();
  return compact.length > 8 ? `${compact.slice(0, 4)}…${compact.slice(-4)}` : compact;
}

// Stable substitute for banks that omit identification_hash: the app keys accounts on it, so it must never change.
export async function hashIBAN(iban: string, salt: string): Promise<string> {
  const normalized = iban.replace(/\s+/g, "").toUpperCase();
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}|${normalized}`));
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `lifeos-sha256:${hex}`;
}

export function normalizeAccount(raw: unknown): NormalizedAccount {
  const record = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  if ("identificationHash" in record) {
    const projected = record as unknown as NormalizedAccount;
    return { ...projected, iban: maskIBAN(projected.iban) };
  }
  const accountId = record.account_id && typeof record.account_id === "object" ? (record.account_id as Record<string, unknown>) : {};
  return {
    uid: stringOrNull(record.uid),
    identificationHash: stringOrNull(record.identification_hash),
    iban: maskIBAN(stringOrNull(accountId.iban)),
    name: stringOrNull(record.name),
    currency: stringOrNull(record.currency),
    product: stringOrNull(record.product),
    cashAccountType: stringOrNull(record.cash_account_type),
    usage: stringOrNull(record.usage),
  };
}

// What gets persisted in KV: no full IBAN, and a hash for every account that has one.
export async function projectAccount(raw: unknown, salt: string | undefined): Promise<NormalizedAccount> {
  const record = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const accountId = record.account_id && typeof record.account_id === "object" ? (record.account_id as Record<string, unknown>) : {};
  const fullIBAN = stringOrNull(accountId.iban);
  let identificationHash = stringOrNull(record.identification_hash);
  if (!identificationHash && fullIBAN && salt) {
    identificationHash = await hashIBAN(fullIBAN, salt);
  }
  return {
    uid: stringOrNull(record.uid),
    identificationHash,
    iban: maskIBAN(fullIBAN),
    name: stringOrNull(record.name),
    currency: stringOrNull(record.currency),
    product: stringOrNull(record.product),
    cashAccountType: stringOrNull(record.cash_account_type),
    usage: stringOrNull(record.usage),
  };
}

export function publicLinkView(link: StoredLink, nowMs: number) {
  const expired = link.status === "authorized" && link.validUntil !== undefined && Date.parse(link.validUntil) <= nowMs;
  return {
    id: link.id,
    status: expired ? "expired" : link.status,
    aspsp: link.aspsp,
    psuType: link.psuType,
    createdAt: link.createdAt,
    validUntil: link.validUntil ?? null,
    errorCode: link.errorCode ?? null,
    accounts: (link.accounts ?? []).map(normalizeAccount),
  };
}

async function loadLink(env: Env, id: string, principal?: UserPrincipal): Promise<StoredLink> {
  if (usesUserSessions(env)) {
    if (!principal) throw new GatewayError(401, "unauthorized");
    return new UserAccess(env).getLink(principal.userId, id);
  }
  if (!UUID_PATTERN.test(id)) {
    throw new GatewayError(404, "link_not_found");
  }
  const link = await env.LINKS.get<StoredLink>(linkKey(id), "json");
  if (!link) {
    throw new GatewayError(404, "link_not_found");
  }
  return link;
}

async function saveLink(env: Env, link: StoredLink): Promise<void> {
  if (usesUserSessions(env)) {
    if (!link.ownerUserID) throw new GatewayError(404, "link_not_found");
    await new UserAccess(env).updateLink(link as OwnedLink);
    return;
  }
  const ttl = link.status === "pending" ? PENDING_LINK_TTL_SECONDS : link.status === "failed" ? FAILED_LINK_TTL_SECONDS : undefined;
  const options = ttl === undefined ? undefined : { expirationTtl: ttl };
  await env.LINKS.put(linkKey(link.id), JSON.stringify(link), options);
}

export async function startLink(request: Request, env: Env, client: EnableBankingClient, deps: Deps, principal?: UserPrincipal): Promise<Response> {
  if (usesUserSessions(env) && !principal) throw new GatewayError(401, "unauthorized");
  const body = await readJsonBody(request);
  const aspspName = typeof body.aspspName === "string" ? body.aspspName.trim() : "";
  const aspspCountry = typeof body.aspspCountry === "string" ? body.aspspCountry.trim().toUpperCase() : "";
  const psuType = body.psuType === "business" ? "business" : "personal";
  if (!aspspName || !/^[A-Z]{2}$/.test(aspspCountry)) {
    throw new GatewayError(400, "invalid_request", "aspspName and aspspCountry (ISO 3166-1 alpha-2) are required");
  }

  const { aspsps } = await client.listAspsps({ country: aspspCountry, psu_type: psuType });
  const aspsp = aspsps.find((candidate) => candidate.name.toLowerCase() === aspspName.toLowerCase());
  if (!aspsp) {
    throw new GatewayError(404, "aspsp_not_found", { aspspName, aspspCountry, available: aspsps.map((a) => a.name) });
  }

  const requestedDays = typeof body.validityDays === "number" && body.validityDays > 0 ? body.validityDays : undefined;
  const maximumSeconds = aspsp.maximum_consent_validity ?? DEFAULT_CONSENT_SECONDS;
  const validitySeconds = requestedDays ? Math.min(requestedDays * 86400, maximumSeconds) : maximumSeconds;
  const nowMs = deps.now();
  const validUntil = new Date(nowMs + validitySeconds * 1000).toISOString();

  const link: StoredLink = {
    ...(principal ? { ownerUserID: principal.userId } : {}),
    id: crypto.randomUUID(),
    status: "pending",
    aspsp: { name: aspsp.name, country: aspsp.country },
    psuType,
    state: crypto.randomUUID(),
    createdAt: new Date(nowMs).toISOString(),
  };
  const redirectUrl = new URL("/v1/links/callback", env.GATEWAY_PUBLIC_URL || request.url).toString();
  const authorization = await client.startAuthorization({
    access: { valid_until: validUntil },
    aspsp: link.aspsp,
    state: link.state,
    redirect_url: redirectUrl,
    psu_type: psuType,
  });

  if (usesUserSessions(env)) {
    await new UserAccess(env).createLink(link as OwnedLink);
  } else {
    await saveLink(env, link);
    await env.LINKS.put(stateKey(link.state), link.id, { expirationTtl: STATE_TTL_SECONDS });
  }
  return json({ linkId: link.id, authUrl: authorization.url, validUntil, redirectUrl }, 201);
}

function appRedirect(env: Env, path: string, params: Record<string, string>): Response {
  const url = new URL(`${env.APP_CALLBACK_URL}/${path}`);
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }
  return redirect(url.toString());
}

export async function handleCallback(request: Request, env: Env, client: EnableBankingClient): Promise<Response> {
  const params = new URL(request.url).searchParams;
  const state = params.get("state") ?? "";
  // The route is anonymous: throttle per client address, then refuse anything that is not a generated state before touching KV.
  const verdict = await env.AUTH_RATE_LIMITER?.limit({ key: `callback:${request.headers.get("CF-Connecting-IP") ?? "unknown"}` });
  if (verdict && !verdict.success) throw new GatewayError(429, "too_many_requests");
  if (!UUID_PATTERN.test(state)) throw new GatewayError(400, "invalid_state");
  let link: StoredLink | null;
  if (usesUserSessions(env)) {
    link = await new UserAccess(env).consumeCallback(state);
  } else {
    const legacyLinkId = state ? await env.LINKS.get(stateKey(state)) : null;
    if (!legacyLinkId) return appRedirect(env, "error", { code: "invalid_state" });
    await env.LINKS.delete(stateKey(state));
    link = await env.LINKS.get<StoredLink>(linkKey(legacyLinkId), "json");
  }
  if (!link || link.state !== state) {
    return appRedirect(env, "error", { code: "invalid_state" });
  }
  const linkId = link.id;
  // A replayed callback must not create a second bank session or turn a finished link into a failure.
  if (link.status !== "pending") {
    return link.status === "authorized"
      ? appRedirect(env, "done", { linkId })
      : appRedirect(env, "error", { linkId, code: link.errorCode ?? "invalid_state" });
  }

  const upstreamError = params.get("error");
  const code = params.get("code");
  if (upstreamError || !code) {
    link.status = "failed";
    link.errorCode = upstreamError ?? "missing_code";
    await saveLink(env, link);
    return appRedirect(env, "error", { linkId, code: link.errorCode });
  }

  let createdSessionId: string | undefined;
  try {
    const session = await client.createSession(code);
    createdSessionId = session.session_id;
    link.status = "authorized";
    link.sessionId = session.session_id;
    link.validUntil = session.access?.valid_until;
    link.accounts = await Promise.all((session.accounts ?? []).map((account) => projectAccount(account, env.ACCOUNT_HASH_SALT)));
    delete link.errorCode;
    await saveLink(env, link);
    return appRedirect(env, "done", { linkId });
  } catch (error) {
    // The owner may have deleted the pending link while the bank was responding.
    // Never resurrect it; best-effort revoke a bank session we can no longer retain.
    if (createdSessionId) {
      try { await client.deleteSession(createdSessionId); }
      catch { console.error("Bank session cleanup failed after callback persistence failure"); }
    }
    if (error instanceof GatewayError && error.status === 404) {
      return appRedirect(env, "error", { code: "invalid_state" });
    }
    link.status = "failed";
    delete link.sessionId;
    delete link.accounts;
    link.errorCode = error instanceof EnableBankingError ? error.code : "session_creation_failed";
    await saveLink(env, link);
    return appRedirect(env, "error", { linkId, code: link.errorCode });
  }
}

export async function getLink(env: Env, id: string, deps: Deps, principal?: UserPrincipal): Promise<Response> {
  const link = await loadLink(env, id, principal);
  return json(publicLinkView(link, deps.now()));
}

export async function deleteLink(env: Env, id: string, client: EnableBankingClient, principal?: UserPrincipal): Promise<Response> {
  const link = await loadLink(env, id, principal);
  if (link.sessionId) {
    try {
      await client.deleteSession(link.sessionId);
    } catch (error) {
      const ignorable = error instanceof EnableBankingError && (error.status === 404 || error.code === "EXPIRED_SESSION");
      if (!ignorable) {
        throw error;
      }
    }
  }
  if (usesUserSessions(env)) {
    if (!principal) throw new GatewayError(401, "unauthorized");
    await new UserAccess(env).deleteLink(principal.userId, id);
  } else {
    await env.LINKS.delete(linkKey(id));
  }
  return new Response(null, { status: 204 });
}
