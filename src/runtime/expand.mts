/* Word expansion for the interpreter path — the M0–M1 slice of bash's
 * `subst.c` (GPLv3+; see NOTICE.md).
 *
 * Works from the shared word structure (parser/word.mts): resolve each part to
 * a value, tag characters from unquoted expansions as splittable, then field-
 * split on the default IFS. The AOT emitter compiles the same structure to
 * TypeScript instead; `splitTaggedFields` is shared so both agree. */

import type { Word } from "../ast/nodes.mts";
import type { Shell } from "./shell.mts";
import { parseArith, parseDquote, parseParam, parseWord } from "../parser/word.mts";
import type { Param, ParsedWord, WordPart } from "../parser/word.mts";
import { braceExpand } from "../parser/brace.mts";
import { evalArith } from "./arith.mts";
import { changeCase, replaceGlob, substr, transform, trimPrefix, trimSuffix } from "./param.mts";
import { ExitSignal } from "./types.mts";

const isWsChar = (c: string): boolean => c === " " || c === "\t" || c === "\n";

/** Split an assembled, per-character-tagged buffer into fields on IFS (bash
 *  rules): runs of IFS-whitespace delimit without empty fields, while each
 *  IFS non-whitespace char is its own delimiter (so `a,,b` -> a, "", b), with
 *  surrounding IFS-whitespace absorbed. `ifs` undefined means the default
 *  ` \t\n`; a trailing delimiter yields no trailing empty field. */
export const splitTaggedFields = (
  chars: string[],
  splittable: boolean[],
  anchored: boolean,
  ifs?: string,
): string[] => {
  const IFS = ifs === undefined ? " \t\n" : ifs;
  const ws = new Set<string>();
  const nw = new Set<string>();
  for (const c of IFS) (isWsChar(c) ? ws : nw).add(c);
  const n = chars.length;
  const isWs = (i: number): boolean => splittable[i]! && ws.has(chars[i]!);
  const isNw = (i: number): boolean => splittable[i]! && nw.has(chars[i]!);

  if (n === 0) return anchored ? [""] : [];
  const fields: string[] = [];
  let i = 0;
  while (i < n && isWs(i)) i++; // strip leading IFS whitespace
  while (i < n) {
    let field = "";
    while (i < n && !isWs(i) && !isNw(i)) { field += chars[i]; i++; }
    fields.push(field);
    if (i >= n) break;
    if (isNw(i)) {
      i++; // a single non-whitespace delimiter, plus any trailing whitespace
      while (i < n && isWs(i)) i++;
    } else {
      while (i < n && isWs(i)) i++; // a run of whitespace...
      if (i < n && isNw(i)) { i++; while (i < n && isWs(i)) i++; } // ...may end at one non-ws delim
    }
    if (i >= n) break; // trailing delimiter: no extra empty field
  }
  if (fields.length === 0) return anchored ? [""] : [];
  return fields;
};

const starSep = (shell: Shell): string => shell.starSep();

