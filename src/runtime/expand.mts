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
import { changeCase, replaceGlob, substr, transform, trimPrefix, trimSuffix } from "./param.mts";
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
    case "-": return shell.optionFlags();
    case "#": return String(shell.positional.length);
    case "@": case "*": return shell.positional.join(" ");
    case "0": return shell.name;
    default: return shell.positional[Number(name) - 1] ?? "";
  }
};

/** `${arr[@]:off:len}` / `${@:off:len}` — the `:` op applied to a whole list. */
const isSlice = (prm: Param): boolean =>
  prm.op === ":" &&
  (prm.sub === "@" || prm.sub === "*" || (prm.special && (prm.name === "@" || prm.name === "*")));

const sliceValues = (shell: Shell, prm: Param): Promise<string[]> =>
  prm.special ? shell.slicePos(prm.arg, prm.arg2) : shell.sliceArr(prm.name, prm.arg, prm.arg2);

/** `${x@op}` / `${arr[@]@op}` — is the operator a `@`-transform? */
const isTransform = (prm: Param): boolean => prm.op.startsWith("@");
/** `${x^}` `${x^^}` `${x,}` `${x,,}` — case-modification operator? */
const isCaseOp = (op: string): boolean => op === "^" || op === "^^" || op === "," || op === ",,";
/** Whether this param names a whole list (@/* subscript or special @/*). */
const isList = (prm: Param): boolean =>
  prm.sub === "@" || prm.sub === "*" || (prm.special && (prm.name === "@" || prm.name === "*"));
const listValues = (shell: Shell, prm: Param): string[] =>
  prm.special ? [...shell.positional] : shell.arrayValues(prm.name);

/** `#`/`##`/`%`/`%%`/`/`/`//`/`/#`/`/%` — prefix/suffix/replace string ops. */
const STR_OPS = new Set(["#", "##", "%", "%%", "/", "//", "/#", "/%"]);
const applyStrOp = (op: string, v: string, pat: string, repl: string, extglob = false): string => {
  switch (op) {
    case "#": return trimPrefix(v, pat, false, extglob);
    case "##": return trimPrefix(v, pat, true, extglob);
    case "%": return trimSuffix(v, pat, false, extglob);
    case "%%": return trimSuffix(v, pat, true, extglob);
    case "/": return replaceGlob(v, pat, repl, false, "", extglob);
    case "//": return replaceGlob(v, pat, repl, true, "", extglob);
    case "/#": return replaceGlob(v, pat, repl, false, "#", extglob);
    case "/%": return replaceGlob(v, pat, repl, false, "%", extglob);
    default: return v;
  }
};

