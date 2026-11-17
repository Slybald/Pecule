const PEM_PATTERN = /-----BEGIN ([A-Z ]+)-----([\s\S]*?)-----END \1-----/;

// AlgorithmIdentifier { rsaEncryption OID 1.2.840.113549.1.1.1, NULL }
const RSA_ALGORITHM_IDENTIFIER = new Uint8Array([
  0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
]);

export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i] as number);
  }
  return btoa(binary);
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function derLength(length: number): number[] {
  if (length < 0x80) {
    return [length];
  }
  const bytes: number[] = [];
  let remaining = length;
  while (remaining > 0) {
    bytes.unshift(remaining & 0xff);
    remaining >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

function derTlv(tag: number, content: Uint8Array): Uint8Array {
  const length = derLength(content.length);
  const out = new Uint8Array(1 + length.length + content.length);
  out[0] = tag;
  out.set(length, 1);
  out.set(content, 1 + length.length);
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

// PrivateKeyInfo ::= SEQUENCE { version INTEGER 0, AlgorithmIdentifier, privateKey OCTET STRING }
export function wrapPkcs1InPkcs8(pkcs1: Uint8Array): Uint8Array {
  const version = new Uint8Array([0x02, 0x01, 0x00]);
  return derTlv(0x30, concat(version, RSA_ALGORITHM_IDENTIFIER, derTlv(0x04, pkcs1)));
}

// WebCrypto only imports PKCS#8; OpenSSL-style "RSA PRIVATE KEY" (PKCS#1) files are wrapped on the fly.
export function pemToPkcs8Der(pem: string): Uint8Array {
  const match = PEM_PATTERN.exec(pem);
  if (!match) {
    throw new Error("Invalid PEM: BEGIN/END markers not found");
  }
  const label = match[1] as string;
  const der = base64ToBytes((match[2] as string).replace(/\s+/g, ""));
  if (label === "PRIVATE KEY") {
    return der;
  }
  if (label === "RSA PRIVATE KEY") {
    return wrapPkcs1InPkcs8(der);
  }
  throw new Error(`Unsupported PEM label: ${label}`);
}
