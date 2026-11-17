import { describe, expect, it } from "vitest";
import { importPrivateKey } from "../src/jwt";
import { pemToPkcs8Der, wrapPkcs1InPkcs8 } from "../src/pem";
import { generateTestKey, toPem } from "./helpers";

interface Tlv {
  tag: number;
  contentStart: number;
  end: number;
}

function readTlv(bytes: Uint8Array, offset: number): Tlv {
  const tag = bytes[offset] as number;
  let length = bytes[offset + 1] as number;
  let cursor = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    length = 0;
    for (let i = 0; i < count; i += 1) {
      length = (length << 8) | (bytes[cursor + i] as number);
    }
    cursor += count;
  }
  return { tag, contentStart: cursor, end: cursor + length };
}

function extractPkcs1(pkcs8: Uint8Array): Uint8Array {
  const outer = readTlv(pkcs8, 0);
  const version = readTlv(pkcs8, outer.contentStart);
  const algorithm = readTlv(pkcs8, version.end);
  const octetString = readTlv(pkcs8, algorithm.end);
  expect(octetString.tag).toBe(0x04);
  return pkcs8.slice(octetString.contentStart, octetString.end);
}

describe("pem", () => {
  it("returns PKCS#8 DER unchanged for 'PRIVATE KEY' PEM", async () => {
    const { privatePem, pkcs8 } = await generateTestKey();
    expect(pemToPkcs8Der(privatePem)).toEqual(pkcs8);
  });

  it("wraps PKCS#1 'RSA PRIVATE KEY' PEM into the same PKCS#8 DER", async () => {
    const { pkcs8 } = await generateTestKey();
    const pkcs1 = extractPkcs1(pkcs8);
    expect(wrapPkcs1InPkcs8(pkcs1)).toEqual(pkcs8);
    expect(pemToPkcs8Der(toPem("RSA PRIVATE KEY", pkcs1))).toEqual(pkcs8);
  });

  it("imports a PKCS#1 PEM as a usable signing key", async () => {
    const { pkcs8 } = await generateTestKey();
    const key = await importPrivateKey(toPem("RSA PRIVATE KEY", extractPkcs1(pkcs8)));
    expect(key.type).toBe("private");
  });

  it("rejects malformed or unsupported PEM", () => {
    expect(() => pemToPkcs8Der("not a pem")).toThrow(/BEGIN\/END/);
    expect(() => pemToPkcs8Der("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----")).toThrow(/Unsupported/);
  });
});
