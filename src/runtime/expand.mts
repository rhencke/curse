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
import type { Param, ParsedWord, WordPart } from "../parser/word.mts";
import { braceExpand } from "../parser/brace.mts";
import { evalArith } from "./arith.mts";
import { replaceGlob, substr, trimPrefix, trimSuffix } from "./param.mts";
import { ExitSignal } from "./types.mts";

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
    case "!": return String(shell.lastBgPid);
    case "#": return String(shell.positional.length);
    case "@": case "*": return shell.positional.join(" ");
    case "0": return shell.name;
    default: return shell.positional[Number(name) - 1] ?? "";
  }
};

const evalParam = async (shell: Shell, prm: Param): Promise<string> => {
  // ${!name[@]} / ${!name[*]} — array indices.
  if (prm.indices) return shell.arrayIndices(prm.name).join(" ");
  // ${!name} — indirect (value of the variable named by $name).
  if (prm.indirect) return shell.indirect(prm.name);

  // Resolve the referenced value (scalar, array element, or all elements).
  let rawVal: string | undefined;
  let isSet: boolean;
  if (prm.special) {
    rawVal = specialValue(shell, prm.name);
    isSet = true;
  } else if (prm.sub === "@" || prm.sub === "*") {
    const vals = shell.arrayValues(prm.name);
    if (prm.length) return String(vals.length); // ${#arr[@]}
    rawVal = vals.join(" ");
    isSet = vals.length > 0;
  } else if (prm.sub !== "") {
    rawVal = await shell.elemGet(prm.name, prm.sub);
    isSet = rawVal !== undefined;
  } else {
    rawVal = shell.getVar(prm.name);
    isSet = rawVal !== undefined;
  }
  const val = rawVal ?? "";
  const arg = (): Promise<string> => expandNoSplit(shell, prm.arg);
  const arg2 = (): Promise<string> => expandNoSplit(shell, prm.arg2);

  // set -u: a plain reference (or ${#x}) to an unset parameter is an error.
  if (prm.op === "" && shell.opts.nounset) {
    const unbound = prm.special
      ? /^[0-9]+$/.test(prm.name) && Number(prm.name) > shell.positional.length
      : !isSet;
    if (unbound) {
      shell.io.err(`${shell.name}: ${prm.name}: unbound variable\n`);
      throw new ExitSignal(1);
    }
  }

  if (prm.length) {
    if (prm.name === "@" || prm.name === "*" || prm.name === "#") {
      return String(shell.positional.length);
    }
    return String(val.length);
  }
  switch (prm.op) {
    case "": return val;
    case ":-": return val !== "" ? val : await arg();
    case "-": return isSet ? val : await arg();
    case ":+": return val !== "" ? await arg() : "";
    case "+": return isSet ? await arg() : "";
    case ":?": return val !== "" ? val : shell.paramError(prm.name, await arg());
    case "?": return isSet ? val : shell.paramError(prm.name, await arg());
    case ":=": {
      if (val !== "") return val;
      const d = await arg();
      shell.setVar(prm.name, d);
      return d;
    }
    case "=": {
      if (isSet) return val;
      const d = await arg();
      shell.setVar(prm.name, d);
      return d;
    }
    case "#": return trimPrefix(val, await arg(), false);
    case "##": return trimPrefix(val, await arg(), true);
    case "%": return trimSuffix(val, await arg(), false);
    case "%%": return trimSuffix(val, await arg(), true);
    case "/": return replaceGlob(val, await arg(), await arg2(), false, "");
    case "//": return replaceGlob(val, await arg(), await arg2(), true, "");
    case "/#": return replaceGlob(val, await arg(), await arg2(), false, "#");
    case "/%": return replaceGlob(val, await arg(), await arg2(), false, "%");
    case ":": {
      const off = Number(evalArith(shell, await arg()));
      const len = prm.arg2 === "" ? undefined : Number(evalArith(shell, await arg2()));
      return substr(val, off, len);
    }
    default:
      throw new Error(`parameter operator not supported: ${prm.op}`);
  }
};

const partValue = async (shell: Shell, p: Exclude<WordPart, { k: "lit" }>): Promise<string> => {
  switch (p.k) {
    case "param": return evalParam(shell, p.p);
    case "arith": return evalArith(shell, await expandNoSplit(shell, p.expr)).toString();
    case "cmdsub": return shell.subSrc(p.src);
  }
};

/** Expand one word into zero or more fields (splitting + quote removal). */
export const expandWord = async (shell: Shell, word: Word): Promise<string[]> => {
  const pw = parseWord(word.text);

  // "$@" / $@ and "${arr[@]}" / ${arr[@]}: each element becomes its own field.
  if (pw.parts.length === 1) {
    const only = pw.parts[0]!;
    if (only.k === "param" && only.p.op === "" && !only.p.length) {
      const p = only.p;
      if (p.special && p.name === "@") return [...shell.positional];
      if (p.sub === "@") return p.indices ? shell.arrayIndices(p.name).map(String) : shell.arrayValues(p.name);
    }
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
  const fields = splitTaggedFields(chars, sp, anchored);
  return pw.hasQuote ? fields : shell.glob(fields);
};

/** Expand several words (brace expansion first), flattening into an argv list. */
export const expandWords = async (shell: Shell, words: Word[]): Promise<string[]> => {
  const argv: string[] = [];
  for (const w of words) {
    for (const t of braceExpand(w.text)) argv.push(...(await expandWord(shell, makeWordLocal(t))));
  }
  return argv;
};

const makeWordLocal = (text: string): Word => ({ text, flags: 0 });

/** Expand text with no field splitting (assignment RHS, arithmetic operands). */
export const expandNoSplit = async (shell: Shell, text: string): Promise<string> => {
  return expandParsed(shell, parseWord(text));
};

/** Concatenate an already-parsed word's parts into a single string (no split). */
export const expandParsed = async (shell: Shell, pw: ParsedWord): Promise<string> => {
  let out = "";
  for (const p of pw.parts) {
    out += p.k === "lit" ? p.s : await partValue(shell, p);
  }
  return out;
};
