// Minimal host utilities for extension lifecycle unit tests, never a replacement Pi.
export function truncateHead(text, options) { return { content: text.slice(0, options.maxBytes), truncated: text.length > options.maxBytes }; }
const tails = new Map();
export function withFileMutationQueue(path, callback) {
  const task = (tails.get(path) ?? Promise.resolve()).catch(() => {}).then(callback);
  tails.set(path, task);
  return task.finally(() => { if (tails.get(path) === task) tails.delete(path); });
}
