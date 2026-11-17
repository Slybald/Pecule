export interface Env {
  // Existing single-user deployments remain explicit; multi-user mode has no bearer fallback.
  AUTH_MODE?: "single_user" | "multi_user";
  IDENTITY_VAULT?: DurableObjectNamespace;
  APPLE_CLIENT_ID?: string;
  LINKS: KVNamespace;
  ENVIRONMENT: string;
  EB_BASE_URL: string;
  APP_CALLBACK_URL: string;
  GATEWAY_PUBLIC_URL?: string;
  DATA_PROTECTION_EMAIL: string;
  EB_APP_ID: string;
  EB_PRIVATE_KEY_PEM: string;
  GATEWAY_BEARER_TOKEN: string;
  GATEWAY_BEARER_TOKEN_PREVIOUS?: string;
  ACCOUNT_HASH_SALT?: string;
  AUTH_RATE_LIMITER?: RateLimiter;
}

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Deps {
  fetch: typeof fetch;
  now: () => number;
}

export interface Aspsp {
  name: string;
  country: string;
}

export type LinkStatus = "pending" | "authorized" | "failed";

export interface StoredLink {
  ownerUserID?: string;
  id: string;
  status: LinkStatus;
  aspsp: Aspsp;
  psuType: string;
  state: string;
  createdAt: string;
  sessionId?: string;
  validUntil?: string;
  accounts?: unknown[];
  errorCode?: string;
}

export interface PsuContext {
  ipAddress: string;
  userAgent: string;
}
