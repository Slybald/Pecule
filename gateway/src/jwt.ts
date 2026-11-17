import { bytesToBase64Url, pemToPkcs8Der } from "./pem";

export const JWT_TTL_SECONDS = 3600;
const REFRESH_MARGIN_SECONDS = 60;
const SIGNING_ALGORITHM = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } as const;

const utf8 = (value: string): Uint8Array => new TextEncoder().encode(value);

export async function importPrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", pemToPkcs8Der(pem), SIGNING_ALGORITHM, false, ["sign"]);
}

export async function signEnableBankingJwt(appId: string, key: CryptoKey, nowSeconds: number): Promise<string> {
  const header = { typ: "JWT", alg: "RS256", kid: appId };
  const claims = {
    iss: "enablebanking.com",
    aud: "api.enablebanking.com",
    iat: nowSeconds,
    exp: nowSeconds + JWT_TTL_SECONDS,
  };
  const signingInput = `${bytesToBase64Url(utf8(JSON.stringify(header)))}.${bytesToBase64Url(utf8(JSON.stringify(claims)))}`;
  const signature = await crypto.subtle.sign(SIGNING_ALGORITHM.name, key, utf8(signingInput));
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

export class JwtProvider {
  private key: Promise<CryptoKey> | undefined;
  private cached: { token: string; exp: number } | undefined;

  constructor(
    private readonly appId: string,
    private readonly pem: string,
    private readonly now: () => number = () => Date.now(),
  ) {}

  async token(): Promise<string> {
    const nowSeconds = Math.floor(this.now() / 1000);
    if (this.cached && this.cached.exp - nowSeconds > REFRESH_MARGIN_SECONDS) {
      return this.cached.token;
    }
    this.key ??= importPrivateKey(this.pem);
    const token = await signEnableBankingJwt(this.appId, await this.key, nowSeconds);
    this.cached = { token, exp: nowSeconds + JWT_TTL_SECONDS };
    return token;
  }
}
