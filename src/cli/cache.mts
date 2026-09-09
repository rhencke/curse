/* Content-addressed transpile cache. Like git, the key is a hash of the input
 * (source + the runtime path it targets + a format version), so an unchanged
 * script is never re-transpiled: a hit reads the stored .mjs, a miss transpiles
 * once and stores it. Cache writes are best-effort — a read-only or missing
 * cache directory just means we always transpile. */

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Bump when the emitter's output could change for the same input, so old
 *  cache entries are ignored rather than reused. */
const CACHE_VERSION = "1";

/** `$CURSE_CACHE`, else `$XDG_CACHE_HOME/curse`, else `~/.cache/curse`. */
export const cacheDir = (): string =>
  process.env.CURSE_CACHE ??
  join(process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache"), "curse");

/** The cache key (hex sha-256) for a source targeting a given runtime. */
export const cacheKey = (src: string, runtimeSpecifier: string): string =>
  createHash("sha256")
    .update(CACHE_VERSION).update("\0")
    .update(runtimeSpecifier).update("\0")
    .update(src)
    .digest("hex");

/** Return the transpiled code for `src`, reusing a cached copy when the exact
 *  source (and target runtime + format version) was transpiled before. */
export const cachedTranspile = (
  src: string,
  runtimeSpecifier: string,
  transpile: () => string,
): string => {
  const file = join(cacheDir(), cacheKey(src, runtimeSpecifier) + ".mjs");
  try {
    return readFileSync(file, "utf8"); // hit
  } catch {
    /* miss */
  }
  const code = transpile();
  try {
    mkdirSync(cacheDir(), { recursive: true });
    writeFileSync(file, code);
  } catch {
    /* cache unwritable — fine, we just recompute next time */
  }
  return code;
};
