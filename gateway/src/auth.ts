function constantTimeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let diff = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i += 1) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

export function presentedBearer(request: Request): string | null {
  const header = request.headers.get("Authorization") ?? "";
  // Reject appended credentials instead of silently accepting the first two words.
  const match = /^Bearer ([A-Za-z0-9._~+\/-]+=*)$/.exec(header);
  return match?.[1] ?? null;
}

// The previous token stays valid during a rotation so the app can be updated without downtime.
export function isAuthorized(request: Request, acceptedTokens: Array<string | undefined>): boolean {
  const token = presentedBearer(request);
  if (!token) {
    return false;
  }
  return acceptedTokens.some((accepted) => !!accepted && constantTimeEqual(token, accepted));
}