const specialValue = (shell: Shell, name: string): string => {
  switch (name) {
    case "?": return String(shell.status);
    case "$": return String(shell.pid);
    case "!": return String(shell.lastBgPid);
    case "-": return shell.optionFlags();
    case "#": return String(shell.positional.length);
    case "*": return shell.positional.join(starSep(shell));
    case "@": return shell.positional.join(" ");
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

export const evalParam = async (shell: Shell, prm: Param, quoted = false): Promise<string> => {
  // ${!name[@]} / ${!name[*]} — array indices.
  if (prm.indices) return shell.arrayIndices(prm.name).join(" ");
  // ${!prefix*} / ${!prefix@} — names of set variables sharing a prefix.
  if (prm.names) return shell.matchNames(prm.name).join(" ");
  // ${!ref} — indirect: the ref names another variable (possibly `arr[i]`, a
  // positional like `1`, or a special like `?`). Any operator applies to that
  // target, so re-parse the referenced name and evaluate it with the operator.
  if (prm.indirect) {
    const targetName = prm.special ? specialValue(shell, prm.name) : (shell.getVar(prm.name) ?? "");
    if (targetName === "") {
      // The ref itself is unset/empty: no target to expand.
      const empty: Param = { ...prm, indirect: false, name: "", special: true, sub: "" };
      return prm.op === "" && !prm.length ? "" : evalParam(shell, empty);
    }
    return evalParam(shell, { ...parseParam(targetName), op: prm.op, arg: prm.arg, arg2: prm.arg2, length: prm.length });
  }
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
    const pat = await shell.patExpand(prm.arg);
    return listValues(shell, prm).map((x) => changeCase(x, prm.op, pat)).join(" ");
  }
  // ${arr[@]#pat} / %pat / /pat/repl — string op applied to each element.
  if (isList(prm) && STR_OPS.has(prm.op)) {
    const pat = await shell.patExpand(prm.arg);
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
    rawVal = vals.join(prm.sub === "*" ? starSep(shell) : " ");
    isSet = vals.length > 0;
  } else if (prm.sub !== "") {
    rawVal = await shell.elemGet(prm.name, prm.sub);
    isSet = rawVal !== undefined;
  } else {
    rawVal = shell.getVar(prm.name);
    isSet = rawVal !== undefined;
  }
  const val = rawVal ?? "";
  // A default value (`${x-…}`) inside `"…"` uses double-quote backslash rules.
  const arg = (): Promise<string> =>
    quoted ? expandDquote(shell, prm.arg) : expandNoSplit(shell, prm.arg);
  const arg2 = (): Promise<string> => expandNoSplit(shell, prm.arg2);
  // `#`/`%`/`/` operands are quote-aware globs; the replacement stays literal.
  const pat = (): Promise<string> => shell.patExpand(prm.arg);

  // set -u: referencing an unset parameter errors — for a plain `${x}`, `${#x}`,
  // and the value-using operators (substring, trim, replace, case, transform),
  // but NOT the `-`/`:-`/`+`/`:+`/`=`/`:=`/`?`/`:?` operators that handle unset.
  const altOp = new Set(["-", ":-", "+", ":+", "=", ":=", "?", ":?"]);
  if (shell.opts.nounset && !altOp.has(prm.op)) {
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
    case "#": return trimPrefix(val, await pat(), false, shell.shopts.extglob);
    case "##": return trimPrefix(val, await pat(), true, shell.shopts.extglob);
    case "%": return trimSuffix(val, await pat(), false, shell.shopts.extglob);
    case "%%": return trimSuffix(val, await pat(), true, shell.shopts.extglob);
    case "/": return replaceGlob(val, await pat(), await arg2(), false, "", shell.shopts.extglob);
    case "//": return replaceGlob(val, await pat(), await arg2(), true, "", shell.shopts.extglob);
    case "/#": return replaceGlob(val, await pat(), await arg2(), false, "#", shell.shopts.extglob);
    case "/%": return replaceGlob(val, await pat(), await arg2(), false, "%", shell.shopts.extglob);
    case ":": {
      const off = Number(evalArith(shell, await arg()));
      const len = prm.arg2 === "" ? undefined : Number(evalArith(shell, await arg2()));
      return substr(val, off, len);
    }
    case "^": case "^^": case ",": case ",,": return changeCase(val, prm.op, await pat());
    default:
      throw new Error(`parameter operator not supported: ${prm.op}`);
  }
};

const partValue = async (shell: Shell, p: Exclude<WordPart, { k: "lit" }>): Promise<string> => {
  switch (p.k) {
    case "param": return evalParam(shell, p.p, p.quoted);
    case "arith": return evalArith(shell, await expandArith(shell, p.expr)).toString();
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
        const pat = await shell.patExpand(p.arg);
        return listValues(shell, p).map((x) => changeCase(x, p.op, pat));
      }
      // "${arr[@]#pat}" etc. — string op on each element, one field each.
      if (STR_OPS.has(p.op) && (p.sub === "@" || (p.special && p.name === "@"))) {
        const pat = await shell.patExpand(p.arg);
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
  const fields = splitTaggedFields(chars, sp, anchored, shell.getVar("IFS"));
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

const ASSIGN_WORD = /^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/;
/** Expand the words of an assignment-builtin command (declare/local/export/…):
 *  a `name=value` operand is an assignment word (its RHS is not field-split or
 *  globbed), while the command name, flags, and other args expand normally. */
export const expandWordsAssign = async (shell: Shell, words: Word[]): Promise<string[]> => {
  const argv: string[] = [];
  for (let j = 0; j < words.length; j++) {
    const w = words[j]!;
    if (j > 0 && ASSIGN_WORD.test(w.text)) argv.push(await expandNoSplit(shell, w.text));
    else for (const t of braceExpand(w.text)) argv.push(...(await expandWord(shell, makeWordLocal(t))));
  }
  return argv;
};

const makeWordLocal = (text: string): Word => ({ text, flags: 0 });

/** Expand text with no field splitting (assignment RHS, arithmetic operands). */
export const expandNoSplit = async (shell: Shell, text: string): Promise<string> => {
  return expandParsed(shell, parseWord(text));
};

/** Expand an assignment's value: like expandNoSplit but tilde also expands
 *  after each `:` (bash's assignment tilde expansion). */
export const expandAssign = async (shell: Shell, text: string): Promise<string> => {
  return expandParsed(shell, parseWord(text, true));
};

/** Expand text as double-quoted content (a `${x-default}` default within `"…"`). */
export const expandDquote = async (shell: Shell, text: string): Promise<string> => {
  return expandParsed(shell, parseDquote(text));
};

/** Expand an arithmetic expression's `$`-substitutions ($x, $(...), ${...}),
 *  leaving `<(`/`>(` as operators (not process substitutions). */
export const expandArith = async (shell: Shell, text: string): Promise<string> => {
  return expandParsed(shell, parseArith(text));
};

/** Concatenate an already-parsed word's parts into a single string (no split). */
export const expandParsed = async (shell: Shell, pw: ParsedWord): Promise<string> => {
  let out = "";
  for (const p of pw.parts) {
    out += p.k === "lit" ? p.s : await partValue(shell, p);
  }
  return out;
};
