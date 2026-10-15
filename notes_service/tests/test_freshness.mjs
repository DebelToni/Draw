import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
const packagePath = process.env.DRAW_PI_PACKAGE ?? "/home/xaj/.local/share/pi-codex-ultra/releases/5b814f7c6a4f0c7761e6ce2b02ae0641353072b8/node_modules/@earendil-works/pi-coding-agent";
const { createJiti } = createRequire(import.meta.url)(join(packagePath, "node_modules/jiti/lib/jiti.cjs"));
const jiti = createJiti(import.meta.url, { moduleCache: false, fsCache: false });
const { waitForFreshness } = await jiti.import(fileURLToPath(new URL("../freshness.ts", import.meta.url)));

test("sync-started ACK keeps waiting beyond ten seconds during busy native calls", async () => {
  let now = 0, polls = 0;
  const syncing = { status: "synchronizing", syncDeadlineAt: new Date(301000).toISOString() };
  const result = await waitForFreshness({ status: "awaiting_sync" }, async () => {
    polls++;
    return now < 45000 ? syncing : { status: "queued" };
  }, undefined, () => now, async ms => { now += ms; });
  assert.equal(result.status, "queued");
  assert.ok(now >= 45000);
  assert.ok(polls > 40);
});

test("no app response retains ordinary ten-second explicit stale choice", async () => {
  let now = 0;
  const result = await waitForFreshness({ status: "awaiting_sync" }, async () => ({ status: now < 10000 ? "awaiting_sync" : "needs_stale_choice" }), undefined, () => now, async ms => { now += ms; });
  assert.equal(now, 10000);
  assert.equal(result.status, "needs_stale_choice");
});

test("acknowledged Sync expires only at manager's bounded three-hundred-second deadline", async () => {
  let now = 0;
  const syncing = { status: "synchronizing", syncDeadlineAt: new Date(300000).toISOString() };
  const result = await waitForFreshness(syncing, async () => now < 300000 ? syncing : { status: "needs_stale_choice" }, undefined, () => now, async ms => { now += ms; });
  assert.equal(now, 300000);
  assert.equal(result.status, "needs_stale_choice");
});

test("local wait bound never changes actively synchronizing response into stale choice", async () => {
  let now = 0;
  const syncing = { status: "synchronizing" };
  const result = await waitForFreshness(syncing, async () => syncing, undefined, () => now, async ms => { now += ms; });
  assert.equal(now, 300000);
  assert.equal(result.status, "synchronizing");
  assert.equal(result.requiredHumanChoice, undefined);
});

test("ack racing initial ten-second boundary is observed before offering fallback", async () => {
  let now = 0;
  const syncing = { status: "synchronizing", syncDeadlineAt: new Date(310000).toISOString() };
  let callsAtBoundary = 0;
  const result = await waitForFreshness({ status: "awaiting_sync" }, async () => {
    if (now < 10000) return { status: "awaiting_sync" };
    if (now === 10000 && callsAtBoundary++ === 0) return { status: "awaiting_sync" };
    return now < 15000 ? syncing : { status: "queued" };
  }, undefined, () => now, async ms => { now += ms; });
  assert.equal(result.status, "queued");
  assert.equal(now, 15000);
});

test("abort stops wait rather than granting stale authority", async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(() => waitForFreshness({ status: "synchronizing" }, async () => ({ status: "queued" }), controller.signal));
});
