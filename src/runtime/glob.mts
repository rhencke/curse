/* Pattern matching (fnmatch-style), for `case`, `[[ == ]]`, and pathname
 * expansion. Follows bash pattern rules (GPLv3+; see NOTICE.md), minus extglob
 * for now: `*`, `?`, `[...]` character classes with ranges and `!`/`^`
 * negation, and backslash escaping. */

import { lstatSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const escapeRe = (c: string): string => (/[.*+?^${}()|[\]\\]/.test(c) ? "\\" + c : c);

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

/** Translate a glob pattern to a regular-expression body (no anchors). */
export const globToRegExpBody = (pat: string, extglob = false): string =>
  translate(pat, 0, extglob, false)[0];

/** Anchored source (`^…$`) — inlined by the emitter as a `/…/s` literal for
 *  static patterns; used by the runtime for dynamic ones. */
export const globToRegExpSource = (pat: string, extglob = false): string =>
  "^" + globToRegExpBody(pat, extglob) + "$";

export const globMatch = (str: string, pattern: string, nocase = false, extglob = false): boolean =>
  new RegExp(globToRegExpSource(pattern, extglob), nocase ? "si" : "s").test(str);

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
