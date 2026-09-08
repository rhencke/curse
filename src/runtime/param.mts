/* Parameter-expansion string operations shared by the interpreter and the
 * AOT-generated code (bash's `subst.c`; GPLv3+, see NOTICE.md): prefix/suffix
 * removal, pattern replacement, and substring. Value and pattern are already
 * expanded strings; matching uses the glob→regex machinery. */

import { globToRegExpBody, globToRegExpSource } from "./glob.mts";

/** `${v#pat}` / `${v##pat}` — remove a matching prefix (shortest / longest). */
export const trimPrefix = (v: string, pat: string, longest: boolean): string => {
  const re = new RegExp(globToRegExpSource(pat), "s");
  if (longest) {
    for (let e = v.length; e >= 0; e--) if (re.test(v.slice(0, e))) return v.slice(e);
  } else {
    for (let e = 0; e <= v.length; e++) if (re.test(v.slice(0, e))) return v.slice(e);
  }
  return v;
};

/** `${v%pat}` / `${v%%pat}` — remove a matching suffix (shortest / longest). */
export const trimSuffix = (v: string, pat: string, longest: boolean): string => {
  const re = new RegExp(globToRegExpSource(pat), "s");
  if (longest) {
    for (let s = 0; s <= v.length; s++) if (re.test(v.slice(s))) return v.slice(0, s);
  } else {
    for (let s = v.length; s >= 0; s--) if (re.test(v.slice(s))) return v.slice(0, s);
  }
  return v;
};

/** `${v/pat/repl}` (first), `${v//pat/repl}` (all), `/#` (start), `/%` (end). */
export const replaceGlob = (
  v: string,
  pat: string,
  repl: string,
  all: boolean,
  anchor: string,
): string => {
  const body = globToRegExpBody(pat);
  const src = anchor === "#" ? "^(?:" + body + ")" : anchor === "%" ? "(?:" + body + ")$" : "(?:" + body + ")";
  const re = new RegExp(src, "s" + (all ? "g" : ""));
  return v.replace(re, () => repl);
};

/** `${v:offset}` / `${v:offset:length}` — bash substring (negatives from end). */
export const substr = (v: string, offset: number, length: number | undefined): string => {
  const start = offset < 0 ? Math.max(v.length + offset, 0) : Math.min(offset, v.length);
  if (length === undefined) return v.slice(start);
  if (length < 0) return v.slice(start, Math.max(v.length + length, start));
  return v.slice(start, start + length);
};

/** `${arr[@]:offset:length}` / `${@:offset:length}` — slice a list (same rules). */
export const sliceArr = (list: string[], offset: number, length: number | undefined): string[] => {
  const start = offset < 0 ? Math.max(list.length + offset, 0) : Math.min(offset, list.length);
  if (length === undefined) return list.slice(start);
  if (length < 0) return list.slice(start, Math.max(list.length + length, start));
  return list.slice(start, start + length);
};