const evalParam = async (shell: Shell, prm: Param): Promise<string> => {
  // ${!name[@]} / ${!name[*]} — array indices.
  if (prm.indices) return shell.arrayIndices(prm.name).join(" ");
  // ${!prefix*} / ${!prefix@} — names of set variables sharing a prefix.
  if (prm.names) return shell.matchNames(prm.name).join(" ");
  // ${!name} — indirect (value of the variable named by $name).
  if (prm.indirect) return shell.indirect(prm.name);
  // ${arr[@]:off:len} / ${@:off:len} — slice a list; scalar contexts join it.
  if (isSlice(prm)) return (await sliceValues(shell, prm)).join(" ");
  // ${x@op} / ${arr[@]@op} — transform (per element for lists).
  if (isTransform(prm)) {
    if (isList(prm)) return listValues(shell, prm).map((x) => transform(prm.op, x)).join(" ");
    const base = prm.special
      ? specialValue(shell, prm.name)
      : prm.sub !== "" ? (await shell.elemGet(prm.name, prm.sub)) ?? "" : shell.getVar(prm.name) ?? "";
    return transform(prm.op, base);
  }
  // ${arr[@]^^} etc. — case-modify each element of a list.
  if (isCaseOp(prm.op) && isList(prm)) {
    const pat = await expandNoSplit(shell, prm.arg);
    return listValues(shell, prm).map((x) => changeCase(x, prm.op, pat)).join(" ");
  }
  // ${arr[@]#pat} / %pat / /pat/repl — string op applied to each element.
  if (isList(prm) && STR_OPS.has(prm.op)) {
    const pat = await expandNoSplit(shell, prm.arg);
    const repl = prm.op[0] === "/" ? await expandNoSplit(shell, prm.arg2) : "";
    const eg = shell.shopts.extglob;
    return listValues(shell, prm).map((x) => applyStrOp(prm.op, x, pat, repl, eg)).join(" ");
  }

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
    case "#": return trimPrefix(val, await arg(), false, shell.shopts.extglob);
    case "##": return trimPrefix(val, await arg(), true, shell.shopts.extglob);
    case "%": return trimSuffix(val, await arg(), false, shell.shopts.extglob);
    case "%%": return trimSuffix(val, await arg(), true, shell.shopts.extglob);
    case "/": return replaceGlob(val, await arg(), await arg2(), false, "", shell.shopts.extglob);
    case "//": return replaceGlob(val, await arg(), await arg2(), true, "", shell.shopts.extglob);
    case "/#": return replaceGlob(val, await arg(), await arg2(), false, "#", shell.shopts.extglob);
    case "/%": return replaceGlob(val, await arg(), await arg2(), false, "%", shell.shopts.extglob);
    case ":": {
      const off = Number(evalArith(shell, await arg()));
      const len = prm.arg2 === "" ? undefined : Number(evalArith(shell, await arg2()));
      return substr(val, off, len);
    }
    case "^": case "^^": case ",": case ",,": return changeCase(val, prm.op, await arg());
    default:
      throw new Error(`parameter operator not supported: ${prm.op}`);
  }
};

const partValue = async (shell: Shell, p: Exclude<WordPart, { k: "lit" }>): Promise<string> => {
  switch (p.k) {
    case "param": return evalParam(shell, p.p);
    case "arith": return evalArith(shell, await expandNoSplit(shell, p.expr)).toString();
    case "cmdsub": return shell.subSrc(p.src);
    case "procsub": return shell.procSub(p.dir, p.src);
  }
};

/** Expand one word into zero or more fields (splitting + quote removal). */
export const expandWord = async (shell: Shell, word: Word): Promise<string[]> => {
  const pw = parseWord(word.text);

  // "$@" / $@ and "${arr[@]}" / ${arr[@]}: each element becomes its own field.
  if (pw.parts.length === 1) {
    const only = pw.parts[0]!;
    if (only.k === "param") {
      const p = only.p;
      if (p.op === "" && !p.length) {
        if (p.names === "@") return shell.matchNames(p.name); // "${!prefix@}"
        if (p.special && p.name === "@") return [...shell.positional];
        if (p.sub === "@") return p.indices ? shell.arrayIndices(p.name).map(String) : shell.arrayValues(p.name);
      }
      // "${arr[@]:i:n}" / "${@:i:n}" — sliced @ keeps each element as a field.
      if (isSlice(p) && (p.sub === "@" || (p.special && p.name === "@"))) {
        return sliceValues(shell, p);
      }
      // "${arr[@]@op}" / "${@@op}" — transform each element, one field each.
      if (isTransform(p) && (p.sub === "@" || (p.special && p.name === "@"))) {
        return listValues(shell, p).map((x) => transform(p.op, x));
      }
      // "${arr[@]^^}" etc. — case-modify each element, one field each.
      if (isCaseOp(p.op) && (p.sub === "@" || (p.special && p.name === "@"))) {
        const pat = await expandNoSplit(shell, p.arg);
        return listValues(shell, p).map((x) => changeCase(x, p.op, pat));
      }
      // "${arr[@]#pat}" etc. — string op on each element, one field each.
      if (STR_OPS.has(p.op) && (p.sub === "@" || (p.special && p.name === "@"))) {
        const pat = await expandNoSplit(shell, p.arg);
        const repl = p.op[0] === "/" ? await expandNoSplit(shell, p.arg2) : "";
        const eg = shell.shopts.extglob;
        return listValues(shell, p).map((x) => applyStrOp(p.op, x, pat, repl, eg));
      }
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
    const splittable = p.k !== "procsub" && !p.quoted;
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
