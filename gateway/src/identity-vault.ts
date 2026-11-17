import { GatewayError, errorResponse } from "./errors";
import { json } from "./http";
import type { StoredLink } from "./types";

export interface UserSession {
  userId: string;
  issuedAt: number;
  expiresAt: number;
}

export type OwnedLink = StoredLink & { ownerUserID: string };

export type VaultCommand =
  | { operation: "challenge.issue"; challengeId: string; nonce: string }
  | { operation: "challenge.consume"; challengeId: string }
  | { operation: "session.issue"; tokenHash: string; userId: string; lifetimeSeconds: number }
  | { operation: "session.resolve"; tokenHash: string }
  | { operation: "session.revoke"; tokenHash: string }
  | { operation: "link.create"; link: OwnedLink }
  | { operation: "link.get"; userId: string; linkId: string }
  | { operation: "link.update"; link: OwnedLink }
  | { operation: "link.delete"; userId: string; linkId: string }
  | { operation: "callback.consume"; state: string }
  | { operation: "account.check"; userId: string; accountUid: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const OWNER = /^[A-Za-z0-9_-]{1,128}$/;
const HASH = /^[a-f0-9]{64}$/;
const STATE_LIFETIME_MS = 15 * 60 * 1000;
const PENDING_LIFETIME_MS = 60 * 60 * 1000;
const FAILED_LIFETIME_MS = 24 * 60 * 60 * 1000;

interface LinkEntry { link: OwnedLink; expiresAt?: number }
interface CallbackEntry { userId: string; linkId: string; expiresAt: number }
export interface LoginChallenge { challengeId: string; nonce: string; expiresAt: number }

function linkKey(userId: string, id: string): string {
  if (typeof userId !== "string" || typeof id !== "string" || !OWNER.test(userId) || !UUID.test(id)) throw new GatewayError(404, "link_not_found");
  return `link:${userId}:${id}`;
}

function linkEntry(link: OwnedLink, now: number): LinkEntry {
  const lifetime = link.status === "pending" ? PENDING_LIFETIME_MS : link.status === "failed" ? FAILED_LIFETIME_MS : undefined;
  return { link, expiresAt: lifetime === undefined ? undefined : now + lifetime };
}

function activeEntry(entry: LinkEntry | undefined, now: number): OwnedLink | null {
  return entry && (entry.expiresAt === undefined || entry.expiresAt > now) ? entry.link : null;
}

// Internal binding only, never a public HTTP route. Session issuance must be called
// only after server-side identity verification by the Apple adapter.
// The storage transaction makes callback consumption and revocation strongly consistent.
export class IdentityVault {
  constructor(
    private readonly state: DurableObjectState,
    _env?: unknown,
    private readonly now: () => number = Date.now,
  ) {}

  async fetch(request: Request): Promise<Response> {
    try {
      if (request.method !== "POST") throw new GatewayError(405, "method_not_allowed");
      const command = await request.json<VaultCommand>();
      if (!command || typeof command !== "object") throw new GatewayError(400, "invalid_request");
      return await this.state.storage.transaction(async (storage) => {
        const now = this.now();
        switch (command.operation) {
          case "challenge.issue": {
            if (!UUID.test(command.challengeId) || !HASH.test(command.nonce)) throw new GatewayError(400, "invalid_challenge");
            const key = `challenge:${command.challengeId}`;
            if (await storage.get(key)) throw new GatewayError(409, "challenge_exists");
            const challenge: LoginChallenge = { challengeId: command.challengeId, nonce: command.nonce, expiresAt: now + 5 * 60 * 1000 };
            await storage.put(key, challenge);
            return json(challenge, 201);
          }
          case "challenge.consume": {
            if (!UUID.test(command.challengeId)) return json(null);
            const key = `challenge:${command.challengeId}`;
            const challenge = await storage.get<LoginChallenge>(key);
            if (!challenge) return json(null);
            await storage.delete(key);
            return json(challenge.expiresAt > now ? challenge : null);
          }
          case "session.issue": {
            if (typeof command.tokenHash !== "string" || typeof command.userId !== "string"
              || !HASH.test(command.tokenHash) || !OWNER.test(command.userId)
              || !Number.isSafeInteger(command.lifetimeSeconds) || command.lifetimeSeconds < 60 || command.lifetimeSeconds > 86400) {
              throw new GatewayError(400, "invalid_session");
            }
            const key = `session:${command.tokenHash}`;
            if (await storage.get(key)) throw new GatewayError(409, "session_exists");
            const session: UserSession = { userId: command.userId, issuedAt: now, expiresAt: now + command.lifetimeSeconds * 1000 };
            await storage.put(key, session);
            return json(session, 201);
          }
          case "session.resolve": {
            if (!HASH.test(command.tokenHash)) return json(null);
            const key = `session:${command.tokenHash}`;
            const session = await storage.get<UserSession>(key);
            if (!session || session.expiresAt <= now) {
              if (session) await storage.delete(key);
              return json(null);
            }
            return json(session);
          }
          case "session.revoke": {
            if (!HASH.test(command.tokenHash)) throw new GatewayError(400, "invalid_session");
            await storage.delete(`session:${command.tokenHash}`);
            return json({ revoked: true });
          }
          case "link.create": {
            const { link } = command;
            const key = linkKey(link.ownerUserID, link.id);
            if (link.status !== "pending" || !UUID.test(link.state) || link.sessionId || link.accounts?.length) {
              throw new GatewayError(400, "invalid_link");
            }
            if (await storage.get(key) || await storage.get(`callback:${link.state}`)) throw new GatewayError(409, "link_exists");
            await storage.put(key, linkEntry(link, now));
            await storage.put(`callback:${link.state}`, {
              userId: link.ownerUserID, linkId: link.id, expiresAt: now + STATE_LIFETIME_MS,
            } satisfies CallbackEntry);
            return json({ created: true }, 201);
          }
          case "link.get": {
            const link = activeEntry(await storage.get<LinkEntry>(linkKey(command.userId, command.linkId)), now);
            if (!link) throw new GatewayError(404, "link_not_found");
            return json(link);
          }
          case "link.update": {
            const { link } = command;
            const key = linkKey(link.ownerUserID, link.id);
            const current = activeEntry(await storage.get<LinkEntry>(key), now);
            // A late callback must never recreate a link deleted by its owner.
            if (!current) throw new GatewayError(404, "link_not_found");
            if (current.status !== "pending" || current.state !== link.state || link.status === "pending"
              || await storage.get(`callback:${link.state}`)) {
              throw new GatewayError(409, "invalid_link_transition");
            }
            await storage.put(key, linkEntry(link, now));
            return json({ updated: true });
          }
          case "link.delete": {
            const key = linkKey(command.userId, command.linkId);
            const current = activeEntry(await storage.get<LinkEntry>(key), now);
            if (!current) throw new GatewayError(404, "link_not_found");
            await storage.delete([key, `callback:${current.state}`]);
            return json({ deleted: true });
          }
          case "callback.consume": {
            if (!UUID.test(command.state)) return json(null);
            const key = `callback:${command.state}`;
            const callback = await storage.get<CallbackEntry>(key);
            if (!callback) return json(null);
            await storage.delete(key);
            if (callback.expiresAt <= now) return json(null);
            const link = activeEntry(await storage.get<LinkEntry>(linkKey(callback.userId, callback.linkId)), now);
            return json(link?.status === "pending" && link.state === command.state ? link : null);
          }
          case "account.check": {
            if (!OWNER.test(command.userId) || !command.accountUid || command.accountUid.length > 512) return json(false);
            // Bounded by the number of a beta user's linked banks, not transaction history.
            // No global UID-to-owner fallback: the same physical account may have two owners.
            const entries = await storage.list<LinkEntry>({ prefix: `link:${command.userId}:` });
            const allowed = [...entries.values()].some((entry) => {
              const link = activeEntry(entry, now);
              const expiry = link?.validUntil ? Date.parse(link.validUntil) : NaN;
              return link?.status === "authorized" && Number.isFinite(expiry) && expiry > now && !!link.sessionId
                && link.accounts?.some((account) => !!account && typeof account === "object"
                  && (account as { uid?: unknown }).uid === command.accountUid);
            });
            return json(allowed);
          }
          default: throw new GatewayError(400, "invalid_request");
        }
      });
    } catch (error) {
      return errorResponse(error);
    }
  }
}
