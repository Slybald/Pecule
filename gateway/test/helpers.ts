import { bytesToBase64 } from "../src/pem";
import type { Env } from "../src/types";

export class FakeKV {
  readonly store = new Map<string, { value: string; expiresAt?: number }>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  async get(key: string, type?: "text" | "json"): Promise<unknown> {
    const entry = this.store.get(key);
    if (!entry) {
      return null;
    }
    if (entry.expiresAt !== undefined && entry.expiresAt <= this.now()) {
      this.store.delete(key);
      return null;
    }
    return type === "json" ? JSON.parse(entry.value) : entry.value;
  }

  async put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void> {
    const expiresAt = options?.expirationTtl ? this.now() + options.expirationTtl * 1000 : undefined;
    this.store.set(key, { value, expiresAt });
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }
}

export function toPem(label: string, der: Uint8Array): string {
  const lines = bytesToBase64(der).match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

export async function generateTestKey(): Promise<{ privatePem: string; publicKey: CryptoKey; pkcs8: Uint8Array }> {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  return { privatePem: toPem("PRIVATE KEY", pkcs8), publicKey: pair.publicKey, pkcs8 };
}

export interface RecordedRequest {
  method: string;
  url: URL;
  headers: Record<string, string>;
  body: unknown;
}

export type FakeHandler = (request: RecordedRequest) => Response | Promise<Response>;

export function fakeFetch(handlers: Record<string, FakeHandler>): { fetch: typeof fetch; requests: RecordedRequest[] } {
  const requests: RecordedRequest[] = [];
  const fetchImpl = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(typeof input === "string" || input instanceof URL ? input.toString() : input.url);
    const method = (init?.method ?? "GET").toUpperCase();
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries((init?.headers as Record<string, string>) ?? {})) {
      headers[key] = value;
    }
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    const recorded = { method, url, headers, body };
    requests.push(recorded);
    const handler = handlers[`${method} ${url.pathname}`];
    if (!handler) {
      return new Response(JSON.stringify({ error: "NOT_FOUND" }), { status: 404 });
    }
    return handler(recorded);
  };
  return { fetch: fetchImpl as typeof fetch, requests };
}

export const jsonResponse = (data: unknown, status = 200): Response => new Response(JSON.stringify(data), { status });

export const TEST_BEARER = "test-bearer-token";
export const TEST_APP_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

export async function makeEnv(kv: FakeKV): Promise<{ env: Env; publicKey: CryptoKey }> {
  const { privatePem, publicKey } = await generateTestKey();
  const env: Env = {
    LINKS: kv as unknown as KVNamespace,
    ENVIRONMENT: "test",
    EB_BASE_URL: "https://eb.test",
    APP_CALLBACK_URL: "lifeos://link",
    DATA_PROTECTION_EMAIL: "privacy@example.test",
    EB_APP_ID: TEST_APP_ID,
    EB_PRIVATE_KEY_PEM: privatePem,
    GATEWAY_BEARER_TOKEN: TEST_BEARER,
    ACCOUNT_HASH_SALT: "test-salt",
  };
  return { env, publicKey };
}

export function gatewayRequest(path: string, init: RequestInit & { bearer?: string | null } = {}): Request {
  const headers = new Headers(init.headers);
  const bearer = init.bearer === undefined ? TEST_BEARER : init.bearer;
  if (bearer) {
    headers.set("Authorization", `Bearer ${bearer}`);
  }
  if (init.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  return new Request(`https://gw.test${path}`, { ...init, headers });
}
