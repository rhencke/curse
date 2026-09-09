/* AOT emitter: compile a command tree into a standalone `.mts` module.
 *
 * The output is real TypeScript that leans on JavaScript's dynamism:
 *  - a command is a live lookup on the `sh.commands` Proxy, so a bash function
 *    definition (`sh.commands.name = sh.func(...)`) monkeypatches the binding;
 *  - assignment is property mutation on `sh.env`;
 *  - word expansion compiles inline (template literals; `sh.fields`/`sh.S` for
 *    field splitting; inline `sh.sub(...)` for command substitution);
 *  - control flow becomes native TS. `sh.status` carries `$?`.
 *
 * Word structure comes from the shared parser (parser/word.mts), so the
 * compiled output and the interpreter agree. */

import type { ArithForCommand, Command, CondExpr, FunctionDef, SimpleCommand, Word } from "../ast/nodes.mts";
import { CMD_INVERT_RETURN } from "../ast/nodes.mts";
import { parse } from "../parser/parser.mts";
import { parseDquote, parseHeredoc, parseWord } from "../parser/word.mts";
import type { Param, WordPart } from "../parser/word.mts";
import { braceExpand } from "../parser/brace.mts";
import { globToRegExpSource, hasExtglob } from "../runtime/glob.mts";
import { parseArithAst } from "../runtime/arith.mts";
import type { ArithNode } from "../runtime/arith.mts";

export interface EmitOptions {
  /** Import specifier (path or file: URL) for the runtime's `Shell`. */
  runtimeSpecifier: string;
  /** Emit a `source`-able fragment (a default-exported `(sh) => …` that runs
   *  against an injected shell) rather than a standalone program. */
  fragment?: boolean;
}

const pad = (n: number): string => "  ".repeat(n);
/** Add one indent level to every non-empty line of an already-emitted block. */
const bump = (s: string): string => s.replace(/^(?=.)/gm, "  ");
/** An assignment word: name(1), optional `[sub(3)]`(2), optional `+`(4), value(5). */
const ASSIGN = /^([A-Za-z_][A-Za-z0-9_]*)(\[([^\]]*)\])?(\+)?=([\s\S]*)$/;

/** Builtins whose `name=value` operands are assignment words (RHS not split/globbed). */
const ASSIGN_BUILTINS = new Set(["declare", "typeset", "local", "export", "readonly"]);

/** An array-literal element of the form `[subscript]=value` / `[subscript]+=value`. */
const ELEM_ASSIGN = /^\[.*\]\+?=/;

const isCaseOp = (op: string): boolean => op === "^" || op === "^^" || op === "," || op === ",,";
const STR_OPS = new Set(["#", "##", "%", "%%", "/", "//", "/#", "/%"]);
/** Alternation operators that keep a set `[@]` array as per-element fields. */
const ALT_OPS = new Set(["-", ":-", "+", ":+", "?", ":?"]);
/** `[[ ]]` comparison operators that evaluate their operands arithmetically
 *  (and so can raise a fatal arithmetic error), unlike the string ops. */
const ARITH_COND_OPS = new Set(["-eq", "-ne", "-lt", "-le", "-gt", "-ge"]);

/* ---- compile-time arithmetic: turn a `$(( ))` / `for (( ))` expression into
   native-JS BigInt code (parsed once here) instead of re-parsing the string at
   runtime. Returns null to fall back to the runtime evaluator for anything not
   statically compilable (a `$`/backtick expansion, or an array subscript). ---- */

const WRAP_BINOPS: Record<string, string> = {
  "+": "+", "-": "-", "*": "*", "<<": "<<", ">>": ">>", "&": "&", "^": "^", "|": "|",
};
const CMP_BINOPS: Record<string, string> = { "<": "<", "<=": "<=", ">": ">", ">=": ">=" };

const arithBinJS = (op: string, l: string, r: string): string | null => {
  if (op in WRAP_BINOPS) return `sh.aw((${l}) ${WRAP_BINOPS[op]} (${r}))`;
  if (op in CMP_BINOPS) return `((${l}) ${CMP_BINOPS[op]} (${r}) ? 1n : 0n)`;
  if (op === "/") return `sh.adiv((${l}), (${r}))`;
  if (op === "%") return `sh.amod((${l}), (${r}))`;
  if (op === "**") return `sh.apow((${l}), (${r}))`;
  if (op === "==") return `((${l}) === (${r}) ? 1n : 0n)`;
  if (op === "!=") return `((${l}) !== (${r}) ? 1n : 0n)`;
  return null;
};

const arithNodeJS = (n: ArithNode, hoist: Map<string, string> | null): string | null => {
  const J = JSON.stringify;
  // Read/write a scalar via a hoisted box (no scope lookup) when available.
  const box = (name: string): string | undefined => hoist?.get(name);
  switch (n.t) {
    case "num":
      return `${n.v}n`;
    case "var": {
      if (n.index !== undefined) return null;
      const b = box(n.name);
      return b !== undefined ? `sh.bxget(${b})` : `sh.aget(${J(n.name)})`;
    }
    case "unary": {
      const e = arithNodeJS(n.e, hoist);
      if (e === null) return null;
      if (n.op === "+") return `(${e})`;
      if (n.op === "-") return `sh.aw(-(${e}))`;
      if (n.op === "!") return `((${e}) === 0n ? 1n : 0n)`;
      return `sh.aw(~(${e}))`; // "~"
    }
    case "incr": {
      if (n.index !== undefined) return null;
      const d = n.op === "++" ? "1n" : "-1n";
      const b = box(n.name);
      return b !== undefined
        ? `sh.bxinc(${b}, ${d}, ${n.post})`
        : `sh.ainc(${J(n.name)}, ${d}, ${n.post})`;
    }
    case "bin": {
      const l = arithNodeJS(n.l, hoist), r = arithNodeJS(n.r, hoist);
      return l === null || r === null ? null : arithBinJS(n.op, l, r);
    }
    case "logic": {
      const l = arithNodeJS(n.l, hoist), r = arithNodeJS(n.r, hoist);
      if (l === null || r === null) return null;
      return `((${l}) !== 0n ${n.op} (${r}) !== 0n ? 1n : 0n)`;
    }
    case "ternary": {
      const c = arithNodeJS(n.c, hoist), a = arithNodeJS(n.a, hoist), b = arithNodeJS(n.b, hoist);
      return c === null || a === null || b === null ? null : `((${c}) !== 0n ? (${a}) : (${b}))`;
    }
    case "comma": {
      const l = arithNodeJS(n.l, hoist), r = arithNodeJS(n.r, hoist);
      return l === null || r === null ? null : `((${l}), (${r}))`;
    }
    case "assign": {
      if (n.index !== undefined) return null;
      const r = arithNodeJS(n.e, hoist);
      if (r === null) return null;
      const b = box(n.name);
      const read = b !== undefined ? `sh.bxget(${b})` : `sh.aget(${J(n.name)})`;
      const val = n.op === "=" ? `(${r})` : arithBinJS(n.op.slice(0, -1), read, `(${r})`);
      if (val === null) return null;
      return b !== undefined ? `sh.bxset(${b}, ${val})` : `sh.aset(${J(n.name)}, ${val})`;
    }
  }
};

/** Compile an arithmetic expression to a JS BigInt expression, or null if it
 *  needs the runtime evaluator (empty, `$`/backtick expansion, or a subscript).
 *  `hoist` maps loop variables to their pre-resolved box JS variable. */
