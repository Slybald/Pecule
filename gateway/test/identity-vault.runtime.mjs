// Real local workerd + SQLite transactions, not an in-memory storage double.
// No upstream banking request, credentials or production resource is used.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

const bundle = await build({
  entryPoints: [fileURLToPath(new URL("../src/identity-vault.ts", import.meta.url))],
  bundle: true, write: false, format: "esm", platform: "browser", target: "es2022",
});
const script = bundle.outputFiles[0].text + "\nexport default { fetch() { return new Response(null, { status: 404 }); } };";

async function fixture(t) {
  // Wrangler currently pins Miniflare 5; use its official v4 options adapter.
  const mf = new Miniflare(convertV4MiniflareOptions({
    cf: false,
    workers: [{
      name: "identity-runtime", modules: true, script, compatibilityDate: "2026-09-01",
      durableObjects: { IDENTITY_VAULT: { className: "IdentityVault", useSQLite: true } },
    }],
  }));
  t.after(() => mf.dispose());
  const namespace = await mf.getDurableObjectNamespace("IDENTITY_VAULT");
  const stub = namespace.get(namespace.idFromName("runtime-test"));
  const command = async body => {
    const response = await stub.fetch("https://identity.internal/command", { method: "POST", body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const link = {
    id: crypto.randomUUID(), ownerUserID: "alice", state: crypto.randomUUID(),
    status: "pending", aspsp: { name: "Test", country: "FR" }, psuType: "personal", createdAt: new Date().toISOString(),
  };
  return { command, link };
}

test("SQLite callback consumption is atomic under concurrent requests", async t => {
  const { command, link } = await fixture(t);
  assert.equal((await command({ operation: "link.create", link })).status, 201);
  const results = await Promise.all(Array.from({ length: 8 }, () => command({ operation: "callback.consume", state: link.state })));
  assert.equal(results.filter(result => result.body?.id === link.id).length, 1);
  assert.equal(results.filter(result => result.body === null).length, 7);
});

test("SQLite storage isolates owners and denies account access after deletion", async t => {
  const { command, link } = await fixture(t);
  await command({ operation: "link.create", link });
  assert.equal((await command({ operation: "link.get", userId: "bob", linkId: link.id })).status, 404);
  await command({ operation: "callback.consume", state: link.state });
  const authorized = { ...link, status: "authorized", sessionId: "test-bank-session",
    validUntil: new Date(Date.now() + 86400000).toISOString(), accounts: [{ uid: "account-a" }] };
  assert.equal((await command({ operation: "link.update", link: authorized })).status, 200);
  assert.equal((await command({ operation: "account.check", userId: "alice", accountUid: "account-a" })).body, true);
  assert.equal((await command({ operation: "account.check", userId: "bob", accountUid: "account-a" })).body, false);
  assert.equal((await command({ operation: "link.delete", userId: "bob", linkId: link.id })).status, 404);
  assert.equal((await command({ operation: "link.delete", userId: "alice", linkId: link.id })).status, 200);
  assert.equal((await command({ operation: "account.check", userId: "alice", accountUid: "account-a" })).body, false);
});

test("SQLite does not recreate a deleted pending link after callback consumption", async t => {
  const { command, link } = await fixture(t);
  await command({ operation: "link.create", link });
  await command({ operation: "callback.consume", state: link.state });
  await command({ operation: "link.delete", userId: "alice", linkId: link.id });
  assert.equal((await command({ operation: "link.update", link: { ...link, status: "failed" } })).status, 404);
});

test("SQLite session revocation is immediately visible to subsequent reads", async t => {
  const { command } = await fixture(t);
  const tokenHash = "a".repeat(64);
  assert.equal((await command({ operation: "session.issue", tokenHash, userId: "alice", lifetimeSeconds: 60 })).status, 201);
  assert.equal((await command({ operation: "session.resolve", tokenHash })).body.userId, "alice");
  await command({ operation: "session.revoke", tokenHash });
  assert.equal((await command({ operation: "session.resolve", tokenHash })).body, null);
});

test("SQLite login challenges are consumed exactly once", async t => {
  const { command } = await fixture(t);
  const challengeId = crypto.randomUUID();
  const nonce = "b".repeat(64);
  assert.equal((await command({ operation: "challenge.issue", challengeId, nonce })).status, 201);
  const attempts = await Promise.all(Array.from({ length: 8 }, () => command({ operation: "challenge.consume", challengeId })));
  assert.equal(attempts.filter(result => result.body?.nonce === nonce).length, 1);
  assert.equal(attempts.filter(result => result.body === null).length, 7);
});
