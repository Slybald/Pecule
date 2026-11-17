import { describe, expect, it } from "vitest";
import { isAuthorized, presentedBearer } from "../src/auth";

const request = (authorization?: string): Request =>
  new Request("https://gw.test/v1/links", { headers: authorization ? { Authorization: authorization } : {} });

describe("isAuthorized", () => {
  it("accepts the exact bearer token", () => {
    expect(isAuthorized(request("Bearer secret"), ["secret"])).toBe(true);
  });

  it("accepts the previous token during a rotation, never an empty one", () => {
    expect(isAuthorized(request("Bearer old"), ["new", "old"])).toBe(true);
    expect(isAuthorized(request("Bearer new"), ["new", "old"])).toBe(true);
    expect(isAuthorized(request("Bearer "), ["new", ""])).toBe(false);
    expect(isAuthorized(request("Bearer x"), ["new", undefined])).toBe(false);
  });

  it("rejects missing, malformed, wrong-length and wrong-value tokens", () => {
    expect(isAuthorized(request(), ["secret"])).toBe(false);
    expect(isAuthorized(request("secret"), ["secret"])).toBe(false);
    expect(isAuthorized(request("Basic secret"), ["secret"])).toBe(false);
    expect(isAuthorized(request("Bearer secre"), ["secret"])).toBe(false);
    expect(isAuthorized(request("Bearer secret2"), ["secret"])).toBe(false);
    expect(isAuthorized(request("Bearer Secret"), ["secret"])).toBe(false);
    expect(isAuthorized(request("Bearer secret extra"), ["secret"])).toBe(false);
    expect(isAuthorized(request("Bearer secret,Bearer other"), ["secret"])).toBe(false);
  });

  it("rejects everything when no token is configured", () => {
    expect(isAuthorized(request("Bearer "), [""])).toBe(false);
    expect(isAuthorized(request("Bearer x"), [""])).toBe(false);
    expect(presentedBearer(request("Bearer x"))).toBe("x");
    expect(presentedBearer(request())).toBeNull();
  });
});
