import { presentedBearer } from "./auth";
import { GatewayError } from "./errors";
import type { LoginChallenge, OwnedLink, UserSession, VaultCommand } from "./identity-vault";
import type { Env } from "./types";

export interface UserPrincipal { userId: string; tokenHash: string }

export function usesUserSessions(env: Env): boolean {
  if (env.AUTH_MODE === "multi_user") return true;
  if (env.AUTH_MODE === undefined || env.AUTH_MODE === "single_user") return false;
  throw new GatewayError(503, "authentication_unavailable");
}

export async function tokenDigest(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

export class UserAccess {
  constructor(private readonly env: Env) {}

  async issueChallenge(): Promise<LoginChallenge> {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const nonce = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
    return this.command({ operation: "challenge.issue", challengeId: crypto.randomUUID(), nonce });
  }

  consumeChallenge(challengeId: string): Promise<LoginChallenge | null> {
    return this.command({ operation: "challenge.consume", challengeId });
  }

  private async command<T>(command: VaultCommand): Promise<T> {
    const namespace = this.env.IDENTITY_VAULT;
    if (!namespace) throw new GatewayError(503, "authentication_unavailable");
    const stub = namespace.get(namespace.idFromName("lifeos-identity-v1"));
    const response = await stub.fetch(new Request("https://identity.internal/command", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(command),
    }));
    if (!response.ok) {
      const result = await response.json<{ error?: string }>();
      throw new GatewayError(response.status, result.error ?? "authentication_unavailable");
    }
    return response.json<T>();
  }

  // Internal use only: never wire this directly to a body containing a client-supplied userId.
  async issueVerifiedSession(verifiedUserId: string, lifetimeSeconds = 3600): Promise<{ token: string; session: UserSession }> {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const token = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
    const session = await this.command<UserSession>({ operation: "session.issue", userId: verifiedUserId,
      tokenHash: await tokenDigest(token), lifetimeSeconds });
    return { token, session };
  }

  async authenticate(request: Request): Promise<UserPrincipal | null> {
    // Fail closed if multi-user mode has not been provisioned; no legacy token fallback.
    if (!this.env.IDENTITY_VAULT) throw new GatewayError(503, "authentication_unavailable");
    const token = presentedBearer(request);
    if (!token || !/^[a-f0-9]{64}$/.test(token)) return null;
    const tokenHash = await tokenDigest(token);
    const session = await this.command<UserSession | null>({ operation: "session.resolve", tokenHash });
    return session ? { userId: session.userId, tokenHash } : null;
  }

  revoke(principal: UserPrincipal): Promise<unknown> {
    return this.command({ operation: "session.revoke", tokenHash: principal.tokenHash });
  }

  createLink(link: OwnedLink): Promise<unknown> { return this.command({ operation: "link.create", link }); }
  updateLink(link: OwnedLink): Promise<unknown> { return this.command({ operation: "link.update", link }); }
  getLink(userId: string, linkId: string): Promise<OwnedLink> { return this.command({ operation: "link.get", userId, linkId }); }
  deleteLink(userId: string, linkId: string): Promise<unknown> { return this.command({ operation: "link.delete", userId, linkId }); }
  consumeCallback(state: string): Promise<OwnedLink | null> { return this.command({ operation: "callback.consume", state }); }

  async requireAccount(userId: string, accountUid: string): Promise<void> {
    if (!await this.command<boolean>({ operation: "account.check", userId, accountUid })) {
      throw new GatewayError(404, "account_not_found");
    }
  }
}
