import { EnableBankingError } from "./errors";
import type { JwtProvider } from "./jwt";
import type { PsuContext } from "./types";

interface RequestOptions {
  query?: Record<string, string | undefined>;
  body?: unknown;
  psu?: PsuContext;
}

export interface AspspDescriptor {
  name: string;
  country: string;
  maximum_consent_validity?: number;
  psu_types?: string[];
  sandbox?: boolean;
  beta?: boolean;
  logo?: string;
}

export interface AuthorizationResponse {
  url: string;
  authorization_id: string;
  psu_id_hash?: string;
}

export interface SessionResponse {
  session_id: string;
  accounts: unknown[];
  access?: { valid_until?: string };
  aspsp?: { name: string; country: string };
  psu_type?: string;
}

export class EnableBankingClient {
  constructor(
    private readonly baseUrl: string,
    private readonly jwt: JwtProvider,
    private readonly fetchFn: typeof fetch,
  ) {}

  async request<T>(method: string, path: string, options: RequestOptions = {}): Promise<T> {
    const url = new URL(path, this.baseUrl);
    for (const [key, value] of Object.entries(options.query ?? {})) {
      if (value !== undefined) {
        url.searchParams.set(key, value);
      }
    }
    const headers: Record<string, string> = {
      Authorization: `Bearer ${await this.jwt.token()}`,
      Accept: "application/json",
    };
    if (options.body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    if (options.psu) {
      headers["Psu-Ip-Address"] = options.psu.ipAddress;
      headers["Psu-User-Agent"] = options.psu.userAgent;
    }
    const response = await this.fetchFn(url.toString(), {
      method,
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });
    const text = await response.text();
    let payload: unknown = null;
    if (text) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = { raw: text };
      }
    }
    if (!response.ok) {
      throw EnableBankingError.fromResponse(response.status, payload);
    }
    return payload as T;
  }

  listAspsps(query: Record<string, string | undefined>): Promise<{ aspsps: AspspDescriptor[] }> {
    return this.request("GET", "/aspsps", { query });
  }

  startAuthorization(body: Record<string, unknown>): Promise<AuthorizationResponse> {
    return this.request("POST", "/auth", { body });
  }

  createSession(code: string): Promise<SessionResponse> {
    return this.request("POST", "/sessions", { body: { code } });
  }

  deleteSession(sessionId: string): Promise<unknown> {
    return this.request("DELETE", `/sessions/${encodeURIComponent(sessionId)}`);
  }

  balances(accountUid: string, psu?: PsuContext): Promise<unknown> {
    return this.request("GET", `/accounts/${encodeURIComponent(accountUid)}/balances`, { psu });
  }

  transactions(accountUid: string, query: Record<string, string | undefined>, psu?: PsuContext): Promise<unknown> {
    return this.request("GET", `/accounts/${encodeURIComponent(accountUid)}/transactions`, { query, psu });
  }
}
