/** Bounded terminal bridge wait. The manager owns the authoritative Sync deadline. */
async function pause(milliseconds: number, signal?: AbortSignal) {
  await new Promise<void>((done, reject) => {
    const abort = () => { clearTimeout(timer); reject(new Error("Draw wait cancelled")); };
    const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); done(); }, milliseconds);
    if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
  });
}

export async function waitForFreshness(
  initial: any, poll: () => Promise<any>, signal?: AbortSignal,
  now: () => number = Date.now, sleep: (milliseconds: number, signal?: AbortSignal) => Promise<void> = pause,
) {
  let value = initial;
  const responseDeadline = now()+10000;
  let syncObservedAt: number | undefined;
  while (value.status === "awaiting_sync" || value.status === "synchronizing") {
    signal?.throwIfAborted();
    let deadline = responseDeadline;
    if (value.status === "synchronizing") {
      syncObservedAt ??= now();
      const serverDeadline = Date.parse(value.syncDeadlineAt);
      deadline = Math.min(syncObservedAt+300000, Number.isFinite(serverDeadline) ? serverDeadline : Infinity);
    }
    if (now() >= deadline) {
      const previousStatus = value.status;
      value = await poll(); // Resolve an acknowledgement racing the original ten-second boundary.
      if (previousStatus === "awaiting_sync" && value.status === "synchronizing") continue;
      // Never mark an actively synchronizing response as a stale choice locally.
      return value;
    }
    await sleep(250, signal);
    value = await poll();
  }
  return value;
}
