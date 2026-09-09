/* Transpile cache, two levels like git:
 *
 *  1. An index (like git's index/staging file) maps each source path to its
 *     lstat signature (mtime, size, inode) and the content key it produced. An
 *     unchanged file is detected by a cheap stat comparison — no reading or
 *     hashing of the content at all.
 *  2. A content-addressed store maps a key (sha-256 of source + target runtime +
 *     format version) to the transpiled .mjs. This catches the case where a file
 *     was touched (mtime changed) but its content did not, and shares output
 *     between identical sources — so we re-transpile only on a real change.
 *
 * All cache I/O is best-effort: a missing/unwritable cache just means we do the
 * work. `--no-cache` and stdin bypass it entirely (see the CLI).
 */

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

/** Bump when the emitter's output could change for the same input. */
const CACHE_VERSION = "1";

/** `$CURSE_CACHE`, else `$XDG_CACHE_HOME/curse`, else `~/.cache/curse`. */
export const cacheDir = (): string =>
  process.env.CURSE_CACHE ??
  join(process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache"), "curse");

/** The content key (hex sha-256) for a source targeting a given runtime.
 *  `variant` distinguishes emit shapes (a standalone program vs a source
 *  fragment) so they never collide on the same source. */
export const cacheKey = (src: string, runtimeSpecifier: string, variant = "prog"): string =>
  createHash("sha256")
    .update(CACHE_VERSION).update("\0")
    .update(variant).update("\0")
    .update(runtimeSpecifier).update("\0")
    .update(src)
    .digest("hex");

interface IndexEntry {
  mtimeMs: number;
  size: number;
  ino: number;
  key: string;
}
type Index = Record<string, IndexEntry>;

const indexPath = (): string => join(cacheDir(), "index.json");

const loadIndex = (): Index => {
  try {
    return JSON.parse(readFileSync(indexPath(), "utf8")) as Index;
  } catch {
    return {};
  }
};

const saveIndex = (idx: Index): void => {
  try {
    mkdirSync(cacheDir(), { recursive: true });
    // Atomic-ish: write a temp then rename, so a crash can't corrupt the index.
    const tmp = indexPath() + "." + process.pid + ".tmp";
    writeFileSync(tmp, JSON.stringify(idx));
    renameSync(tmp, indexPath());
  } catch {
    /* unwritable — cache just won't persist */
  }
};

const readMjs = (key: string): string | null => {
  try {
    return readFileSync(join(cacheDir(), key + ".mjs"), "utf8");
  } catch {
    return null;
  }
};

/** Ensure a file's cached transpile is current, avoiding re-reading / re-hashing
 *  / re-emitting when possible. Returns its content key and the code, plus the
 *  cache-file path. `transpile(src)` runs only on a genuine change. `variant`
 *  separates emit shapes (program vs source fragment). */
const cachedEntry = (
  file: string,
  runtimeSpecifier: string,
  transpile: (src: string) => string,
  variant: string,
): { key: string; code: string; path: string } => {
  const abs = resolve(file);
  const idxKey = variant + "\0" + abs;
  let st: ReturnType<typeof statSync> | null = null;
  try {
    st = statSync(abs);
  } catch {
    st = null;
  }

  const idx = loadIndex();
  const ent = st !== null ? idx[idxKey] : undefined;
  // Level 1 — stat matches the index: trust it, no content read or hash.
  if (st !== null && ent !== undefined &&
      ent.mtimeMs === st.mtimeMs && ent.size === st.size && ent.ino === Number(st.ino)) {
    const hit = readMjs(ent.key);
    if (hit !== null) return { key: ent.key, code: hit, path: join(cacheDir(), ent.key + ".mjs") };
  }

  // Changed (or first-seen): now we must read the source.
  const src = readFileSync(abs, "utf8");
  const key = cacheKey(src, runtimeSpecifier, variant);
  const path = join(cacheDir(), key + ".mjs");
  // Level 2 — content-addressed: reuse the .mjs if this exact content was
  // transpiled before (e.g. the file was only touched), else transpile once.
  let code = readMjs(key);
  if (code === null) {
    code = transpile(src);
    try {
      mkdirSync(cacheDir(), { recursive: true });
      writeFileSync(path, code);
    } catch {
      /* unwritable */
    }
  }
  // Refresh the index so the next run hits level 1.
  if (st !== null) {
    idx[idxKey] = { mtimeMs: st.mtimeMs, size: st.size, ino: Number(st.ino), key };
    saveIndex(idx);
  }
  return { key, code, path };
};

/** Transpile a file to standalone-program code (the `transpile` command). */
export const transpileFile = (
  file: string,
  runtimeSpecifier: string,
  transpile: (src: string) => string,
): string => cachedEntry(file, runtimeSpecifier, transpile, "prog").code;

/** Ensure a file is transpiled+cached with `variant`, returning the cache-file
 *  path so it can be dynamically imported (used by AOT `source`). Returns null
 *  if the cache is unwritable (so the transpile couldn't be persisted to a
 *  file to import). */
export const cachedModulePath = (
  file: string,
  runtimeSpecifier: string,
  transpile: (src: string) => string,
  variant: string,
): string | null => {
  const { code, path } = cachedEntry(file, runtimeSpecifier, transpile, variant);
  // The path must actually contain the code to be importable.
  try {
    if (readFileSync(path, "utf8") === code) return path;
    mkdirSync(cacheDir(), { recursive: true });
    writeFileSync(path, code);
    return path;
  } catch {
    return null;
  }
};
