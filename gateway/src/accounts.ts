import type { EnableBankingClient } from "./enablebanking";
import { json } from "./http";
import type { PsuContext } from "./types";

const TRANSACTION_QUERY_KEYS = ["date_from", "date_to", "continuation_key", "strategy", "transaction_status"] as const;

// PSU headers tell the bank the end user is present, which lifts the PSD2 "4 unattended fetches per day" limit.
export function psuContext(request: Request): PsuContext | undefined {
  const url = new URL(request.url);
  if (url.searchParams.get("attended") !== "1") {
    return undefined;
  }
  const ipAddress = request.headers.get("CF-Connecting-IP") ?? request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim();
  const userAgent = request.headers.get("User-Agent");
  if (!ipAddress || !userAgent) {
    return undefined;
  }
  return { ipAddress, userAgent };
}

export async function getBalances(request: Request, client: EnableBankingClient, accountUid: string): Promise<Response> {
  return json(await client.balances(accountUid, psuContext(request)));
}

export async function getTransactions(request: Request, client: EnableBankingClient, accountUid: string): Promise<Response> {
  const params = new URL(request.url).searchParams;
  const query: Record<string, string | undefined> = {};
  for (const key of TRANSACTION_QUERY_KEYS) {
    query[key] = params.get(key) ?? undefined;
  }
  return json(await client.transactions(accountUid, query, psuContext(request)));
}