const arithToJS = (text: string, hoist: Map<string, string> | null = null): string | null => {
  if (text === "" || /[$`]/.test(text)) return null;
  let ast: ArithNode;
  try {
    ast = parseArithAst(text);
  } catch {
    return null;
  }
  return arithNodeJS(ast, hoist);
};

const CMP_JS: Record<string, string> = {
  "<": "<", "<=": "<=", ">": ">", ">=": ">=", "==": "===", "!=": "!==",
};

// Var-box hoisting: a word/command is "opaque" if it can run arbitrary code (a
// command substitution or process substitution), and only these command words
// are known not to restructure the scope (unset/declare/read/functions can).
const OPAQUE = /\$\((?!\()|[`]|<\(|>\(/;
const SAFE_CMDS = new Set(["echo", "printf", ":", "true", "false", "test", "["]);

/** Context for the loop hoisting analysis: names assigned via arith (candidates)
 *  vs. names ever used with a subscript (arrays — never hoisted); `ok` clears
 *  when an unsafe construct makes hoisting unsound for the whole loop. */
interface HoistCtx {
  ok: boolean;
  targets: Set<string>;
  subscripted: Set<string>;
}

/** Compile an arithmetic expression used as a boolean (a loop test / `(( ))`
 *  truthiness) to a JS boolean, avoiding the `? 1n : 0n) !== 0n` round-trip when
 *  the top node is already a comparison. Returns null to fall back. */
const arithToJSBool = (text: string, hoist: Map<string, string> | null = null): string | null => {
  if (text === "" || /[$`]/.test(text)) return null;
  let ast: ArithNode;
  try {
    ast = parseArithAst(text);
  } catch {
    return null;
  }
  if (ast.t === "bin" && ast.op in CMP_JS) {
    const l = arithNodeJS(ast.l, hoist), r = arithNodeJS(ast.r, hoist);
    if (l !== null && r !== null) return `(${l}) ${CMP_JS[ast.op]} (${r})`;
  }
  const js = arithNodeJS(ast, hoist);
  return js === null ? null : `(${js}) !== 0n`;
};

/** Compile-time glob pattern from a static (expansion-free) word: quoted or
 *  escaped characters are backslashed so they match literally. */
const staticGlobPattern = (raw: string): string => {
  const esc = (s: string): string => s.replace(/[^A-Za-z0-9]/g, "\\$&");
  let out = "";
  let i = 0;
  while (i < raw.length) {
    const c = raw[i]!;
    if (c === "\\") {
      const n = raw[i + 1];
      if (n === undefined) { out += "\\\\"; i++; } else { out += esc(n); i += 2; }
      continue;
    }
    if (c === "'") {
      i++;
      while (i < raw.length && raw[i] !== "'") out += esc(raw[i++]!);
      i++;
      continue;
    }
    if (c === '"') {
      i++;
      let seg = "";
      while (i < raw.length && raw[i] !== '"') {
        if (raw[i] === "\\" && i + 1 < raw.length) { seg += raw[i + 1]!; i += 2; continue; }
        seg += raw[i++]!;
      }
      i++;
      out += esc(seg);
      continue;
    }
    out += c;
    i++;
  }
  return out;
};
const ident = (s: string): boolean => /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);
const escTemplate = (s: string): string =>
  s.replace(/\\/g, "\\\\").replace(/`/g, "\\`").replace(/\$/g, "\\$");

interface WordCode {
  /** true => a `...spread` producing zero+ args; false => a single arg. */
  spread: boolean;
  code: string;
}

/** Does the script use `set` anywhere? If not, `set -e` can never be on, so we
 *  skip the errexit `condDepth` guards and keep the output clean. */
const usesSet = (cmd: Command): boolean => {
  switch (cmd.type) {
    case "simple": {
      // `set` (errexit) and trap/eval/source (which may install an ERR trap)
      // all need the condDepth guards so failures in conditions/&&/|| are
      // exempt from errexit and the ERR trap.
      const w0 = cmd.words[0]?.text;
      return w0 === "set" || w0 === "trap" || w0 === "eval" || w0 === "source" || w0 === ".";
    }
    case "connection": return usesSet(cmd.first) || usesSet(cmd.second);
    case "pipeline": return cmd.stages.some(usesSet);
    case "background": return usesSet(cmd.command);
    case "group": case "subshell": return usesSet(cmd.body);
    case "if":
      return usesSet(cmd.test) || usesSet(cmd.consequent) ||
        (cmd.alternate !== null && usesSet(cmd.alternate));
    case "while": return usesSet(cmd.test) || usesSet(cmd.body);
    case "for": case "select": case "arith_for": case "function": return usesSet(cmd.body);
    case "case": return cmd.clauses.some((c) => c.body !== null && usesSet(c.body));
    case "arith": case "cond": case "array_assign": return false;
  }
};

class Emitter {
  private forId = 0;
  private caseId = 0;
  private hoistSeq = 0;
  /** Loop variables whose Var box is hoisted (name → JS box variable), set while
   *  compiling a proven-safe arith loop so arith accesses skip the scope lookup. */
  private hoist: Map<string, string> | null = null;
  guards = false;

  /** Emit a command in an errexit-suppressed scope (a condition, `!`, or the
   *  non-final operand of && / ||). When the script never uses `set`, errexit
   *  can't be on, so we skip the scope and keep the output clean. */
  private suppressed(child: Command, ind: number): string {
    if (!this.guards) return this.command(child, ind);
    const i = pad(ind);
    return `${i}{\n${pad(ind + 1)}using _ = sh.suppress();\n${this.command(child, ind + 1)}\n${i}}`;
  }

  /* ---------------- words ---------------- */

  private specialExpr(name: string): string {
    switch (name) {
      case "?": return "String(sh.status)";
      case "#": return "String(sh.positional.length)";
      case "$": return "String(sh.pid)";
      case "!": return "String(sh.lastBgPid)";
      case "-": return "sh.optionFlags()";
      case "0": return "sh.name";
      case "*": return "sh.positional.join(sh.starSep())";
      case "@": return 'sh.positional.join(" ")';
      default: return `sh.param(${Number(name)})`;
    }
  }

  /** The value of a param reference as a string expression (scalar, array
   *  element, or all elements joined). Not nounset-aware — plain `${x}` uses
   *  sh.ref() below. */
  private valStr(prm: Param): string {
    const J = JSON.stringify;
    if (prm.special) return this.specialExpr(prm.name);
    if (prm.sub === "@" || prm.sub === "*") {
      return `sh.arrayValues(${J(prm.name)}).join(${prm.sub === "*" ? "sh.starSep()" : '" "'})`;
    }
    if (prm.sub !== "") {
      return `((await sh.elemGet(${J(prm.name)}, ${J(prm.sub)})) ?? "")`;
    }
    return `sh.env.${prm.name}`;
  }

  /** `${arr[@]:off:len}` / `${@:off:len}` — is the `:` op slicing a whole list? */
  private isSlice(prm: Param): boolean {
    return prm.op === ":" &&
      (prm.sub === "@" || prm.sub === "*" || (prm.special && (prm.name === "@" || prm.name === "*")));
  }

  /** A `Promise<string[]>` expression for the sliced list. */
  private sliceExpr(prm: Param): string {
    const J = JSON.stringify;
    return prm.special
      ? `await sh.slicePos(${J(prm.arg)}, ${J(prm.arg2)})`
      : `await sh.sliceArr(${J(prm.name)}, ${J(prm.arg)}, ${J(prm.arg2)})`;
  }

  /** Whether this param names a whole list (@/* subscript or special @/*). */
  private isList(prm: Param): boolean {
    return prm.sub === "@" || prm.sub === "*" || (prm.special && (prm.name === "@" || prm.name === "*"));
  }
  /** A `string[]` expression for the param's values. */
  private listExpr(prm: Param): string {
    return prm.special ? "sh.positional" : `sh.arrayValues(${JSON.stringify(prm.name)})`;
  }
  /** Quote-aware glob pattern from the operand's raw text (bash escapes quoted
   *  metacharacters); resolved at runtime since it depends on the quoting. */
  private patArg(prm: Param): string {
    // A pattern with no quotes, backslash escapes, or `$`/backtick expansions is
    // already its own glob (patExpand would return it unchanged), so emit it as
    // a literal and skip the runtime pattern walk.
    if (!/[\\'"$`]/.test(prm.arg)) return JSON.stringify(prm.arg);
    return `await sh.patExpand(${JSON.stringify(prm.arg)})`;
  }
  /** A `#`/`%`/`/` string op applied to `subj`, given pattern/replacement
   *  expressions (hoisted by the caller so a list expands them once). */
  private strOpExpr(prm: Param, subj: string, pat: string, repl: string): string {
    switch (prm.op) {
      case "#": return `sh.trimPrefix(${subj}, ${pat}, false)`;
      case "##": return `sh.trimPrefix(${subj}, ${pat}, true)`;
      case "%": return `sh.trimSuffix(${subj}, ${pat}, false)`;
      case "%%": return `sh.trimSuffix(${subj}, ${pat}, true)`;
      case "/": return `sh.replaceGlob(${subj}, ${pat}, ${repl}, false, "")`;
      case "//": return `sh.replaceGlob(${subj}, ${pat}, ${repl}, true, "")`;
      case "/#": return `sh.replaceGlob(${subj}, ${pat}, ${repl}, false, "#")`;
      case "/%": return `sh.replaceGlob(${subj}, ${pat}, ${repl}, false, "%")`;
      default: return subj;
    }
  }

  private paramExpr(prm: Param, quoted = false): string {
    const J = JSON.stringify;
    // `[*]`/`prefix*` join on IFS[0] (like $*); `[@]`/`prefix@` join on a space.
    if (prm.indices) return `sh.arrayIndices(${J(prm.name)}).join(${prm.sub === "*" ? "sh.starSep()" : '" "'})`;
    if (prm.names) return `sh.matchNames(${J(prm.name)}).join(${prm.names === "*" ? "sh.starSep()" : '" "'})`;
    if (prm.indirect) {
      return `await sh.indirectExpand(${J(prm.name)}, ${prm.special}, ${J(prm.op)}, ${J(prm.arg)}, ${J(prm.arg2)}, ${prm.length})`;
    }
    if (this.isSlice(prm)) return `(${this.sliceExpr(prm)}).join(" ")`;
    // ${var@a}: the variable's attribute letters (uses metadata, not the value).
    if (prm.op === "@a") return `sh.attrOf(${J(prm.name)})`;
    // Value-using operators (substring, trim, replace, case, transform, length)
    // must honor `set -u` on an unset var, unlike the alternation operators.
    const valueUsing = !this.isList(prm) &&
      (prm.length || prm.op === ":" || prm.op.startsWith("@") || isCaseOp(prm.op) || STR_OPS.has(prm.op));
    const base = valueUsing
      ? `(sh.assertSet(${J(prm.name)}, ${prm.special}), ${this.valStr(prm)})`
      : this.valStr(prm);
    if (prm.op.startsWith("@")) {
      if (this.isList(prm)) {
        return `${this.listExpr(prm)}.map((x) => sh.transform(${J(prm.op)}, x)).join(" ")`;
      }
      // A plain scalar goes through transformScalar (unset → no field / nounset
      // error); special params and elements keep the value-based path.
      if (!prm.special && prm.sub === "") return `sh.transformScalar(${J(prm.op)}, ${J(prm.name)})`;
      return `sh.transform(${J(prm.op)}, String(${base}))`;
    }
    if (isCaseOp(prm.op)) {
      if (this.isList(prm)) {
        return `await (async () => { const p = ${this.patArg(prm)}; return ${this.listExpr(prm)}.map((x) => sh.changeCase(x, ${J(prm.op)}, p)).join(" "); })()`;
      }
      return `sh.changeCase(String(${base}), ${J(prm.op)}, ${this.patArg(prm)})`;
    }
    // ${arr[@]#pat} / %pat / /pat/repl — apply the string op to each element.
    if (this.isList(prm) && STR_OPS.has(prm.op)) {
      const repl = this.templateOf(parseWord(prm.arg2).parts);
      return `await (async () => { const p = ${this.patArg(prm)}; const r = ${repl}; return ${this.listExpr(prm)}.map((x) => ${this.strOpExpr(prm, "x", "p", "r")}).join(" "); })()`;
    }
    // A default value inside `"…"` follows double-quote backslash rules.
    const arg = (): string => this.templateOf((quoted ? parseDquote(prm.arg) : parseWord(prm.arg)).parts);
    const arg2 = (): string => this.templateOf(parseWord(prm.arg2).parts);
    if (prm.length) {
      if (prm.name === "@" || prm.name === "*" || prm.name === "#") return "String(sh.positional.length)";
      if (prm.sub === "@" || prm.sub === "*") return `String(sh.arrayLen(${J(prm.name)}))`;
      return `String(sh.clen(String(${base})))`;
    }
    switch (prm.op) {
      case "": return prm.special || prm.sub !== "" ? base : `sh.ref(${J(prm.name)})`;
      case ":-": return `(String(${base}) || ${arg()})`;
      case "-": return `(sh.has(${J(prm.name)}) ? ${base} : ${arg()})`;
      case ":+": return `(String(${base}) ? ${arg()} : "")`;
      case "+": return `(sh.has(${J(prm.name)}) ? ${arg()} : "")`;
      case ":?": return `(String(${base}) || sh.paramError(${J(prm.name)}, ${arg()}))`;
      case "?": return `(sh.has(${J(prm.name)}) ? ${base} : sh.paramError(${J(prm.name)}, ${arg()}))`;
      case ":=": return `(String(${base}) || (sh.env.${prm.name} = ${arg()}))`;
      case "=": return `(sh.has(${J(prm.name)}) ? ${base} : (sh.env.${prm.name} = ${arg()}))`;
      case "#": case "##": case "%": case "%%":
      case "/": case "//": case "/#": case "/%":
        return this.strOpExpr(prm, `String(${base})`, this.patArg(prm), arg2());
      case ":": {
        // Compile static offset/length arithmetic; fall back if either needs
        // runtime `$`-expansion.
        const offJS = arithToJS(prm.arg, this.hoist);
        const lenJS = prm.arg2 === "" ? "null" : arithToJS(prm.arg2, this.hoist);
        if (offJS !== null && lenJS !== null) return `sh.substrN(String(${base}), ${offJS}, ${lenJS})`;
        return `await sh.substr(String(${base}), ${J(prm.arg)}, ${J(prm.arg2)})`;
      }
      default: throw new Error(`parameter operator not supported: ${prm.op}`);
    }
  }

  private valueExpr(p: Exclude<WordPart, { k: "lit" }>): string {
    switch (p.k) {
      case "param":
        return this.paramExpr(p.p, p.quoted);
      case "arith": {
        const js = arithToJS(p.expr, this.hoist);
        return js !== null ? `String(${js})` : `await sh.arithStr(${JSON.stringify(p.expr)})`;
      }
      case "cmdsub": {
        const sub = parse(p.src);
        const body = sub === null ? "" : this.command(sub, 0);
        return `await sh.sub(async (sh) => {\n${body}\n})`;
      }
      case "procsub": {
        const sub = parse(p.src);
        const body = sub === null ? "" : this.command(sub, 0);
        return `await sh.procSubFn(${JSON.stringify(p.dir)}, async (sh) => {\n${body}\n})`;
      }
    }
  }

  private templateOf(parts: WordPart[]): string {
    if (parts.length === 0) return '""';
    if (parts.length === 1 && parts[0]!.k === "lit") return JSON.stringify(parts[0]!.s);
    let s = "`";
    for (const p of parts) {
      s += p.k === "lit" ? escTemplate(p.s) : "${" + this.valueExpr(p) + "}";
    }
    return s + "`";
  }

  private fieldArg(p: WordPart): string {
    if (p.k === "lit") return JSON.stringify(p.s);
    const v = this.valueExpr(p);
    // A process-sub path is a single token: never split or glob it.
    if (p.k === "procsub" || p.quoted) return "`${" + v + "}`";
    return `sh.S(${v})`;
  }

  private word(text: string): WordCode {
    const pw = parseWord(text);

    // "$@"/$@ and "${arr[@]}"/${arr[@]}/${!arr[@]} each expand to separate
    // fields. ($* / ${arr[*]} are scalar joins and flow through the paths below.)
    const spreadCode = (p: WordPart): string | null => {
      if (p.k !== "param" || p.p.length) return null;
      // "${arr[@]:i:n}" / "${@:i:n}" — sliced @ keeps each element as a field.
      if (this.isSlice(p.p) && (p.p.sub === "@" || (p.p.special && p.p.name === "@"))) {
        return this.sliceExpr(p.p);
      }
      // "${arr[@]@op}" / "${@@op}" — transform each element, one field each.
      if (p.p.op.startsWith("@") && (p.p.sub === "@" || (p.p.special && p.p.name === "@"))) {
        return `${this.listExpr(p.p)}.map((x) => sh.transform(${JSON.stringify(p.p.op)}, x))`;
      }
      // "${arr[@]#pat}" etc. — string op on each element, one field each.
      if (STR_OPS.has(p.p.op) && (p.p.sub === "@" || (p.p.special && p.p.name === "@"))) {
        const repl = this.templateOf(parseWord(p.p.arg2).parts);
        return `(await (async () => { const p = ${this.patArg(p.p)}; const r = ${repl}; return ${this.listExpr(p.p)}.map((x) => ${this.strOpExpr(p.p, "x", "p", "r")}); })())`;
      }
      if (p.p.names === "@") return `sh.matchNames(${JSON.stringify(p.p.name)})`;
      // "${arr[@]^^}" etc. — case-modify each element, one field each.
      if (isCaseOp(p.p.op) && (p.p.sub === "@" || (p.p.special && p.p.name === "@"))) {
        return `(await (async () => { const p = ${this.patArg(p.p)}; return ${this.listExpr(p.p)}.map((x) => sh.changeCase(x, ${JSON.stringify(p.p.op)}, p)); })())`;
      }
      // "${arr[@]-word}" / "+word" / "?" — set array yields its elements.
      if (ALT_OPS.has(p.p.op) && (p.p.sub === "@" || (p.p.special && p.p.name === "@"))) {
        return `(await sh.altList(${JSON.stringify(p.p.name)}, ${p.p.special}, ${JSON.stringify(p.p.op)}, ${JSON.stringify(p.p.arg)}, ${p.quoted}))`;
      }
      if (p.p.op !== "") return null;
      if (p.p.special && p.p.name === "@") return "sh.positional";
      if (p.p.sub === "@") {
        return p.p.indices
          ? `sh.arrayIndices(${JSON.stringify(p.p.name)}).map(String)`
          : `sh.arrayValues(${JSON.stringify(p.p.name)})`;
      }
      return null;
    };
    if (pw.parts.length === 1) {
      const c = spreadCode(pw.parts[0]!);
      if (c !== null) return { spread: true, code: `...${c}` };
    }
    // Mixed with other text: `@`/`[@]` flows through as a scalar join (valStr),
    // matching how the interpreter and `echo` render it.

    const needsSplit = pw.parts.some((p) => p.k !== "lit" && p.k !== "procsub" && !p.quoted);
    const litMeta = pw.parts.some((p) => p.k === "lit" && /[*?[]/.test(p.s));
    // An unquoted word may glob (any resulting metachar is active).
    const globbable = !pw.hasQuote && (needsSplit || litMeta);

    if (!needsSplit && !globbable) return { spread: false, code: this.templateOf(pw.parts) };
    const fieldsExpr = `sh.fields(${pw.parts.map((p) => this.fieldArg(p)).join(", ")})`;
    return { spread: true, code: globbable ? `...sh.glob(${fieldsExpr})` : `...${fieldsExpr}` };
  }

  /* ---------------- commands ---------------- */

  /** A boolean test of `subjectExpr` against a glob pattern word. A static
   *  pattern (no expansions) compiles to an inline regex — quote-aware, so a
   *  quoted `*` matches literally — with a runtime fallback for nocasematch;
   *  extglob and dynamic patterns defer to sh.matchGlob (quote-aware). */
  private matchExpr(subjectExpr: string, patText: string, forceExtglob = false): string {
    const pw = parseWord(patText);
    const dynamic = pw.parts.some((p) => p.k !== "lit");
    const egArg = forceExtglob ? ", true" : "";
    if (!dynamic) {
      const pat = staticGlobPattern(patText);
      // `[[ ]]` always recognises extended patterns, so a static extglob pattern
      // can be inlined there; under `case` it depends on the runtime option.
      if (forceExtglob || !hasExtglob(pat)) {
        const src = globToRegExpSource(pat, forceExtglob).replace(/\//g, "\\/");
        return `(sh.shopts.nocasematch ? await sh.matchGlob(${subjectExpr}, ${JSON.stringify(patText)}${egArg}) : /${src}/s.test(${subjectExpr}))`;
      }
    }
    return `await sh.matchGlob(${subjectExpr}, ${JSON.stringify(patText)}${egArg})`;
  }

  private cond(e: CondExpr): string {
    switch (e.k) {
      case "and": return `(${this.cond(e.l)} && ${this.cond(e.r)})`;
      case "or": return `(${this.cond(e.l)} || ${this.cond(e.r)})`;
      case "not": return `(!${this.cond(e.e)})`;
      case "word": return `(${this.templateOf(parseWord(e.w.text).parts)} !== "")`;
      case "unary":
        return `sh.condUnary(${JSON.stringify(e.op)}, ${this.templateOf(parseWord(e.arg.text).parts)})`;
      case "binary": {
        const l = this.templateOf(parseWord(e.l.text).parts);
        if (e.op === "==" || e.op === "=") return this.matchExpr(l, e.r.text, true);
        if (e.op === "!=") return `(!${this.matchExpr(l, e.r.text, true)})`;
        // `=~` keeps its RHS raw so condMatch applies regex-literal quoting and
        // sets BASH_REMATCH.
        if (e.op === "=~") return `(await sh.condMatch(${l}, ${JSON.stringify(e.r.text)}))`;
        const r = this.templateOf(parseWord(e.r.text).parts);
        return `sh.condBinary(${l}, ${JSON.stringify(e.op)}, ${r})`;
      }
    }
  }

  /** Whether this command node may raise a fatal arithmetic error (div by zero,
   *  a bad constant/base) while expanding its own words — the emitter then wraps
   *  it in a per-command guard so the error aborts just this command (status 1)
   *  and the program continues, exactly like bash and the interpreter. Only leaf
   *  nodes are inspected: structural nodes let their children guard themselves,
   *  and `$( )` / `<( )` are nested commands that guard themselves too. */
  private throwsArith(cmd: Command): boolean {
    switch (cmd.type) {
      case "arith": case "arith_for": return true;
      case "cond": return this.condThrowsArith(cmd.expr);
      case "array_assign": return cmd.elems.some((w) => this.wordThrowsArith(w.text));
      case "simple": {
        for (const w of cmd.words) if (this.wordThrowsArith(w.text)) return true;
        if (cmd.arrayArgs !== undefined) {
          for (const aa of cmd.arrayArgs) {
            for (const w of aa.elems) if (this.wordThrowsArith(w.text)) return true;
          }
        }
        return false;
      }
      default: return false;
    }
  }

  private wordThrowsArith(text: string): boolean {
    for (const p of parseWord(text).parts) {
      if (p.k === "arith") return true; // $(( )) / $[ ]
      if (p.k === "param") {
        if (p.p.op === ":") return true; // ${x:off:len} — arithmetic offset/length
        if (p.p.sub !== "" && p.p.sub !== "@" && p.p.sub !== "*") return true; // array subscript
      }
    }
    return false;
  }

  private condThrowsArith(e: CondExpr): boolean {
    switch (e.k) {
      case "and": case "or": return this.condThrowsArith(e.l) || this.condThrowsArith(e.r);
      case "not": return this.condThrowsArith(e.e);
      case "binary": return ARITH_COND_OPS.has(e.op);
      default: return false;
    }
  }

  /** Wrap a leaf command's code so a fatal arithmetic error aborts just it. The
   *  core keeps its own indentation (re-indenting would corrupt the literal
   *  newlines inside a multi-line heredoc template). */
  private arithGuard(core: string, ind: number): string {
    const i = pad(ind);
    return `${i}try {\n${core}\n${i}} catch (__e) {\n${pad(ind + 1)}sh.arithAbort(__e);\n${i}}`;
  }

  command(cmd: Command, ind: number): string {
    // $LINENO: mark this command's source line. The marker is a comment that
    // emit() scans into a line map and then strips (same line, so line numbers
    // survive), leaving clean code — $LINENO is resolved lazily from the map.
    const lnMark = cmd.line !== undefined ? `/*@${cmd.line}@*/` : "";
    // DEBUG trap: fire before each simple/leaf command (guarded at runtime on
    // whether a DEBUG trap is actually set). Only emitted when the program uses
    // set/trap/eval/source, so trap-free code pays nothing.
    const dbg =
      this.guards && cmd.line !== undefined &&
      (cmd.type === "simple" || cmd.type === "arith" || cmd.type === "cond" ||
        cmd.type === "array_assign" || cmd.type === "case")
        ? `${pad(ind)}await sh.debugTrap(${cmd.line});\n`
        : "";
    const reds = cmd.redirects;
    let core: string;
    if (reds !== undefined && reds.length > 0) {
      const i = pad(ind);
      const rd = reds
        .map((r) => {
          const parts =
            r.op === "<<" || r.op === "<<-"
              ? parseHeredoc(r.target.text, r.expand !== false).parts
              : parseWord(r.target.text).parts;
          return `{ op: ${JSON.stringify(r.op)}, fd: ${r.fd}, target: ${this.templateOf(parts)} }`;
        })
        .join(", ");
      core = `${i}await sh.withRedirects([${rd}], async () => {\n${this.base(cmd, ind + 1)}\n${i}});`;
    } else {
      core = this.base(cmd, ind);
    }
    // A fatal arithmetic error in this command's own expansion (or a redirect
    // target) aborts just this command, like bash — wrap the leaf in a guard.
    if (this.throwsArith(cmd) ||
        (reds !== undefined && reds.some((r) => this.wordThrowsArith(r.target.text)))) {
      core = this.arithGuard(core, ind);
    }
    if (cmd.flags !== undefined && (cmd.flags & CMD_INVERT_RETURN) !== 0) {
      const i = pad(ind);
      if (this.guards) {
        return lnMark + dbg + `${i}{\n${pad(ind + 1)}using _ = sh.suppress();\n${bump(core)}\n${i}}\n${i}sh.invert();`;
      }
      return lnMark + dbg + core + "\n" + `${i}sh.invert();`;
    }
    return lnMark + dbg + core;
  }

  /** Emit a statement for an assignment word (name=, name+=, name[i]=, …). */
  private assignStmt(text: string, ind: number): string {
    const m = ASSIGN.exec(text)!;
    const name = m[1]!;
    const hasSub = m[2] !== undefined;
    const append = m[4] === "+";
    const parts = parseWord(m[5]!, true).parts;
    const rhs = this.templateOf(parts);
    const i = pad(ind);
    const J = JSON.stringify;
    // `name=$(( expr ))`: assign the BigInt directly (keeps the arith cache warm
    // and skips the stringify → Proxy-set → re-parse round-trip in hot loops).
    if (!hasSub && !append && parts.length === 1 && parts[0]!.k === "arith") {
      const js = arithToJS(parts[0]!.expr, this.hoist);
      if (js !== null) {
        const b = this.hoist?.get(name);
        return b !== undefined ? `${i}sh.bxset(${b}, ${js});` : `${i}sh.aset(${J(name)}, ${js});`;
      }
    }
    if (hasSub) {
      const sub = J(m[3] ?? "");
      if (append) {
        return `${i}await sh.elemSet(${J(name)}, ${sub}, ((await sh.elemGet(${J(name)}, ${sub})) ?? "") + ${rhs});`;
      }
      return `${i}await sh.elemSet(${J(name)}, ${sub}, ${rhs});`;
    }
    if (append) return `${i}sh.appendVar(${J(name)}, ${rhs});`;
    return `${i}sh.env.${name} = ${rhs};`;
  }

  /** Element fragments for a compound array assignment: a plain word is
   *  brace-expanded and split/globbed, but a `[sub]=value` element is an
   *  assignment word emitted as a single no-split/no-glob scalar template. */
  private arrayElemFrags(elems: readonly Word[], assoc: boolean): string[] {
    const frags: string[] = [];
    for (const w of elems) {
      if (assoc && ELEM_ASSIGN.test(w.text)) frags.push(this.templateOf(parseWord(w.text).parts));
      else for (const t of braceExpand(w.text)) frags.push(this.word(t).code);
    }
    return frags;
  }

  private simpleCore(cmd: SimpleCommand, ind: number): string {
    const words = cmd.words;
    const i = pad(ind);
    const assignWords: string[] = [];
    let k = 0;
    for (; k < words.length; k++) {
      if (ASSIGN.test(words[k]!.text)) assignWords.push(words[k]!.text);
      else break;
    }
    const rest = words.slice(k);

    if (rest.length === 0) {
      // A pure assignment's status is 0, unless a RHS command sub ran (its
      // status) or a readonly target rejected it; $? stays intact for the RHS.
      const i = pad(ind);
      return `${i}sh.beginAssign();\n` +
        assignWords.map((w) => this.assignStmt(w, ind)).join("\n") +
        `\n${i}sh.endAssign();` +
        // A failing pure assignment (readonly target, or a failed RHS command
        // sub) fires the ERR trap and errexit like any other command.
        (this.guards ? `\n${i}await sh.afterCommand();` : "");
    }

    // `declare -a arr=(...)` / `local m=(...)` array-literal arguments.
    let arrayStmts = "";
    if (cmd.arrayArgs !== undefined && cmd.arrayArgs.length > 0) {
      const isLocal = words[0]!.text === "local";
      // `-A` marks an associative array, even bundled in a cluster (`declare -Ar`).
      const isAssoc = words.some((w) => (w.text[0] === "-" || w.text[0] === "+") && w.text.slice(1).includes("A"));
      // Attributes from the flags (declare -ai arr=(...)) apply to each array.
      const attrs: Record<string, boolean> = {};
      let exported = false;
      for (const w of words.slice(1)) {
        const t = w.text;
        if (t.length > 1 && (t[0] === "-" || t[0] === "+")) {
          const on = t[0] === "-";
          for (const ch of t.slice(1)) {
            if (ch === "i") attrs["integer"] = on;
            else if (ch === "l") attrs["lower"] = on;
            else if (ch === "u") attrs["upper"] = on;
            else if (ch === "r") attrs["readonly"] = attrs["readonly"] || on;
            else if (ch === "x") exported = exported || on;
          }
        }
      }
      for (const aa of cmd.arrayArgs) {
        const nm = JSON.stringify(aa.name);
        if (isLocal) arrayStmts += `${i}sh.local(${nm});\n`;
        if (isAssoc) arrayStmts += `${i}sh.declareAssoc(${nm});\n`;
        const frags = this.arrayElemFrags(aa.elems, isAssoc);
        const fn = aa.append ? "appendArrayFields" : "setArrayFields";
        arrayStmts += `${i}sh.${fn}(${nm}, [${frags.join(", ")}]);\n`;
        if (Object.keys(attrs).length > 0) arrayStmts += `${i}sh.setAttrs(${nm}, ${JSON.stringify(attrs)});\n`;
        if (exported) arrayStmts += `${i}sh.exportVar(${nm});\n`;
      }
    }

    const texts: string[] = [];
    for (const w of rest) for (const t of braceExpand(w.text)) texts.push(t);
    const nameText = texts[0]!;
    // For assignment builtins, a `name=value` operand is an assignment word: its
    // RHS is not field-split or globbed (bash), so emit it as a scalar template.
    const assignBuiltin = ASSIGN_BUILTINS.has(nameText);
    const argFrags = texts.slice(1).map((t) =>
      assignBuiltin && ASSIGN.test(t) ? this.templateOf(parseWord(t).parts) : this.word(t).code);
    const npw = parseWord(nameText);
    const literal =
      npw.parts.length === 1 && npw.parts[0]!.k === "lit" ? npw.parts[0]!.s : null;

    let callInner: string;
    if (literal !== null) {
      const target = ident(literal) ? `sh.commands.${literal}` : `sh.commands[${JSON.stringify(literal)}]`;
      callInner = `${target}(${argFrags.join(", ")})`;
    } else {
      const nameFrag = this.word(nameText).code;
      // markSubs() (via comma) snapshots the sub counter before the args run, so
      // an empty expansion adopts the last command sub's status.
      callInner = `(sh.markSubs(), sh.exec(${[nameFrag, ...argFrags].join(", ")}))`;
    }

    // `declare d=(…)` with no other operands is just the array assignment;
    // don't call the builtin (its bare no-arg form would list everything).
    if (cmd.arrayArgs !== undefined && cmd.arrayArgs.length > 0 && texts.length === 1) {
      return arrayStmts + `${i}sh.status = 0;`;
    }
    if (assignWords.length === 0) return arrayStmts + `${i}await ${callInner};`;
    // Prefix env from plain name=value assignments.
    const env = assignWords
      .map((w) => ASSIGN.exec(w)!)
      .filter((m) => m[2] === undefined && m[4] === undefined)
      .map((m) => `${JSON.stringify(m[1])}: ${this.templateOf(parseWord(m[5]!, true).parts)}`)
      .join(", ");
    // Expand the command words BEFORE applying the temporary env — bash expands
    // args in the current environment, then sets the prefix assignments.
    const argList = literal !== null ? argFrags : [this.word(nameText).code, ...argFrags];
    const mark = literal !== null ? "" : "sh.markSubs(); ";
    const call = literal !== null
      ? `${ident(literal) ? `sh.commands.${literal}` : `sh.commands[${JSON.stringify(literal)}]`}(...__a)`
      : "sh.exec(...__a)";
    return arrayStmts +
      `${i}await (async () => { ${mark}const __a = [${argList.join(", ")}]; ` +
      `return sh.withEnv({ ${env} }, () => ${call}); })();`;
  }

  private functionDef(cmd: FunctionDef, ind: number): string {
    const i = pad(ind);
    const target = ident(cmd.name) ? `sh.commands.${cmd.name}` : `sh.commands[${JSON.stringify(cmd.name)}]`;
    return (
      `${i}${target} = sh.func(async (sh) => {\n` +
      this.command(cmd.body, ind + 1) + "\n" +
      `${i}});`
    );
  }

  /* ---- arith loop Var-box hoisting ---- */

  /** Plan box hoisting for an arith-for loop: the set of scalar variables it is
   *  safe to resolve once (name → JS box var), or null if the loop body could
   *  unset/redeclare a variable or run opaque code. Conservative: anything not
   *  understood bails, falling back to the (already fast) per-access path. */
  private planHoist(cmd: ArithForCommand): Map<string, string> | null {
    const ctx: HoistCtx = { ok: true, targets: new Set(), subscripted: new Set() };
    this.scanArith(cmd.init, ctx);
    this.scanArith(cmd.test, ctx);
    this.scanArith(cmd.step, ctx);
    this.scanBody(cmd.body, ctx);
    if (!ctx.ok) return null;
    const map = new Map<string, string>();
    for (const n of ctx.targets) if (!ctx.subscripted.has(n)) map.set(n, `_hb${this.hoistSeq++}`);
    return map.size > 0 ? map : null;
  }

  private scanArith(text: string, ctx: HoistCtx): void {
    if (text === "" || /[$`]/.test(text)) return; // dynamic: safe, just not hoisted
    let ast: ArithNode;
    try {
      ast = parseArithAst(text);
    } catch {
      return;
    }
    this.walkArith(ast, ctx);
  }

  private walkArith(n: ArithNode, ctx: HoistCtx): void {
    switch (n.t) {
      case "num": return;
      case "var": if (n.index !== undefined) ctx.subscripted.add(n.name); return;
      case "unary": this.walkArith(n.e, ctx); return;
      case "incr":
        if (n.index !== undefined) ctx.subscripted.add(n.name);
        else ctx.targets.add(n.name);
        return;
      case "bin": case "logic": case "comma":
        this.walkArith(n.l, ctx); this.walkArith(n.r, ctx); return;
      case "ternary":
        this.walkArith(n.c, ctx); this.walkArith(n.a, ctx); this.walkArith(n.b, ctx); return;
      case "assign":
        if (n.index !== undefined) ctx.subscripted.add(n.name);
        else ctx.targets.add(n.name);
        this.walkArith(n.e, ctx);
        return;
    }
  }

  /** Verify a loop body is safe for hoisting and collect its arith targets. */
  private scanBody(cmd: Command, ctx: HoistCtx): void {
    if (!ctx.ok) return;
    if (cmd.redirects !== undefined && cmd.redirects.length > 0) { ctx.ok = false; return; }
    switch (cmd.type) {
      case "simple": {
        if (cmd.arrayArgs !== undefined) { ctx.ok = false; return; }
        for (const w of cmd.words) if (OPAQUE.test(w.text)) { ctx.ok = false; return; }
        let sawCmd = false;
        for (const w of cmd.words) {
          const am = sawCmd ? null : ASSIGN.exec(w.text);
          if (am !== null && am[2] === undefined && am[4] === undefined) {
            const parts = parseWord(am[5]!, true).parts;
            if (parts.length === 1 && parts[0]!.k === "arith") ctx.targets.add(am[1]!);
            continue; // a leading scalar assignment
          }
          sawCmd = true;
          if (!SAFE_CMDS.has(w.text)) { ctx.ok = false; return; }
        }
        for (const w of cmd.words) {
          for (const p of parseWord(w.text).parts) if (p.k === "arith") this.scanArith(p.expr, ctx);
        }
        return;
      }
      case "arith": this.scanArith(cmd.expression, ctx); return;
      case "arith_for":
        this.scanArith(cmd.init, ctx); this.scanArith(cmd.test, ctx); this.scanArith(cmd.step, ctx);
        this.scanBody(cmd.body, ctx); return;
      case "for":
        for (const w of cmd.words) if (OPAQUE.test(w.text)) { ctx.ok = false; return; }
        this.scanBody(cmd.body, ctx); return;
      case "while": this.scanBody(cmd.test, ctx); this.scanBody(cmd.body, ctx); return;
      case "if":
        this.scanBody(cmd.test, ctx); this.scanBody(cmd.consequent, ctx);
        if (cmd.alternate !== null) this.scanBody(cmd.alternate, ctx); return;
      case "case":
        if (OPAQUE.test(cmd.word.text)) { ctx.ok = false; return; }
        for (const cl of cmd.clauses) {
          for (const p of cl.patterns) if (OPAQUE.test(p.text)) { ctx.ok = false; return; }
          if (cl.body !== null) this.scanBody(cl.body, ctx);
        }
        return;
      case "connection": this.scanBody(cmd.first, ctx); this.scanBody(cmd.second, ctx); return;
      case "group": this.scanBody(cmd.body, ctx); return;
      // subshell / pipeline / background / function / cond / array_assign / etc.
      default: ctx.ok = false; return;
    }
  }

  private base(cmd: Command, ind: number): string {
    const i = pad(ind);
    switch (cmd.type) {
      case "simple":
        return this.simpleCore(cmd, ind);
      case "function":
        return this.functionDef(cmd, ind);
      case "connection": {
        if (cmd.connector === ";") {
          return this.command(cmd.first, ind) + "\n" + this.command(cmd.second, ind);
        }
        if (cmd.connector === "&&" || cmd.connector === "||") {
          const test = cmd.connector === "&&" ? "=== 0" : "!== 0";
          return (
            this.suppressed(cmd.first, ind) + "\n" +
            `${i}if (sh.status ${test}) {\n` +
            this.command(cmd.second, ind + 1) + "\n" +
            `${i}}`
          );
        }
        throw new Error(`connector \`${cmd.connector}\` not supported yet`);
      }
      case "pipeline": {
        const stages = cmd.stages
          .map((c) => `async (sh) => {\n${this.command(c, ind + 2)}\n${pad(ind + 1)}}`)
          .join(",\n" + pad(ind + 1));
        return `${i}await sh.pipeline([\n${pad(ind + 1)}${stages},\n${i}]);`;
      }
      case "background":
        return (
          `${i}sh.background(async (sh) => {\n` +
          this.command(cmd.command, ind + 1) + "\n" +
          `${i}});`
        );
      case "group":
        return this.command(cmd.body, ind);
      case "subshell":
        return (
          `${i}await sh.runSubshell(async (sh) => {\n` +
          this.command(cmd.body, ind + 1) + "\n" +
          `${i}});` +
          (this.guards ? `\n${i}await sh.afterCommand();` : "")
        );
      case "if": {
        let out =
          this.suppressed(cmd.test, ind) + "\n" +
          `${i}if (sh.status === 0) {\n` +
          this.command(cmd.consequent, ind + 1) + "\n" +
          `${i}}`;
        if (cmd.alternate !== null) {
          out += ` else {\n` + this.command(cmd.alternate, ind + 1) + "\n" + `${i}}`;
        } else {
          // A false `if` with no else has exit status 0, not the test's status.
          out += ` else {\n${pad(ind + 1)}sh.status = 0;\n${i}}`;
        }
        return out;
      }
      case "while": {
        const brk = cmd.until ? "=== 0" : "!== 0";
        const j = pad(ind + 1);
        // `break`/`continue` may appear in the condition itself (`while break`);
        // catch it here so it acts on this loop, not an enclosing one.
        const cond =
          `${j}try {\n` +
          this.suppressed(cmd.test, ind + 2) + "\n" +
          `${pad(ind + 2)}if (sh.status ${brk}) break;\n` +
          `${j}} catch (e) {\n` +
          `${pad(ind + 2)}if (e instanceof LoopSignal) { if (--e.count > 0) throw e; if (e.kind === "break") break; continue; }\n` +
          `${pad(ind + 2)}throw e;\n` +
          `${j}}`;
        return this.loopScope(
          `${i}for (;;) {\n` +
          cond + "\n" +
          this.loopBody(cmd.body, ind + 1) + "\n" +
          `${i}}`,
          ind,
        );
      }
      case "for": {
        const v = `__it${this.forId++}`;
        const listFrags: string[] = [];
        for (const w of cmd.words) for (const t of braceExpand(w.text)) listFrags.push(this.word(t).code);
        const list = `[${listFrags.join(", ")}]`;
        const setName = ident(cmd.name) ? `sh.env.${cmd.name}` : `sh.env[${JSON.stringify(cmd.name)}]`;
        return this.loopScope(
          `${i}for (const ${v} of ${list}) {\n` +
          (this.guards && cmd.line !== undefined ? `${pad(ind + 1)}await sh.debugTrap(${cmd.line});\n` : "") +
          `${pad(ind + 1)}${setName} = ${v};\n` +
          this.loopBody(cmd.body, ind + 1) + "\n" +
          `${i}}`,
          ind,
        );
      }
      case "select": {
        const listFrags: string[] = [];
        for (const w of cmd.words) for (const t of braceExpand(w.text)) listFrags.push(this.word(t).code);
        return (
          `${i}await sh.runSelect(${JSON.stringify(cmd.name)}, [${listFrags.join(", ")}], async (sh) => {\n` +
          this.command(cmd.body, ind + 1) + "\n" +
          `${i}});`
        );
      }
      case "arith_for": {
        // Hoist each safe scalar variable's Var box once (resolve outside the
        // loop, mutate in place) so arith accesses skip the per-iteration scope
        // lookup. planHoist returns null / a partial map when unsafe.
        const savedHoist = this.hoist;
        let prelude = "";
        const plan = this.planHoist(cmd);
        if (plan !== null) {
          const merged = new Map(savedHoist ?? []);
          for (const [n, jv] of plan) {
            const outer = savedHoist?.get(n);
            if (outer !== undefined) { merged.set(n, outer); continue; } // reuse outer box
            merged.set(n, jv);
            prelude += `${i}const ${jv} = sh.abox(${JSON.stringify(n)});\n`;
          }
          this.hoist = merged;
        }
        // C-style header so a `continue` still runs the step then re-tests.
        // Compile each clause to native JS when possible (parsed once), else
        // fall back to the runtime string evaluator for the whole header.
        const ic = cmd.init === "" ? "" : arithToJS(cmd.init, this.hoist);
        const tc = cmd.test === "" ? "true" : arithToJSBool(cmd.test, this.hoist);
        const sc = cmd.step === "" ? "" : arithToJS(cmd.step, this.hoist);
        let header: string;
        if (ic !== null && tc !== null && sc !== null) {
          header = `for (${ic}; ${tc}; ${sc})`;
        } else {
          header =
            `for (await sh.arithRun(${JSON.stringify(cmd.init)}); ` +
            `await sh.arithTest(${JSON.stringify(cmd.test)}); ` +
            `await sh.arithRun(${JSON.stringify(cmd.step)}))`;
        }
        const bodyCode = this.loopBody(cmd.body, ind + 1);
        this.hoist = savedHoist;
        return this.loopScope(
          prelude + `${i}${header} {\n` + bodyCode + "\n" + `${i}}`,
          ind,
        );
      }
      case "arith": {
        const s = `${i}await sh.arithCommand(${JSON.stringify(cmd.expression)});`;
        return this.guards ? s + `\n${i}await sh.afterCommand();` : s;
      }
      case "cond": {
        // condFatal is reset first; the cond expression may set it (an invalid
        // `=~` regex), and condStatus then maps the result to 0/1 or 2.
        const s = `${i}sh.condFatal = false;\n${i}sh.status = sh.condStatus(${this.cond(cmd.expr)});`;
        return this.guards ? s + `\n${i}await sh.afterCommand();` : s;
      }
      case "array_assign": {
        // A standalone `name=( … )` can target a previously `declare -A`'d
        // variable, whose assoc-ness isn't known here; default to indexed
        // (brace-expand) — the interpreter resolves the assoc case at runtime.
        const frags = this.arrayElemFrags(cmd.elems, false);
        const fn = cmd.append ? "appendArrayFields" : "setArrayFields";
        // Status is 0, unless a readonly target rejected the assignment (then 1).
        return `${i}sh.readonlyHit = false; sh.${fn}(${JSON.stringify(cmd.name)}, [${frags.join(", ")}]); sh.status = sh.readonlyHit ? 1 : 0;`;
      }
      case "case": {
        const id = this.caseId++;
        const subj = this.templateOf(parseWord(cmd.word.text).parts);
        const j = pad(ind + 1);
        const head = `${j}const __case${id} = ${subj};\n${j}sh.status = 0;`;
        const condOf = (clause: (typeof cmd.clauses)[number]): string =>
          clause.patterns.map((p) => this.matchExpr(`__case${id}`, p.text)).join(" || ");
        const bodyOf = (clause: (typeof cmd.clauses)[number], d: number): string =>
          clause.body ? this.command(clause.body, d) : `${pad(d)}sh.status = 0;`;

        // Common case (all `;;`): a clean if / else-if chain.
        if (cmd.clauses.every((c) => c.term === "break")) {
          let chain = "";
          cmd.clauses.forEach((clause, ci) => {
            const block = `(${condOf(clause)}) {\n${bodyOf(clause, ind + 2)}\n${j}}`;
            chain += ci === 0 ? `${j}if ${block}` : ` else if ${block}`;
          });
          return `${i}{\n${chain === "" ? head : head + "\n" + chain}\n${i}}`;
        }

        // With `;&` / `;;&`: a labeled block with a fall-through flag.
        const k = pad(ind + 2);
        let out = `${i}{\n${head}\n${j}__case${id}: {\n${k}let __fall${id} = false;\n`;
        for (const clause of cmd.clauses) {
          out += `${k}if (__fall${id} || (${condOf(clause)})) {\n${bodyOf(clause, ind + 3)}\n`;
          if (clause.term === "break") out += `${pad(ind + 3)}break __case${id};\n`;
          else out += `${pad(ind + 3)}__fall${id} = ${clause.term === "fall"};\n`;
          out += `${k}}\n`;
        }
        return out + `${j}}\n${i}}`;
      }
      default: {
        const unhandled: never = cmd;
        throw new Error(`unhandled command type: ${String(unhandled)}`);
      }
    }
  }

  /** Wrap a whole loop so sh.loopDepth tracks nesting (break/continue are a
   *  no-op outside a loop). */
  private loopScope(loopCode: string, ind: number): string {
    const i = pad(ind);
    return `${i}sh.loopDepth++;\n${i}try {\n${bump(loopCode)}\n${i}} finally { sh.loopDepth--; }`;
  }

  /** A loop body wrapped so a runtime break/continue (LoopSignal) becomes a
   *  native break/continue, consuming one level of a break/continue N. */
  private loopBody(body: Command, ind: number): string {
    const i = pad(ind);
    return (
      `${i}try {\n` +
      this.command(body, ind + 1) + "\n" +
      `${i}} catch (e) {\n` +
      `${pad(ind + 1)}if (e instanceof LoopSignal) { if (--e.count > 0) throw e; if (e.kind === "break") break; continue; }\n` +
      `${pad(ind + 1)}throw e;\n` +
      `${i}}`
    );
  }
}

/** Scan the per-command source-line markers (comment markers of the form
 *  slash-star @N@ star-slash) the emitter left on each command into a sparse
 *  [jsLine, shLine] map (an entry only where the source line changes), strip the
 *  markers (same line, so line numbers are preserved), and splice the map literal
 *  in for the `__CURSE_MAP__` placeholder. `$LINENO` reads this map lazily off
 *  the stack — no per-command code is emitted. */
const finalizeLineMap = (module: string): string => {
  const lines = module.split("\n");
  const pairs: Array<[number, number]> = [];
  let last = -1;
  for (let i = 0; i < lines.length; i++) {
    const ms = lines[i]!.match(/\/\*@(\d+)@\*\//g);
    if (ms === null) continue;
    // Take the innermost (last) marker on the line: a delegating command (e.g. a
    // group or connection) shares a line with the leaf it wraps, and the leaf's
    // line is the one $LINENO should report.
    const sh = Number(/\d+/.exec(ms[ms.length - 1]!)![0]);
    if (sh !== last) { pairs.push([i + 1, sh]); last = sh; }
  }
  const lit = "[" + pairs.map(([j, s]) => `[${j},${s}]`).join(",") + "]";
  return module.replace(/\/\*@\d+@\*\//g, "").replace("__CURSE_MAP__", lit);
};

export const emit = (cmd: Command | null, opts: EmitOptions): string => {
  const em = new Emitter();
  if (cmd !== null) em.guards = usesSet(cmd);
  const body = cmd === null ? "" : em.command(cmd, 1) + "\n";
  const rt = JSON.stringify(opts.runtimeSpecifier);
  if (opts.fragment) {
    // A `source`-able fragment: runs against the caller's shell, so `return`
    // returns from the source and `exit` (ExitSignal) propagates to end the
    // whole shell. Shell isn't imported — the caller injects it.
    return finalizeLineMap(
      "// Generated by curse. Do not edit.\n" +
      `import { ReturnSignal, LoopSignal } from ${rt};\n` +
      "export default async (sh) => {\n" +
      "sh.mapLines(import.meta.url, __CURSE_MAP__);\n" +
      "try {\n" +
      body +
      "} catch (e) {\n" +
      "  if (e instanceof ReturnSignal) { sh.status = e.code; return e.code; }\n" +
      "  if (e instanceof LoopSignal) return sh.status;\n" +
      "  throw e;\n" +
      "}\n" +
      "return sh.status;\n" +
      "};\n",
    );
  }
  return finalizeLineMap(
    "// Generated by curse. Do not edit.\n" +
    `import { Shell, ExitSignal, LoopSignal } from ${rt};\n` +
    "\n" +
    "const sh = new Shell();\n" +
    "sh.mapLines(import.meta.url, __CURSE_MAP__);\n" +
    "try {\n" +
    body +
    "} catch (e) {\n" +
    "  if (e instanceof ExitSignal) sh.status = e.code;\n" +
    "  else if (e instanceof LoopSignal) { /* break/continue outside a loop */ }\n" +
    "  else throw e;\n" +
    "} finally {\n" +
    "  await sh.runExitTrap();\n" +
    "}\n" +
    "process.exitCode = sh.status;\n",
  );
};
