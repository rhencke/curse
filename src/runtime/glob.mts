/* Pattern matching (fnmatch-style), for `case`, `[[ == ]]`, and pathname
 * expansion. Follows bash pattern rules (GPLv3+; see NOTICE.md), minus extglob
 * for now: `*`, `?`, `[...]` character classes with ranges and `!`/`^`
 * negation, and backslash escaping. */

import { lstatSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const escapeRe = (c: string): string => (/[.*+?^${}()|[\]\\]/.test(c) ? "\\" + c : c);

/** POSIX character classes -> equivalent regex char-class body. Ranges use hex
 *  escapes so the class-special chars `[ \ ] ^` need no further quoting. */
const posixClass: Record<string, string> = {
  alpha: "a-zA-Z",
  alnum: "a-zA-Z0-9",
  digit: "0-9",
  xdigit: "0-9A-Fa-f",
  upper: "A-Z",
  lower: "a-z",
  space: " \\t\\n\\r\\f\\v",
  blank: " \\t",
  cntrl: "\\x00-\\x1f\\x7f",
  print: "\\x20-\\x7e",
  graph: "\\x21-\\x7e",
  punct: "!-/:-@\\x5b-\\x60{-~",
  word: "0-9A-Za-z_",
};

/** Translate `pat[start..]` into a regex body. When `inGroup`, stop (without
 *  consuming) at a top-level `|` or `)`. Returns [regex, nextIndex]. */
const translate = (pat: string, start: number, extglob: boolean, inGroup: boolean): [string, number] => {
  let re = "";
  let i = start;
  while (i < pat.length) {
    const c = pat[i]!;
    if (inGroup && (c === "|" || c === ")")) break;
    if (c === "\\") {
      const n = pat[i + 1];
      if (n !== undefined) { re += escapeRe(n); i += 2; } else { re += "\\\\"; i++; }
      continue;
    }
    // extglob: ?(list) *(list) +(list) @(list) !(list)
    if (extglob && (c === "?" || c === "*" || c === "+" || c === "@" || c === "!") && pat[i + 1] === "(") {
      const [grp, next] = extglobGroup(pat, i, extglob);
      re += grp;
      i = next;
      continue;
    }
    if (c === "*") { re += ".*"; i++; continue; }
    if (c === "?") { re += "."; i++; continue; }
    if (c === "[") {
      let j = i + 1;
      let neg = false;
      if (pat[j] === "!" || pat[j] === "^") { neg = true; j++; }
      let cls = "";
      if (pat[j] === "]") { cls += "\\]"; j++; }
      while (j < pat.length && pat[j] !== "]") {
        const ch = pat[j]!;
        // POSIX class/collating/equivalence: [:name:] [.coll.] [=eq=]
        if (ch === "[" && (pat[j + 1] === ":" || pat[j + 1] === "." || pat[j + 1] === "=")) {
          const kind = pat[j + 1]!;
          const close = pat.indexOf(kind + "]", j + 2);
          if (close >= 0) {
            const name = pat.slice(j + 2, close);
            if (kind === ":") cls += posixClass[name] ?? "";
            else cls += name.split("").map(escapeRe).join(""); // [.x.]/[=x=] -> the char(s)
            j = close + 2;
            continue;
          }
        }
        if (ch === "\\") { cls += "\\" + (pat[j + 1] ?? ""); j += 2; continue; }
        cls += ch === "^" || ch === "]" ? "\\" + ch : ch;
        j++;
      }
      if (j >= pat.length) { re += "\\["; i++; continue; }
      re += "[" + (neg ? "^" : "") + cls + "]";
      i = j + 1;
      continue;
    }
    re += escapeRe(c);
    i++;
  }
  return [re, i];
};

/** Translate an extglob group `X(a|b|...)` starting at the operator char. */
const extglobGroup = (pat: string, i: number, extglob: boolean): [string, number] => {
  const op = pat[i]!;
  let j = i + 2; // past `X(`
  const alts: string[] = [];
  for (;;) {
    const [sub, next] = translate(pat, j, extglob, true);
    alts.push(sub);
    j = next;
    if (pat[j] === "|") { j++; continue; }
    if (pat[j] === ")") { j++; break; }
    return [escapeRe(op) + "\\(", i + 2]; // unterminated: literal fallback
  }
  const body = alts.join("|");
  const grp = "(?:" + body + ")";
  switch (op) {
    case "?": return [grp + "?", j];
    case "*": return [grp + "*", j];
    case "+": return [grp + "+", j];
    case "!": return ["(?!(?:" + body + ")$).*", j];
    default: return [grp, j]; // @
  }
};

// Glob→regex translation is a pure function of (pattern, extglob), so memoize
// it: a pattern reused across a loop is translated once instead of on every
// match. Capped to bound memory if a program generates unboundedly many.
const bodyCache = new Map<string, string>();
const CACHE_CAP = 4096;

/** Translate a glob pattern to a regular-expression body (no anchors). */
export const globToRegExpBody = (pat: string, extglob = false): string => {
  const key = (extglob ? "1" : "0") + pat;
  let body = bodyCache.get(key);
  if (body === undefined) {
    body = translate(pat, 0, extglob, false)[0];
    if (bodyCache.size >= CACHE_CAP) bodyCache.clear();
    bodyCache.set(key, body);
  }
  return body;
};

/** Anchored source (`^…$`) — inlined by the emitter as a `/…/s` literal for
 *  static patterns; used by the runtime for dynamic ones. */
export const globToRegExpSource = (pat: string, extglob = false): string =>
  "^" + globToRegExpBody(pat, extglob) + "$";

// Compiled anchored matchers, likewise memoized by (flags, pattern).
const reCache = new Map<string, RegExp>();

export const globMatch = (str: string, pattern: string, nocase = false, extglob = false): boolean => {
  const key = (nocase ? "i" : "") + (extglob ? "e" : "") + pattern;
  let re = reCache.get(key);
  if (re === undefined) {
    re = new RegExp(globToRegExpSource(pattern, extglob), nocase ? "si" : "s");
    if (reCache.size >= CACHE_CAP) reCache.clear();
    reCache.set(key, re);
  }
  return re.test(str);
};

export const hasGlobMeta = (s: string): boolean => /[*?[]/.test(s);
/** Does the word contain an extglob operator group `X(`? */
export const hasExtglob = (s: string): boolean => /[?*+@!]\(/.test(s);

/** Pathname expansion: match `pattern` against the filesystem (relative to
 *  `cwd`), returning sorted matches (paths as written), or [] if none. Hidden
 *  files match only when the component starts with `.`. */
export const globExpand = (
  cwd: string,
  pattern: string,
  dotglob = false,
  globstar = false,
  extglob = false,
): string[] => {
  const comps = pattern.split("/");
  const absolute = pattern.startsWith("/");
  const out: string[] = [];

  const joinPrefix = (p: string, c: string): string =>
    p === "" ? c : p.endsWith("/") ? p + c : p + "/" + c;

  // Recurse into `fsDir`, invoking `cb` for each descendant (files too when
  // `withFiles`). Symlinked directories are matched but not descended (as in
  // bash's globstar), and hidden entries need dotglob.
  const descend = (
    fsDir: string,
    prefix: string,
    withFiles: boolean,
    cb: (p: string, fs: string) => void,
  ): void => {
    let entries: string[];
    try {
      entries = readdirSync(fsDir);
    } catch {
      return;
    }
    for (const e of entries.sort()) {
      if (!dotglob && e.startsWith(".")) continue;
      const childFs = join(fsDir, e);
      let st: ReturnType<typeof lstatSync>;
      try {
        st = lstatSync(childFs);
      } catch {
        continue;
      }
      const isDir = st.isDirectory();
      const childPrefix = joinPrefix(prefix, e);
      if (isDir || withFiles) cb(childPrefix, childFs);
      if (isDir) descend(childFs, childPrefix, withFiles, cb);
    }
  };

  const walk = (idx: number, prefix: string, fsDir: string): void => {
    if (idx >= comps.length) {
      out.push(prefix);
      return;
    }
    const comp = comps[idx]!;
    const isLast = idx === comps.length - 1;
    if (comp === "") {
      walk(idx + 1, prefix, fsDir);
      return;
    }
    // globstar `**`: match across zero or more directory levels.
    if (globstar && comp === "**") {
      if (isLast) {
        descend(fsDir, prefix, true, (p) => out.push(p));
      } else {
        walk(idx + 1, prefix, fsDir); // zero levels
        descend(fsDir, prefix, false, (p, fs) => walk(idx + 1, p, fs));
      }
      return;
    }
    if (!hasGlobMeta(comp) && !(extglob && hasExtglob(comp))) {
      const nextFs = join(fsDir, comp);
      try {
        const st = statSync(nextFs);
        if (isLast) out.push(joinPrefix(prefix, comp));
        else if (st.isDirectory()) walk(idx + 1, joinPrefix(prefix, comp), nextFs);
      } catch {
        /* no such path */
      }
      return;
    }
    let entries: string[];
    try {
      entries = readdirSync(fsDir);
    } catch {
      return;
    }
    const re = new RegExp(globToRegExpSource(comp, extglob), "s");
    for (const e of entries.sort()) {
      if (!dotglob && e.startsWith(".") && !comp.startsWith(".")) continue;
      if (!re.test(e)) continue;
      if (isLast) {
        out.push(joinPrefix(prefix, e));
      } else {
        try {
          if (statSync(join(fsDir, e)).isDirectory()) walk(idx + 1, joinPrefix(prefix, e), join(fsDir, e));
        } catch {
          /* skip */
        }
      }
    }
  };

  walk(absolute ? 1 : 0, absolute ? "/" : "", absolute ? "/" : cwd);
  return out.sort();
};

/** Match a produced path against one GLOBIGNORE pattern component-wise, so a
 *  `*`/`?`/`[…]` never crosses a `/` (bash matches the whole generated name). */
const ignoreMatchOne = (path: string, pat: string, extglob: boolean): boolean => {
  const pc = path.split("/");
  const gc = pat.split("/");
  return pc.length === gc.length && pc.every((c, i) => globMatch(c, gc[i]!, false, extglob));
};

/** Split a GLOBIGNORE value on `:`, but not on a colon inside a `[…]` bracket
 *  expression (including a POSIX `[:class:]`) or after a backslash. */
const splitIgnorePatterns = (s: string): string[] => {
  const out: string[] = [];
  let start = 0;
  let i = 0;
  while (i < s.length) {
    const c = s[i]!;
    if (c === "\\") { i += 2; continue; }
    if (c === ":") { out.push(s.slice(start, i)); start = i + 1; i++; continue; }
    if (c === "[") {
      let j = i + 1;
      if (s[j] === "!" || s[j] === "^") j++;
      if (s[j] === "]") j++; // a leading `]` is a literal member
      while (j < s.length && s[j] !== "]") {
        if (s[j] === "[" && (s[j + 1] === ":" || s[j + 1] === "." || s[j + 1] === "=")) {
          const close = s.indexOf(s[j + 1]! + "]", j + 2);
          if (close >= 0) { j = close + 2; continue; }
        }
        j += s[j] === "\\" ? 2 : 1;
      }
      i = j < s.length ? j + 1 : j;
      continue;
    }
    i++;
  }
  out.push(s.slice(start));
  return out;
};

/** Whether `path` matches any pattern in a colon-separated GLOBIGNORE value. */
export const globIgnored = (path: string, globignore: string, extglob = false): boolean =>
  splitIgnorePatterns(globignore).some((pat) => pat !== "" && ignoreMatchOne(path, pat, extglob));
