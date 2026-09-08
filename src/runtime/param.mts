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

/** Quote a value so it can be read back in (bash's `${v@Q}`). Bash always
 *  quotes: `$'…'` when there are control chars, otherwise single quotes. */
const shellQuote = (v: string): string => {
  if (/[\x00-\x1f\x7f]/.test(v)) {
    let s = "$'";
    for (const ch of v) {
      const code = ch.charCodeAt(0);
      if (ch === "\\") s += "\\\\";
      else if (ch === "'") s += "\\'";
      else if (ch === "\n") s += "\\n";
      else if (ch === "\t") s += "\\t";
      else if (ch === "\r") s += "\\r";
      else if (code < 0x20 || code === 0x7f) s += "\\" + code.toString(8).padStart(3, "0");
      else s += ch;
    }
    return s + "'";
  }
  return "'" + v.replace(/'/g, "'\\''") + "'";
};

/** Expand ANSI-C backslash escapes in a value (bash's `${v@E}`). */
const expandEscapes = (v: string): string =>
  v.replace(/\\(x[0-9A-Fa-f]{1,2}|[0-7]{1,3}|.)/g, (m, seq: string) => {
    const c = seq[0]!;
    switch (c) {
      case "n": return "\n";
      case "t": return "\t";
      case "r": return "\r";
      case "a": return "\x07";
      case "b": return "\b";
      case "f": return "\f";
      case "v": return "\v";
      case "e": case "E": return "\x1b";
      case "\\": return "\\";
      case "'": return "'";
      case '"': return '"';
      case "x": return String.fromCharCode(parseInt(seq.slice(1), 16));
      default:
        if (c >= "0" && c <= "7") return String.fromCharCode(parseInt(seq, 8) & 0xff);
        return m;
    }
  });

/** `${v^}` `${v^^}` `${v,}` `${v,,}` — case modification, optionally limited
 *  to characters matching `pat` (empty pattern matches every character). */
export const changeCase = (v: string, op: string, pat: string): string => {
  const up = op[0] === "^";
  const all = op.length === 2;
  const re = pat === "" ? null : new RegExp("^(?:" + globToRegExpBody(pat) + ")$", "s");
  const hit = (ch: string): boolean => re === null || re.test(ch);
  const conv = (ch: string): string => (up ? ch.toUpperCase() : ch.toLowerCase());
  if (all) return [...v].map((ch) => (hit(ch) ? conv(ch) : ch)).join("");
  if (v.length === 0) return v;
  const chars = [...v];
  chars[0] = hit(chars[0]!) ? conv(chars[0]!) : chars[0]!;
  return chars.join("");
};

/** `${parameter@op}` transformations (Q quote, E escapes, L/U case, u title). */
export const transform = (op: string, v: string): string => {
  switch (op) {
    case "@Q": return shellQuote(v);
    case "@E": return expandEscapes(v);
    case "@L": return v.toLowerCase();
    case "@U": return v.toUpperCase();
    case "@u": return v.length === 0 ? v : v[0]!.toUpperCase() + v.slice(1);
    default: return v; // @P @A @a @K @k and unknowns: passthrough for now
  }
};

/** `${arr[@]:offset:length}` / `${@:offset:length}` — slice a list (same rules). */
export const sliceArr = (list: string[], offset: number, length: number | undefined): string[] => {
  const start = offset < 0 ? Math.max(list.length + offset, 0) : Math.min(offset, list.length);
  if (length === undefined) return list.slice(start);
  if (length < 0) return list.slice(start, Math.max(list.length + length, start));
  return list.slice(start, start + length);
};
