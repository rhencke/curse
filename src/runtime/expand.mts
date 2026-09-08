/* Word expansion for the interpreter path — the M0–M1 slice of bash's
 * `subst.c` (GPLv3+; see NOTICE.md).
 *
 * Works from the shared word structure (parser/word.mts): resolve each part to
 * a value, tag characters from unquoted expansions as splittable, then field-
 * split on the default IFS. The AOT emitter compiles the same structure to
 * TypeScript instead; `splitTaggedFields` is shared so both agree. */

import type { Word } from "../ast/nodes.mts";
import type { Shell } from "./shell.mts";
import { parseWord } from "../parser/word.mts";
import type { WordPart } from "../parser/word.mts";
import { evalArith } from "./arith.mts";

const isIFSWhitespace = (c: string): boolean => c === " " || c === "\t" || c === "\n";

/** Split an assembled, per-character-tagged buffer into fields (default IFS). */
export const splitTaggedFields = (
  chars: string[],
  splittable: boolean[],
  anchored: boolean,
): string[] => {
  if (chars.length === 0) return anchored ? [""] : [];
  const fields: string[] = [];
  let cur = "";
  let started = false;
  let i = 0;
  while (i < chars.length) {
    if (splittable[i] && isIFSWhitespace(chars[i]!)) {
      if (started) {
        fields.push(cur);
        cur = "";
        started = false;
      }
      while (i < chars.length && splittable[i] && isIFSWhitespace(chars[i]!)) i++;
      continue;
    }
    cur += chars[i];
    started = true;
    i++;
  }
  if (started) fields.push(cur);
  if (fields.length === 0) return anchored ? [""] : [];
  return fields;
};

const specialValue = (shell: Shell, name: string): string => {
  switch (name) {
    case "?": return String(shell.status);
    case "$": return String(shell.pid);
    case "#": return String(shell.positional.length);
    case "@": case "*": return shell.positional.join(" ");
    case "0": return shell.name;
    default: return shell.positional[Number(name) - 1] ?? "";
  }
};

const partValue = async (shell: Shell, p: Exclude<WordPart, { k: "lit" }>): Promise<string> => {
  switch (p.k) {
    case "var": return shell.getVar(p.name) ?? "";
    case "special": return specialValue(shell, p.name);
    case "arith": return evalArith(shell, await expandNoSplit(shell, p.expr)).toString();
    case "cmdsub": return shell.subSrc(p.src);
  }
};

/** Expand one word into zero or more fields (splitting + quote removal). */
export const expandWord = async (shell: Shell, word: Word): Promise<string[]> => {
  const pw = parseWord(word.text);

  // "$@" / $@ : each positional parameter becomes its own field.
  if (pw.parts.length === 1) {
    const only = pw.parts[0]!;
    if (only.k === "special" && only.name === "@") return [...shell.positional];
  }

  const chars: string[] = [];
  const sp: boolean[] = [];
  let anchored = pw.anchored;
  for (const p of pw.parts) {
    if (p.k === "lit") {
      for (const c of p.s) {
        chars.push(c);
        sp.push(false);
      }
      anchored = true;
      continue;
    }
    const val = await partValue(shell, p);
    const splittable = !p.quoted;
    for (const c of val) {
      chars.push(c);
      sp.push(splittable);
    }
  }
  return splitTaggedFields(chars, sp, anchored);
};

/** Expand several words, flattening the fields into a single argv list. */
export const expandWords = async (shell: Shell, words: Word[]): Promise<string[]> => {
  const argv: string[] = [];
  for (const w of words) argv.push(...(await expandWord(shell, w)));
  return argv;
};

/** Expand text with no field splitting (assignment RHS, arithmetic operands). */
export const expandNoSplit = async (shell: Shell, text: string): Promise<string> => {
  const pw = parseWord(text);
  let out = "";
  for (const p of pw.parts) {
    out += p.k === "lit" ? p.s : await partValue(shell, p);
  }
  return out;
};
