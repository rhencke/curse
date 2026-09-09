/* The bash runtime, in TypeScript.
 *
 * Design: lean on JavaScript's own dynamism to model bash's.
 *  - Variables live as `Var` boxes on a prototype-linked scope chain, exposed
 *    through the `sh.env` Proxy. `sh.env.x = "v"` is an assignment; dynamic
 *    scoping (functions, `local`) is just `Object.create(callerScope)`.
 *  - Commands are live bindings in the `sh.commands` Proxy: builtins are the
 *    prototype, bash function definitions are own properties that shadow them,
 *    and unknown names fall through to external processes. Defining `echo()`
 *    is literally assigning a function onto the registry.
 *
 * The AOT-generated `.mts` and the interpreter (`execute`, for the JIT/eval
 * path) both drive this same surface, so their behaviour matches. */

import type {
  ArithForCommand, ArrayArg, CaseCommand, Command, CondCommand, CondExpr, ForCommand,
  FunctionDef, IfCommand, Redirect, SelectCommand, SimpleCommand, WhileCommand, Word,
} from "../ast/nodes.mts";
import { CMD_INVERT_RETURN } from "../ast/nodes.mts";
import { parse } from "../parser/parser.mts";
import { parseHeredoc } from "../parser/word.mts";
import { evalParam, expandArith, expandArrayElems, expandAssign, expandNoSplit, expandParsed, expandWord, expandWords, expandWordsAssign, splitTaggedFields } from "./expand.mts";
import { ArithError, arithWrap, evalArith } from "./arith.mts";
import { globExpand, globIgnored, globMatch, hasExtglob, hasGlobMeta } from "./glob.mts";
import {
  changeCase as pChangeCase, replaceGlob as pReplaceGlob, sliceArr as pSliceArr,
  substr as pSubstr, transform as pTransform, trimPrefix as pTrimPrefix, trimSuffix as pTrimSuffix,
} from "./param.mts";
import { builtins } from "./builtins.mts";
import { ExitSignal, LoopSignal, ReturnSignal, Var } from "./types.mts";
import type { IO } from "./types.mts";
import { spawn } from "node:child_process";
import {
  accessSync, closeSync, constants, lstatSync, openSync, readFileSync, statSync, unlinkSync,
  writeFileSync, writeSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

export type { IO } from "./types.mts";
export { ExitSignal, LoopSignal, ReturnSignal, Var } from "./types.mts";

const defaultIO = (): IO => ({
  out: (s) => void process.stdout.write(s),
  err: (s) => void process.stderr.write(s),
});

/** A value marked as subject to field splitting, for `sh.fields(...)`. */
interface SplitMark {
  v: string;
}

/** A redirection with its target already expanded to a string. */
interface RedirIO {
  op: string;
  fd: number;
  target: string;
}

/** An assignment word: name(1), optional `[sub(3)]`(2), optional `+`(4), value(5). */
const ASSIGN = /^([A-Za-z_][A-Za-z0-9_]*)(\[([^\]]*)\])?(\+)?=([\s\S]*)$/;

/** Builtins whose `name=value` operands are assignment words (RHS not split/globbed). */
const ASSIGN_BUILTINS = new Set(["declare", "typeset", "local", "export", "readonly"]);

const errMsg = (e: unknown): string => (e instanceof Error ? e.message : String(e));

/** Count Unicode code points (not UTF-16 code units) in a JS string — a low
 *  surrogate is counted with its high half, so an astral char counts once. */
const cpLen = (s: string): number => {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xdc00 && c <= 0xdfff) continue;
    n++;
  }
  return n;
};

/** A variable's attribute letters in bash's order (a A i l n r t u x), as used
 *  by `declare -p` and the `${var@a}` transform. */
const attrLetters = (v: Var): string => {
  let f = "";
  if (v.arr !== null) f += "a";
  if (v.assoc !== null) f += "A";
  if (v.integer) f += "i";
  if (v.lower) f += "l";
  if (v.ref) f += "n";
  if (v.readonly) f += "r";
  if (v.upper) f += "u";
  if (v.exported) f += "x";
  return f;
};

/** Temp files backing process substitutions, unlinked when the process exits. */
let procSubSeq = 0;
const procSubFiles: string[] = [];
process.on("exit", () => {
  for (const f of procSubFiles) {
    try {
      unlinkSync(f);
    } catch {
      /* already gone */
    }
  }
});

/** Quote a value the way `declare -p` does: double quotes with `"$`\` and
 *  backslash escaped, or a `$'…'` form when it holds control characters. */
const declareQuote = (v: string): string => {
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
  return '"' + v.replace(/[\\"$`]/g, "\\$&") + '"';
};

/** Quote a value the way `set` (no args) prints it: bare when safe, `$'…'` for
 *  control characters, otherwise single-quoted. */
const setQuote = (v: string): string => {
  if (v === "") return "";
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
  if (/^[A-Za-z0-9_.,:/=@%+-]+$/.test(v)) return v;
  return "'" + v.replace(/'/g, "'\\''") + "'";
};

/** Index just past the `$…` expansion at `i` (raw[i] === "$"), else `i`. */
const expansionEnd = (raw: string, i: number): number => {
  const n = raw[i + 1];
  if (n === undefined) return i;
  if (n === "(" || n === "{") {
    const open = n;
    const close = open === "(" ? ")" : "}";
    let depth = 0;
    let j = i + 1;
    for (; j < raw.length; j++) {
      if (raw[j] === open) depth++;
      else if (raw[j] === close && --depth === 0) return j + 1;
    }
    return raw.length; // unbalanced — consume the rest
  }
  if (/[A-Za-z_]/.test(n)) {
    let j = i + 2;
    while (j < raw.length && /[A-Za-z0-9_]/.test(raw[j]!)) j++;
    return j;
  }
  if ("?@*#$!0123456789".includes(n)) return i + 2;
  return i;
};

/** Run a subshell body, turning `exit` into that subshell's status. */
const runBody = async (sub: Shell, fn: (sh: Shell) => Promise<unknown>): Promise<number> => {
  try {
    await fn(sub);
  } catch (e) {
    if (e instanceof ExitSignal) sub.status = e.code;
    else if (e instanceof LoopSignal) { /* break/continue does not cross a subshell */ }
    else throw e;
  }
  return sub.status;
};

/** A lexical scope: a Map of name→Var with a parent link (dynamic scoping is a
 *  parent chain). A Map keeps variable access monomorphic and fast, unlike a
 *  prototype-object chain (which forces a megamorphic keyed load per access). */
class Scope {
  readonly vars = new Map<string, Var>();
  parent: Scope | null;
  constructor(parent: Scope | null = null) {
    this.parent = parent;
  }
}
type BashFunc = { __bashFunc: (sh: Shell) => Promise<void> };

export class Shell {
  io: IO;
  status = 0;
  /** Set when the `exit` builtin ran (so an interactive loop knows to stop). */
  exited = false;
  name = "curse";
  cwd = process.cwd();
  /** Directory stack for pushd/popd/dirs; index 0 mirrors the current dir. */
  dirStack: string[] = [];
  positional: string[] = [];
  /** Redirected stdin (file contents / here-string), or null to inherit. Read by
   *  the `read` builtin and passed to external stdin. Held in a small box shared
   *  by reference with subshells and command substitutions, so a read that
   *  consumes input in a `( … )` or `$( … )` advances the same position the
   *  parent sees next — matching bash's shared stdin fd. A pipeline stage instead
   *  gets its own box (its slice of the upstream output). */
  private stdinBuf: { data: string | null } = { data: null };
  get stdinData(): string | null { return this.stdinBuf.data; }
  set stdinData(v: string | null) { this.stdinBuf.data = v; }

  /** getopts scan state: char index within the current word (0 = the `-`),
   *  and the OPTIND value we last wrote (to detect an external reset). */
  optsPos = 1;
  optsInd = 1;
  /** Set when an assignment/unset was refused because the target is readonly;
   *  the assignment/unset command turns this into exit status 1. */
  readonlyHit = false;
  /** Set when a `[[ ]]` evaluation hit a fatal error (e.g. an invalid `=~`
   *  regex); the conditional's status becomes 2 rather than the match result. */
  condFatal = false;

  /** trap handlers by normalized signal name (EXIT, INT, …). */
  traps: Record<string, string> = Object.create(null) as Record<string, string>;
  private ranExitTrap = false;
  private inErrTrap = false;

  /** `shopt` toggles (all off by default, as in a non-interactive shell). */
  shopts: Record<string, boolean> = {
    nullglob: false, dotglob: false, nocasematch: false, failglob: false,
    globstar: false, extglob: false, nocaseglob: false,
  };

  /** Background jobs and `$!`. */
  lastBgPid = 0;
  private jobs: Array<{ pid: number; promise: Promise<number> }> = [];
  private nextPid = 10000;

  /** `set` options. */
  opts = { errexit: false, nounset: false, xtrace: false, pipefail: false, noclobber: false, noglob: false };

  /** Exit status when a fatal expansion error aborts the shell (an unbound
   *  variable under `set -u`, or `${x:?}` / `${x?}`). bash uses 1 when running a
   *  script file but 127 for a `-c` command string; the CLI sets this to match. */
  fatalStatus = 1;

  /** Cached string-locale regime: true for a UTF-8 locale (character-oriented
   *  ${#}/slice/case), false for C/POSIX (byte-oriented). Like bash, this is a
   *  runtime lens read from LC_ALL/LC_CTYPE/LANG; recomputed lazily and cleared
   *  when one of those is assigned or unset. */
  private _localeUtf8: boolean | null = null;
  localeUtf8(): boolean {
    if (this._localeUtf8 === null) {
      const pick = (n: string): string => { const v = this.getVar(n); return v !== undefined && v !== "" ? v : ""; };
      const l = pick("LC_ALL") || pick("LC_CTYPE") || pick("LANG");
      this._localeUtf8 = /\.utf-?8$/i.test(l);
    }
    return this._localeUtf8;
  }
  /** `${#s}` length: code points in a UTF-8 locale, bytes in a C/POSIX one. */
  clen(s: string): number {
    return this.localeUtf8() ? cpLen(s) : Buffer.byteLength(s, "utf8");
  }

  /** State of a `set -o` option by long name, for `set -o`, `$SHELLOPTS`, and
   *  `test -o name`. Toggleable options reflect `opts`; the rest are fixed at
   *  their non-interactive defaults. Unknown names return undefined. */
  setOption(name: string): boolean | undefined {
    switch (name) {
      case "errexit": return this.opts.errexit;
      case "nounset": return this.opts.nounset;
      case "xtrace": return this.opts.xtrace;
      case "pipefail": return this.opts.pipefail;
      case "noclobber": return this.opts.noclobber;
      case "noglob": return this.opts.noglob;
      case "braceexpand": case "hashall": return true;
      case "emacs": case "errtrace": case "functrace": case "histexpand":
      case "history": case "ignoreeof": case "keyword": case "monitor":
      case "noexec": case "notify": case "onecmd": case "physical":
      case "posix": case "verbose": case "vi": return false;
      default: return undefined;
    }
  }
  /** Depth of errexit-suppressed contexts (conditions, `!`, `&&`/`||` non-final). */
  condDepth = 0;
  /** Enclosing loop nesting in the current function scope (0 outside any loop).
   *  break/continue are a no-op unless this is positive; reset across functions. */
  loopDepth = 0;
  /** Counts command substitutions run, so an empty command can detect whether
   *  any ran during its expansion and adopt the last sub's status (bash). */
  subCount = 0;
  private subMarkCount = 0;
  /** Snapshot subCount before a (possibly empty) dynamic command's args are
   *  expanded, so `sh.exec` can tell whether a sub ran (see `exec`). */
  markSubs(): void {
    this.subMarkCount = this.subCount;
  }
  /** A pure assignment command (`x=1 y=$(cmd)`): start it. `$?` is left intact
   *  so a RHS `$?` sees the previous command's status. */
  beginAssign(): void {
    this.subMarkCount = this.subCount;
    this.readonlyHit = false;
  }
  /** Finish a pure assignment: its status is 0, unless a RHS command sub ran
   *  (then that sub's status) or a readonly target rejected it. */
  endAssign(): void {
    if (this.subCount === this.subMarkCount) this.status = 0;
    if (this.readonlyHit) this.status = 1;
  }

  private globalScope: Scope = new Scope();
  private scope: Scope = this.globalScope;
  /** For `$SECONDS`: shell start time. */
  private startMs = Date.now();
  private functions: Record<string, unknown> = Object.create(builtins) as Record<string, unknown>;

  /** `sh.env.x` reads/writes variables over the dynamic scope chain. */
  readonly env: Record<string, Var>;
  /** `sh.commands.name(...args)` dispatches function → builtin → external. */
  readonly commands: Record<string, (...args: string[]) => Promise<number>>;

  constructor(io?: IO) {
    this.io = io ?? defaultIO();

    this.env = new Proxy(Object.create(null) as Record<string, Var>, {
      get: (_t, p) => (typeof p === "string" ? this.lookup(p) ?? new Var("") : undefined),
      set: (_t, p, v) => {
        if (typeof p === "string") this.assign(p, v);
        return true;
      },
      has: (_t, p) => typeof p === "string" && this.lookup(p) !== undefined,
      deleteProperty: (_t, p) => {
        if (typeof p === "string") this.unsetVar(p);
        return true;
      },
    }) as Record<string, Var>;

    this.commands = new Proxy(Object.create(null) as object, {
      get: (_t, p) =>
        typeof p === "string" ? (...args: string[]) => this.callByName(p, args) : undefined,
      set: (_t, p, v) => {
        if (typeof p === "string") this.functions[p] = v;
        return true;
      },
      has: (_t, p) => typeof p === "string" && p in this.functions,
      deleteProperty: (_t, p) => {
        if (typeof p === "string") delete this.functions[p];
        return true;
      },
    }) as Record<string, (...args: string[]) => Promise<number>>;

    this.initSpecialVars();
  }

  /** Seed bash's static special variables at startup. */
  private initSpecialVars(): void {
    const uid = typeof process.getuid === "function" ? process.getuid() : 0;
    const set = (n: string, v: string, exported = false): void => {
      this.globalScope.vars.set(n, new Var(v, exported));
    };
    set("PWD", this.cwd, true); // bash keeps PWD exported and in sync with cwd
    set("PPID", String(process.ppid));
    set("UID", String(uid));
    set("EUID", String(uid));
    set("OSTYPE", "linux-gnu");
    set("HOSTTYPE", "x86_64");
    set("MACHTYPE", "x86_64-pc-linux-gnu");
    set("OPTIND", "1"); // getopts index starts at 1
  }

  /** Variables whose value is recomputed on each read (`$RANDOM`, `$SECONDS`),
   *  unless the user has assigned one (checked before this by rawLookup). */
  private dynamicSpecial(name: string): string | undefined {
    if (name === "RANDOM") return String(Math.floor(Math.random() * 32768));
    if (name === "SECONDS") return String(Math.floor((Date.now() - this.startMs) / 1000));
    return undefined;
  }

  get pid(): number {
    return process.pid;
  }

  /* ---------------- variables / scope ---------------- */

  private rawLookup(name: string): Var | undefined {
    const v = this.scopeLookup(name);
    if (v !== undefined) return v;
    const dyn = this.dynamicSpecial(name);
    if (dyn !== undefined) return new Var(dyn);
    const e = process.env[name];
    return e === undefined ? undefined : new Var(e, true);
  }
  /** Find a variable's Var box in the scope chain (no env/dynamic fallback), so
   *  callers that mutate the box in place don't get a throwaway env Var. */
  private scopeLookup(name: string): Var | undefined {
    let s: Scope | null = this.scope;
    while (s !== null) {
      const v = s.vars.get(name);
      if (v !== undefined) return v;
      s = s.parent;
    }
    return undefined;
  }

  /** Follow a nameref (declare -n) chain. The chain ends at a plain name, or at
   *  a `base[subscript]` target (a nameref to an array element), reported via
   *  `sub`. */
  private resolveRef(name: string): { name: string; sub: string | null } {
    // Fast path: the overwhelmingly common case is a plain (non-nameref)
    // variable — one lookup, no cycle-guard Set allocation.
    const first = this.rawLookup(name);
    if (!(first && first.ref && first.value !== "")) return { name, sub: null };
    // Nameref chain — guard against cycles.
    const seen = new Set<string>();
    let cur = name;
    for (;;) {
      const v = this.rawLookup(cur);
      if (v && v.ref && v.value !== "" && !seen.has(cur)) {
        seen.add(cur);
        const m = /^([A-Za-z_][A-Za-z0-9_]*)\[([\s\S]*)\]$/.exec(v.value);
        if (m) return { name: m[1]!, sub: m[2]! };
        cur = v.value;
        continue;
      }
      return { name: cur, sub: null };
    }
  }
  /** Follow a nameref chain to the target variable name (ignoring any element
   *  subscript — callers that operate on the whole variable). */
  private deref(name: string): string {
    return this.resolveRef(name).name;
  }
  /** `typeset +n name` — drop the nameref attribute; the value it held (the
   *  target's name) becomes the variable's plain value, as in bash. */
  clearRef(name: string): void {
    const v = this.rawLookup(name);
    if (v) v.ref = false;
  }
  /** Read `base[sub]` synchronously (arithmetic index / assoc key / `@`/`*`),
   *  shared by `${!ref}`, nameref resolution, and arithmetic array reads. */
  elemValueSync(base: string, sub: string): string | undefined {
    const v = this.lookup(base);
    if (v === undefined) return undefined;
    if (v.assoc !== null) return v.assoc.get(sub);
    if (sub === "@" || sub === "*") return this.arrayValues(base).join(" ");
    if (v.arr !== null) return this.arrayGet(base, Number(evalArith(this, sub)));
    return sub === "0" ? v.value : undefined; // scalar as element 0
  }
  /** True if `name` is an associative array (arithmetic keys are literal). */
  isAssoc(name: string): boolean {
    const v = this.lookup(name);
    return v !== undefined && v.assoc !== null;
  }
  /** True if `name` is an indexed or associative array (as opposed to a scalar). */
  isArrayLike(name: string): boolean {
    const v = this.lookup(name);
    return v !== undefined && (v.arr !== null || v.assoc !== null);
  }
  /** `${var@a}` — the variable's attribute letters (empty if unset/plain). */
  attrOf(name: string): string {
    const v = this.lookup(name);
    return v === undefined ? "" : attrLetters(v);
  }
  /** Write `base[sub]` synchronously (assoc key or arithmetic index) — used by
   *  namerefs and arithmetic array assignment. */
  setElemSync(base: string, sub: string, value: string): void {
    const v = this.lookup(base);
    if (v?.readonly) {
      this.io.err(`${this.name}: ${base}: readonly variable\n`);
      this.readonlyHit = true;
      return;
    }
    if (v && v.assoc !== null) { this.varForWriteRaw(this.deref(base)).assoc!.set(sub, value); return; }
    this.setElem(base, Number(evalArith(this, sub)), value);
  }

  private lookup(name: string): Var | undefined {
    return this.rawLookup(this.deref(name));
  }

  private ownerScope(name: string): Scope | undefined {
    let s: Scope | null = this.scope;
    while (s !== null) {
      if (s.vars.has(name)) return s;
      s = s.parent;
    }
    return undefined;
  }

  private assign(name: string, value: unknown): void {
    this.assignVar(name, value);
  }
  /** Core scalar write; returns the Var it wrote (for the arith cache), or
   *  undefined when the write went elsewhere (a nameref element, or was refused). */
  private assignVar(name: string, value: unknown): Var | undefined {
    if (value instanceof Var) {
      this.scope.vars.set(name, value);
      return value;
    }
    const r = this.resolveRef(name); // write through a nameref to its target
    if (r.sub !== null) { this.setElemSync(r.name, r.sub, String(value)); return undefined; }
    name = r.name;
    // Assigning a locale variable invalidates the cached regime (gate on 'L' so
    // ordinary assignments pay only a char compare).
    if (name.charCodeAt(0) === 76 && (name === "LANG" || name === "LC_ALL" || name === "LC_CTYPE")) this._localeUtf8 = null;
    const s = String(value);
    // Single scope-chain walk: mutate the existing box in place, else create in
    // the global scope (was two walks — ownerScope then get).
    const existing = this.scopeLookup(name);
    if (existing) {
      if (existing.readonly) {
        this.io.err(`${this.name}: ${name}: readonly variable\n`);
        this.readonlyHit = true;
        return undefined;
      }
      const cs = this.coerce(existing, s);
      if (existing.assoc !== null) existing.assoc.set("0", cs);
      else if (existing.arr !== null) existing.arr.set(0, cs);
      else existing.value = cs;
      existing.unset = false;
      return existing;
    }
    const nv = new Var(s, process.env[name] !== undefined);
    this.globalScope.vars.set(name, nv);
    return nv;
  }

  /** Apply a variable's attributes (-i/-l/-u) to a value being stored. */
  private coerce(v: Var, s: string): string {
    let out = s;
    if (v.integer) {
      try {
        out = String(evalArith(this, s));
      } catch {
        out = "0";
      }
    }
    if (v.lower) out = out.toLowerCase();
    else if (v.upper) out = out.toUpperCase();
    return out;
  }

  /** Set declare/local attributes on a variable, creating it if needed.
   *  Only future assignments are coerced — an existing value is left as-is
   *  (bash does not re-evaluate on `declare -i name`). */
  setAttrs(name: string, a: { integer?: boolean; lower?: boolean; upper?: boolean; readonly?: boolean }): void {
    const v = this.varForWrite(name);
    if (a.integer !== undefined) v.integer = a.integer;
    if (a.lower !== undefined) { v.lower = a.lower; if (a.lower) v.upper = false; }
    if (a.upper !== undefined) { v.upper = a.upper; if (a.upper) v.lower = false; }
    if (a.readonly) v.readonly = true;
  }

  getVar(name: string): string | undefined {
    const r = this.resolveRef(name);
    if (r.sub !== null) return this.elemValueSync(r.name, r.sub);
    const v = this.rawLookup(r.name);
    if (v === undefined || v.unset) return undefined;
    return v.scalar();
  }

  /** `set` with no args: every visible variable as a sorted `name=value` line
   *  (bash's quoting; arrays as `name=([i]="v" …)`). */
  varListing(): string[] {
    const out: string[] = [];
    for (const name of this.matchNames("")) {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) continue;
      const v = this.rawLookup(name);
      if (v === undefined || v.unset) continue;
      if (v.ref) { out.push(`${name}=${setQuote(v.value)}`); continue; } // nameref: shows its target
      if (v.assoc !== null) {
        const body = [...v.assoc.entries()].map(([k, val]) => `[${k}]=${declareQuote(val)}`).join(" ");
        out.push(`${name}=(${body})`);
      } else if (v.arr !== null) {
        const body = [...v.arr.entries()].sort((a, b) => a[0] - b[0])
          .map(([i, val]) => `[${i}]=${declareQuote(val)}`).join(" ");
        out.push(`${name}=(${body})`);
      } else {
        out.push(`${name}=${setQuote(v.value)}`);
      }
    }
    return out;
  }

  /** Visible variables whose box matches `pred`, as sorted `declare` lines —
   *  backs `declare -p`, `readonly -p`, `export -p`. */
  declareLinesWhere(pred: (v: Var) => boolean): string[] {
    const out: string[] = [];
    for (const name of this.matchNames("")) {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) continue;
      const v = this.rawLookup(name);
      if (v === undefined || v.unset || !pred(v)) continue;
      const line = this.declareLine(name);
      if (line !== null) out.push(line);
    }
    return out;
  }

  /** `${!prefix*}` / `${!prefix@}` — set variable names sharing a prefix. */
  matchNames(prefix: string): string[] {
    const set = new Set<string>();
    let s: Scope | null = this.scope;
    while (s !== null) {
      for (const k of s.vars.keys()) if (k.startsWith(prefix)) set.add(k);
      s = s.parent;
    }
    for (const k of Object.keys(process.env)) if (k.startsWith(prefix)) set.add(k);
    return [...set].sort();
  }

  /* ---- indexed arrays ---- */

  /** Find/create a variable by its literal name (no nameref resolution). */
  private varForWriteRaw(name: string): Var {
    const owner = this.ownerScope(name);
    const existing = owner?.vars.get(name);
    if (existing) return existing;
    const v = new Var("", process.env[name] !== undefined);
    this.globalScope.vars.set(name, v);
    return v;
  }
  private varForWrite(name: string): Var {
    return this.varForWriteRaw(this.deref(name));
  }
  /** True (with an error + readonlyHit) if `name` is an existing readonly
   *  variable, so array set/append paths can refuse the write, like bash. */
  private readonlyBlocked(name: string): boolean {
    if (this.lookup(name)?.readonly) {
      this.io.err(`${this.name}: ${name}: readonly variable\n`);
      this.readonlyHit = true;
      return true;
    }
    return false;
  }
  /** `declare -p name` — reconstruct the variable's definition, or null if
   *  it is unset. Attribute letters follow bash's order (a A i l n r t u x). */
  declareLine(name: string): string | null {
    const v = this.rawLookup(name);
    if (v === undefined) return null;
    const f = attrLetters(v);
    const attr = f === "" ? "--" : "-" + f;
    if (v.assoc !== null) {
      const body = [...v.assoc.entries()].map(([k, val]) => `[${k}]=${declareQuote(val)}`).join(" ");
      return `declare ${attr} ${name}=(${body}${v.assoc.size > 0 ? " " : ""})`;
    }
    if (v.arr !== null) {
      const body = [...v.arr.entries()].sort((a, b) => a[0] - b[0])
        .map(([i, val]) => `[${i}]=${declareQuote(val)}`).join(" ");
      return `declare ${attr} ${name}=(${body})`;
    }
    return `declare ${attr} ${name}=${declareQuote(v.value)}`;
  }

  /** If `name` is a nameref, the (unresolved) name it points to; else undefined.
   *  Used by `${!ref}` to invert a nameref to its target name. */
  namerefTarget(name: string): string | undefined {
    const v = this.rawLookup(name);
    return v !== undefined && v.ref && !v.unset ? v.value : undefined;
  }
  /** `declare -n name=target` — make `name` a nameref to `target`. A non-empty
   *  target must be a valid variable name (optionally `name[subscript]`), else
   *  bash rejects it; returns false so the caller can report status 1. */
  setRef(name: string, target: string): boolean {
    if (target !== "" && !/^[A-Za-z_][A-Za-z0-9_]*(\[[\s\S]*\])?$/.test(target)) {
      this.io.err(`${this.name}: declare: \`${target}': invalid variable name for name reference\n`);
      return false;
    }
    const v = this.varForWriteRaw(name);
    v.ref = true;
    if (target !== "") v.value = target;
    return true;
  }
  private maxIndex(v: Var): number {
    let m = -1;
    if (v.arr) for (const k of v.arr.keys()) if (k > m) m = k;
    return m;
  }
  private toArray(v: Var): Map<number, string> {
    if (v.arr === null) {
      v.arr = new Map();
      if (v.value !== "") v.arr.set(0, v.value);
      v.value = "";
    }
    return v.arr;
  }

  setArray(name: string, values: string[]): void {
    const v = this.varForWrite(name);
    v.arr = new Map();
    v.unset = false;
    values.forEach((val, i) => v.arr!.set(i, val));
  }
  setElem(name: string, index: number, value: string): void {
    const v = this.varForWrite(name);
    if (v.readonly) {
      this.io.err(`${this.name}: ${name}: readonly variable\n`);
      this.readonlyHit = true;
      return;
    }
    const arr = this.toArray(v);
    const i = index < 0 ? this.maxIndex(v) + 1 + index : index;
    if (i < 0) {
      // A negative index reaching before the start is a fatal bad subscript in
      // bash (status 1, no assignment); reuse the assignment-rejected signal.
      this.io.err(`${this.name}: ${name}[${index}]: bad array subscript\n`);
      this.readonlyHit = true;
      return;
    }
    v.unset = false;
    arr.set(i, value);
  }
  appendArray(name: string, values: string[]): void {
    if (this.readonlyBlocked(name)) return;
    const v = this.varForWrite(name);
    v.unset = false;
    const arr = this.toArray(v);
    let next = this.maxIndex(v) + 1;
    for (const val of values) arr.set(next++, val);
  }
  arrayGet(name: string, index: number): string | undefined {
    const v = this.lookup(name);
    if (!v || v.unset) return undefined;
    if (v.arr === null) return index === 0 ? v.value : undefined;
    return v.arr.get(index < 0 ? this.maxIndex(v) + 1 + index : index);
  }
  arrayValues(name: string): string[] {
    const v = this.lookup(name);
    if (!v || v.unset) return [];
    if (v.assoc !== null) return [...v.assoc.values()];
    if (v.arr === null) return [v.value];
    return [...v.arr.entries()].sort((a, b) => a[0] - b[0]).map((e) => e[1]);
  }
  arrayIndices(name: string): string[] {
    const v = this.lookup(name);
    if (!v || v.unset) return [];
    if (v.assoc !== null) return [...v.assoc.keys()];
    if (v.arr === null) return ["0"];
    return [...v.arr.keys()].sort((a, b) => a - b).map(String);
  }
  arrayLen(name: string): number {
    const v = this.lookup(name);
    if (!v || v.unset) return 0;
    if (v.assoc !== null) return v.assoc.size;
    return v.arr === null ? 1 : v.arr.size;
  }

  /** Mark a variable associative (declare -A). */
  declareAssoc(name: string): void {
    const v = this.varForWrite(name);
    if (v.assoc === null) v.assoc = new Map();
  }
  /** Get an array/assoc element by raw subscript (arithmetic index, or string
   *  key for an associative array). Shared by interpreter and generated code. */
  async elemGet(name: string, subRaw: string): Promise<string | undefined> {
    const v = this.lookup(name);
    if (v && v.assoc !== null) return v.assoc.get(await expandNoSplit(this, subRaw));
    return this.arrayGet(name, Number(evalArith(this, await expandNoSplit(this, subRaw))));
  }
  /** Set an array/assoc element by raw subscript. */
  async elemSet(name: string, subRaw: string, value: string): Promise<void> {
    const existing = this.lookup(name);
    if (existing?.readonly) {
      this.io.err(`${this.name}: ${name}: readonly variable\n`);
      this.readonlyHit = true;
      return;
    }
    const v = this.varForWrite(name);
    if (v.assoc !== null) {
      v.assoc.set(await expandNoSplit(this, subRaw), value);
      return;
    }
    this.setElem(name, Number(evalArith(this, await expandNoSplit(this, subRaw))), value);
  }

  private fillArray(arr: Map<number, string>, fields: string[], start: number): void {
    let idx = start;
    for (const f of fields) {
      const m = /^\[([^\]]*)\]=([\s\S]*)$/.exec(f);
      if (m) {
        idx = Number(evalArith(this, m[1]!));
        arr.set(idx, m[2]!);
      } else {
        arr.set(idx, f);
      }
      idx++;
    }
  }
  setArrayFields(name: string, fields: string[]): void {
    if (this.readonlyBlocked(name)) return;
    const v = this.varForWrite(name);
    v.unset = false;
    if (v.assoc !== null) {
      v.assoc = new Map();
      this.fillAssoc(v.assoc, fields);
      return;
    }
    v.arr = new Map();
    v.value = "";
    this.fillArray(v.arr, fields, 0);
  }
  appendArrayFields(name: string, fields: string[]): void {
    if (this.readonlyBlocked(name)) return;
    const v = this.varForWrite(name);
    v.unset = false;
    if (v.assoc !== null) {
      this.fillAssoc(v.assoc, fields);
      return;
    }
    this.fillArray(this.toArray(v), fields, this.maxIndex(v) + 1);
  }
  private fillAssoc(assoc: Map<string, string>, fields: string[]): void {
    let i = 0;
    while (i < fields.length) {
      const f = fields[i]!;
      const m = /^\[([\s\S]*?)\]=([\s\S]*)$/.exec(f);
      if (m) { assoc.set(m[1]!, m[2]!); i++; continue; }
      // A bare word is a key; the following word is its value (`(k1 v1 k2 v2)`).
      assoc.set(f, fields[i + 1] ?? "");
      i += 2;
    }
  }

  /** `${x:?msg}` / `${x?msg}`: report the error and exit. */
  paramError(name: string, msg: string): never {
    this.io.err(`${this.name}: ${name}: ${msg === "" ? "parameter null or not set" : msg}\n`);
    throw new ExitSignal(this.fatalStatus);
  }

  /** `${!name}`: the value of the variable named by `$name`. */
  indirect(name: string): string {
    return this.indirectValue(this.getVar(name) ?? "") ?? "";
  }
  /** Generated-code entry point for `${!ref …}` (indirect, possibly with an
   *  operator). Rebuilds the Param and reuses the interpreter's expansion. */
  indirectExpand(
    name: string, special: boolean, op: string, arg: string, arg2: string, length: boolean,
  ): Promise<string> {
    return evalParam(this, {
      name, special, length, indices: false, indirect: true, names: "", sub: "", op, arg, arg2,
    });
  }
  /** `"${arr[@]-word}"` / `+word` / `?` — a set array yields its elements as
   *  fields, else the default/alt word (one field if quoted, else split) or an
   *  error. Generated-code bridge mirroring expandWord's list-alternation case. */
  async altList(name: string, special: boolean, op: string, arg: string, quoted: boolean): Promise<string[]> {
    const vals = special ? [...this.positional] : this.arrayValues(name);
    const colon = op[0] === ":";
    const set = colon ? vals.length > 1 || (vals.length === 1 && vals[0] !== "") : vals.length > 0;
    const kind = colon ? op[1] : op[0];
    const word = async (): Promise<string[]> =>
      quoted ? [await expandNoSplit(this, arg)] : expandWord(this, { text: arg, flags: 0 });
    if (kind === "-") return set ? vals : word();
    if (kind === "+") return set ? word() : [];
    if (set) return vals;
    this.paramError(name, await expandNoSplit(this, arg));
  }
  /** Resolve a variable reference string (a name, or `name[subscript]`) to its
   *  value — the target of `${!ref}` / a nameref. */
  indirectValue(target: string): string | undefined {
    if (target === "") return undefined;
    const m = /^([A-Za-z_][A-Za-z0-9_]*)\[([\s\S]*)\]$/.exec(target);
    if (m === null) return this.getVar(target);
    return this.elemValueSync(m[1]!, m[2]!);
  }

  /** Separator for `$*` / `${a[*]}`: the first char of IFS (a space when IFS is
   *  unset, empty when IFS is set but empty). `$@` always joins with a space. */
  starSep(): string {
    const ifs = this.getVar("IFS");
    return ifs === undefined ? " " : ifs === "" ? "" : ifs[0]!;
  }
  /** Under `set -u`, throw the unbound-variable error if `name` is unset — used
   *  by generated code before value-using operators (substring, trim, case, …). */
  assertSet(name: string, special: boolean): void {
    if (!this.opts.nounset) return;
    const unbound = special
      ? /^[0-9]+$/.test(name) && Number(name) > this.positional.length
      : this.getVar(name) === undefined;
    if (unbound) {
      this.io.err(`${this.name}: ${name}: unbound variable\n`);
      throw new ExitSignal(this.fatalStatus);
    }
  }
  /** Report an unbound variable and exit (the `set -u` fatal path); used by the
   *  arithmetic evaluator, which reads variables outside the `$`-expansion path. */
  unbound(name: string): never {
    this.io.err(`${this.name}: ${name}: unbound variable\n`);
    throw new ExitSignal(this.fatalStatus);
  }
  /** Read a plain `$name` reference, honoring `set -u` (used by generated code). */
  ref(name: string): string {
    const r = this.resolveRef(name);
    const val = r.sub !== null
      ? this.elemValueSync(r.name, r.sub)
      : (() => {
          const v = this.rawLookup(r.name);
          return v === undefined || v.unset ? undefined : v.scalar();
        })();
    if (val === undefined) {
      if (this.opts.nounset) {
        this.io.err(`${this.name}: ${name}: unbound variable\n`);
        throw new ExitSignal(this.fatalStatus);
      }
      return "";
    }
    return val;
  }
  setVar(name: string, value: string): void {
    this.assign(name, value);
  }
  /** Whether `name` is bound as a variable in some visible scope (set or a
   *  declared-but-unset local). Used by `unset name` to decide whether to fall
   *  back to unsetting a function of the same name. */
  varExists(name: string): boolean {
    return this.ownerScope(name) !== undefined;
  }
  /** Whether `name` resolves to a readonly variable in any visible scope. */
  isReadonly(name: string): boolean {
    return this.scopeLookup(name)?.readonly ?? false;
  }
  unsetVar(name: string): void {
    name = this.deref(name); // `unset ref` removes the target, as in bash
    if (name.charCodeAt(0) === 76 && (name === "LANG" || name === "LC_ALL" || name === "LC_CTYPE")) this._localeUtf8 = null;
    const owner = this.ownerScope(name);
    if (owner === undefined) return;
    if (owner.vars.get(name)!.readonly) {
      this.io.err(`${this.name}: unset: ${name}: cannot unset: readonly variable\n`);
      this.readonlyHit = true;
      return;
    }
    if (owner === this.globalScope) {
      owner.vars.delete(name);
    } else {
      // Unsetting a local leaves an unset placeholder rather than deleting, so an
      // enclosing variable of the same name stays hidden for the rest of the
      // function (bash) — the placeholder is discarded when the scope pops.
      const nv = new Var("");
      nv.unset = true;
      owner.vars.set(name, nv);
    }
  }
  /** `unset arr[i]` / `unset assoc[key]` — remove a single element. */
  unsetElem(name: string, sub: string): void {
    const v = this.lookup(name);
    if (v === undefined) return;
    if (v.assoc !== null) { v.assoc.delete(sub); return; }
    if (v.arr !== null) {
      const raw = Number(evalArith(this, sub));
      const i = raw < 0 ? this.maxIndex(v) + 1 + raw : raw;
      if (i < 0) {
        this.io.err(`${this.name}: ${name}[${raw}]: bad array subscript\n`);
        this.readonlyHit = true;
        return;
      }
      v.arr.delete(i);
      return;
    }
    // A scalar's element 0 is the whole variable.
    if (sub === "0" || sub === "@" || sub === "*") this.unsetVar(name);
  }
  local(name: string, value?: string): void {
    const v = new Var(value ?? "");
    if (value === undefined) v.unset = true; // `local x` declares but doesn't set
    this.scope.vars.set(name, v);
  }
  /** True if `name` is already a local in the current (innermost) scope — used
   *  by `local x+=v`, which appends to an existing local but starts fresh
   *  (ignoring any enclosing value) on the first `local` declaration. */
  isLocalOwn(name: string): boolean {
    return this.scope.vars.has(name);
  }
  /** `name+=v`: numeric add for integer vars, else string append. */
  appendVar(name: string, rhs: string): void {
    const v = this.lookup(name);
    if (v && v.integer) {
      const cur = v.value === "" ? "0" : v.value;
      try {
        this.setVar(name, String(evalArith(this, `(${cur})+(${rhs})`)));
      } catch {
        this.setVar(name, cur);
      }
      return;
    }
    this.setVar(name, (this.getVar(name) ?? "") + rhs);
  }
  exportVar(name: string): void {
    name = this.deref(name);
    const owner = this.ownerScope(name);
    const existing = owner?.vars.get(name);
    if (existing) existing.exported = true;
    else this.globalScope.vars.set(name, new Var(process.env[name] ?? "", true));
  }
  unsetFunc(name: string): void {
    delete this.functions[name];
  }

  param(n: number): string {
    return n <= 0 ? this.name : this.positional[n - 1] ?? "";
  }

  private childEnv(extra: Record<string, string>): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env };
    const seen = new Set<string>();
    let s: Scope | null = this.scope;
    while (s !== null) {
      for (const [k, v] of s.vars) {
        if (!seen.has(k)) {
          seen.add(k);
          if (v.exported) env[k] = v.value;
        }
      }
      s = s.parent;
    }
    return { ...env, ...extra };
  }

  /* ---------------- word helpers (used by generated code) ---------------- */

  /** Mark a value as subject to field splitting inside `fields(...)`. */
  S(v: unknown): SplitMark {
    return { v: String(v) };
  }

  /** Assemble args from parts (strings = literal, S(...) = splittable). */
  fields(...parts: Array<string | SplitMark>): string[] {
    const chars: string[] = [];
    const sp: boolean[] = [];
    let anchored = false;
    for (const p of parts) {
      if (typeof p === "string") {
        for (const c of p) {
          chars.push(c);
          sp.push(false);
        }
        anchored = true;
      } else {
        for (const c of p.v) {
          chars.push(c);
          sp.push(true);
        }
      }
    }
    return splitTaggedFields(chars, sp, anchored, this.getVar("IFS"));
  }

  /** Command substitution (compiled): run body capturing stdout. */
  async sub(fn: (sh: Shell) => Promise<void>): Promise<string> {
    const chunks: string[] = [];
    const subsh = this.cloneForSubshell({ out: (s) => void chunks.push(s), err: (s) => this.io.err(s) });
    this.status = await runBody(subsh, fn);
    this.subCount++;
    return chunks.join("").replace(/\n+$/, "");
  }

  /** Command substitution (interpreter): parse + run a source string. */
  async subSrc(src: string): Promise<string> {
    return this.sub(async (sh) => {
      await sh.runString(src);
    });
  }

  /** Process substitution: run `fn` in a subshell, capture its output to a
   *  temp file, and return the path (`<(cmds)`). Does not affect `$?`. */
  async procSubFn(dir: string, fn: (sh: Shell) => Promise<void>): Promise<string> {
    const chunks: string[] = [];
    const subsh = this.cloneForSubshell({ out: (s) => void chunks.push(s), err: (s) => this.io.err(s) });
    await runBody(subsh, fn);
    const file = join(tmpdir(), `curse-ps-${process.pid}-${procSubSeq++}`);
    writeFileSync(file, dir === "<" ? chunks.join("") : "");
    procSubFiles.push(file);
    return file;
  }
  /** Process substitution (interpreter): parse + run a source string. */
  procSub(dir: string, src: string): Promise<string> {
    return this.procSubFn(dir, async (sh) => {
      await sh.runString(src);
    });
  }

  /* ---------------- arithmetic (shared with generated code) ---------------- */

  private async arithValue(expr: string): Promise<bigint> {
    return evalArith(this, await expandArith(this, expr));
  }
  /** `$(( expr ))` expansion → the value as a string. */
  async arithStr(expr: string): Promise<string> {
    return (await this.arithValue(expr)).toString();
  }
  /** `(( expr ))` command → status 0 if non-zero, else 1. */
  async arithCommand(expr: string): Promise<number> {
    try {
      this.status = (await this.arithValue(expr)) !== 0n ? 0 : 1;
    } catch (e) {
      // A control-flow signal (exit — e.g. an unbound var under `set -u` — or
      // return/break/continue) must propagate; only a genuine arithmetic error
      // is reported and mapped to status 1.
      if (e instanceof ExitSignal || e instanceof ReturnSignal || e instanceof LoopSignal) throw e;
      this.io.err(`${this.name}: ((: ${expr}: ${errMsg(e)}\n`);
      this.status = 1;
    }
    return this.status;
  }
  async arithRun(expr: string): Promise<void> {
    if (expr !== "") await this.arithValue(expr);
  }

  /* Compiled-arithmetic primitives: the emitter turns a `$(( ))` / `(( ))`
   * expression's AST into native-JS BigInt code that calls these, so the
   * expression is parsed once (at transpile time) instead of on every run.
   * Semantics mirror arith.mts's evalNode exactly. */
  /** 64-bit two's-complement wrap. */
  aw(v: bigint): bigint {
    return arithWrap(v);
  }
  /** Read a scalar as an arithmetic value (a variable's string is re-evaluated
   *  as arithmetic; empty/unset is 0). */
  aget(name: string): bigint {
    const v = this.rawLookup(name);
    if (v === undefined) { if (this.opts.nounset) this.unbound(name); return 0n; }
    if (v.ref && v.value !== "") return this.agetSlow(name); // nameref → full path
    if (v.unset) { if (this.opts.nounset) this.unbound(name); return 0n; }
    const c = v.intCache(); // fresh int, or a remembered parse: no re-parse
    if (c !== null) return c;
    const s = v.scalar();
    if (s === "") return 0n;
    const r = this.parseArithInt(s);
    v.cacheInt(s, r);
    return r;
  }
  /** Nameref / element-nameref arithmetic read (rare; no scalar cache). */
  private agetSlow(name: string): bigint {
    const raw = this.getVar(name);
    if (raw === undefined) { if (this.opts.nounset) this.unbound(name); return 0n; }
    return raw.trim() === "" ? 0n : this.parseArithInt(raw);
  }
  private parseArithInt(s: string): bigint {
    const t = s.trim();
    // Fast path: a plain decimal integer (no leading-zero octal / 0x hex
    // ambiguity) — a direct cast, skipping the full arithmetic re-parse.
    if (/^-?(0|[1-9][0-9]*)$/.test(t)) return arithWrap(BigInt(t));
    return evalArith(this, s);
  }
  /** Assign a scalar arithmetic value (stored lazily as a BigInt); returns it. */
  aset(name: string, v: bigint): bigint {
    this.assignInt(name, v);
    return v;
  }
  /** True if `v` is a plain scalar whose value can be held as a lazy BigInt
   *  (no nameref, readonly, attribute, or array shape forcing a string form). */
  private plainInt(v: Var): boolean {
    return !v.ref && !v.readonly && !v.integer && !v.lower && !v.upper && v.arr === null && v.assoc === null;
  }
  private assignInt(name: string, v: bigint): void {
    // One scope lookup handles the common case (an existing non-nameref var):
    // a nameref, or a not-yet-created var, takes the fuller path below.
    const box = this.scopeLookup(name);
    if (box !== undefined && !box.ref) {
      if (box.readonly) {
        this.io.err(`${this.name}: ${name}: readonly variable\n`);
        this.readonlyHit = true;
        return;
      }
      if (this.plainInt(box)) { box.setInt(v); box.unset = false; return; }
      this.assignVar(name, v.toString()); // attribute/array: string coerce path
      return;
    }
    const r = this.resolveRef(name);
    if (r.sub !== null) { this.setElemSync(r.name, r.sub, v.toString()); return; }
    if (box === undefined && r.name === name) {
      const nv = new Var("", process.env[name] !== undefined);
      nv.setInt(v);
      this.globalScope.vars.set(name, nv);
      return;
    }
    this.assignVar(r.name, v.toString());
  }
  /** `x++` / `++x` / `x--` / `--x` on a scalar; returns the pre/post value. */
  ainc(name: string, delta: bigint, post: boolean): bigint {
    // Fast path: an existing plain, writable scalar (the typical loop counter) —
    // one scope lookup, then mutate the box in place (lazy BigInt, no string).
    const v = this.scopeLookup(name);
    if (v !== undefined && this.plainInt(v)) {
      if (v.unset && this.opts.nounset) this.unbound(name); // unset placeholder under set -u
      const c = v.intCache();
      const cur = c !== null ? c : v.value === "" ? 0n : this.parseArithInt(v.value);
      const nv = arithWrap(cur + delta);
      v.setInt(nv);
      v.unset = false;
      return post ? cur : nv;
    }
    const cur = this.aget(name);
    const nv = arithWrap(cur + delta);
    this.aset(name, nv);
    return post ? cur : nv;
  }

  /* Hoisted-box arithmetic: the emitter resolves a loop variable's Var box once
   * (abox) and then reads/writes it directly, skipping the per-iteration scope
   * Map lookup. Only used where a static safety check proved the loop can't
   * unset/redeclare the variable or run opaque code (see the emitter). */
  /** Resolve-or-create the scalar box a name refers to (deref simple namerefs). */
  abox(name: string): Var {
    const r = this.resolveRef(name);
    const existing = this.scopeLookup(r.name);
    if (existing) return existing;
    const v = new Var("", process.env[r.name] !== undefined);
    this.globalScope.vars.set(r.name, v);
    return v;
  }
  bxget(v: Var): bigint {
    if (v.unset) return 0n;
    const c = v.intCache();
    if (c !== null) return c;
    const s = v.scalar();
    if (s === "") return 0n;
    const r = this.parseArithInt(s);
    v.cacheInt(s, r);
    return r;
  }
  bxset(v: Var, val: bigint): bigint {
    v.setInt(val);
    v.unset = false;
    return val;
  }
  bxinc(v: Var, delta: bigint, post: boolean): bigint {
    const c = v.intCache();
    const cur = c !== null ? c : v.value === "" ? 0n : this.parseArithInt(v.value);
    const nv = arithWrap(cur + delta);
    v.setInt(nv);
    v.unset = false;
    return post ? cur : nv;
  }
  adiv(l: bigint, r: bigint): bigint {
    if (r === 0n) throw new ArithError("division by 0");
    return arithWrap(l / r);
  }
  amod(l: bigint, r: bigint): bigint {
    if (r === 0n) throw new ArithError("division by 0");
    return arithWrap(l % r);
  }
  apow(l: bigint, r: bigint): bigint {
    if (r < 0n) throw new ArithError("exponent less than 0");
    return arithWrap(l ** r);
  }
  async arithTest(expr: string): Promise<boolean> {
    return expr === "" ? true : (await this.arithValue(expr)) !== 0n;
  }

  /* ---------------- command dispatch ---------------- */

  /** Define a bash function body as a monkeypatchable command value. */
  func(body: (sh: Shell) => Promise<void>): BashFunc {
    return { __bashFunc: body };
  }

  private async invokeFunc(body: (sh: Shell) => Promise<void>, args: string[]): Promise<number> {
    const savedScope = this.scope;
    const savedPos = this.positional;
    const savedLoopDepth = this.loopDepth;
    this.scope = new Scope(savedScope);
    this.positional = args;
    this.loopDepth = 0; // break/continue in the function only see its own loops
    try {
      await body(this);
    } catch (e) {
      // ReturnSignal ends the function; a break/continue that reached here
      // escaped its loops — swallow it rather than crossing the call boundary.
      if (e instanceof ReturnSignal) this.status = e.code;
      else if (e instanceof LoopSignal) { /* no-op */ }
      else throw e;
    } finally {
      this.scope = savedScope;
      this.positional = savedPos;
      this.loopDepth = savedLoopDepth;
    }
    return this.status;
  }

  /** Resolve and run a command by name (function → builtin → external). */
  async callByName(name: string, args: string[]): Promise<number> {
    const fn = this.functions[name];
    let code: number;
    if (fn && typeof fn === "object" && "__bashFunc" in fn) {
      code = await this.invokeFunc((fn as BashFunc).__bashFunc, args);
    } else if (typeof fn === "function") {
      code = await (fn as (sh: Shell, ...a: string[]) => number | Promise<number>)(this, ...args);
    } else {
      code = await this.external(name, args, {});
    }
    this.status = code;
    this.setArray("PIPESTATUS", [String(code)]); // a lone command is a 1-stage pipeline
    await this.afterCommand();
    return code;
  }

  /* ---- introspection / dispatch (type, command, builtin) ---- */

  /** A bash function is defined under this name (own property, not a builtin). */
  hasFunction(name: string): boolean {
    const f = this.functions[name];
    return (
      Object.prototype.hasOwnProperty.call(this.functions, name) &&
      !!f && typeof f === "object" && "__bashFunc" in (f as object)
    );
  }
  hasBuiltin(name: string): boolean {
    return Object.prototype.hasOwnProperty.call(builtins, name);
  }
  /** Names of defined shell functions, sorted (for `declare -F`). */
  functionNames(): string[] {
    return Object.keys(this.functions).filter((k) => this.hasFunction(k)).sort();
  }
  /** Resolve `name` on PATH to an executable file path, or null. */
  lookupPath(name: string): string | null {
    const check = (p: string): boolean => {
      try {
        return statSync(p).isFile() && (accessSync(p, constants.X_OK), true);
      } catch {
        return false;
      }
    };
    if (name.includes("/")) {
      const p = resolve(this.cwd, name);
      return check(p) ? name : null;
    }
    const path = this.getVar("PATH") ?? process.env["PATH"] ?? "";
    for (const dir of path.split(":")) {
      if (dir === "") continue;
      const p = resolve(dir, name);
      if (check(p)) return p;
    }
    return null;
  }
  /** Every executable named `name` found across PATH, in order (`type -a`). */
  lookupAllPaths(name: string): string[] {
    if (name.includes("/")) { const p = this.lookupPath(name); return p === null ? [] : [p]; }
    const path = this.getVar("PATH") ?? process.env["PATH"] ?? "";
    const out: string[] = [];
    for (const dir of path.split(":")) {
      if (dir === "") continue;
      const p = resolve(dir, name);
      try {
        if (statSync(p).isFile()) { accessSync(p, constants.X_OK); out.push(p); }
      } catch { /* not here */ }
    }
    return out;
  }
  /** Run a builtin directly, ignoring any shadowing function (`builtin`). */
  async runBuiltin(name: string, args: string[]): Promise<number> {
    const b = (builtins as Record<string, (sh: Shell, ...a: string[]) => number | Promise<number>>)[name];
    if (b === undefined) {
      this.io.err(`${this.name}: ${name}: not a shell builtin\n`);
      this.status = 1;
      return 1;
    }
    const code = await b(this, ...args);
    this.status = code;
    return code;
  }
  /** Run `name` bypassing functions: builtin, else external (`command`). */
  async runBypassFunc(name: string, args: string[]): Promise<number> {
    if (this.hasBuiltin(name)) return this.runBuiltin(name, args);
    const code = await this.external(name, args, {});
    this.status = code;
    return code;
  }

  /** Dispatch when the command name itself came from an expansion. */
  async exec(...fields: string[]): Promise<number> {
    if (fields.length === 0) {
      // Empty command: keep the last command sub's status if one ran during the
      // (now-complete) argument expansion, else 0 — mirroring the interpreter.
      if (this.subCount === this.subMarkCount) this.status = 0;
      return this.status;
    }
    return this.callByName(fields[0]!, fields.slice(1));
  }

  /** Run `fn` with temporary (exported) assignments, e.g. `FOO=bar cmd`. */
  async withEnv(assignments: Record<string, string>, fn: () => Promise<number>): Promise<number> {
    const saved: Array<[string, Var | undefined]> = [];
    for (const [k, v] of Object.entries(assignments)) {
      saved.push([k, this.scope.vars.get(k)]);
      this.scope.vars.set(k, new Var(v, true));
    }
    try {
      return await fn();
    } finally {
      for (const [k, prev] of saved) {
        if (prev === undefined) this.scope.vars.delete(k);
        else this.scope.vars.set(k, prev);
      }
    }
  }

  /* ---------------- redirections ---------------- */

  /** Run `run` with the given redirections applied to this shell's io/stdin,
   *  restoring afterwards. Targets are already-expanded strings (the compiler
   *  expands inline; the interpreter expands before calling). Both builtins
   *  (which write via io) and externals (whose piped output is forwarded to io)
   *  are covered by this one model. */
  async withRedirects(redirects: RedirIO[], run: () => Promise<number>): Promise<number> {
    if (redirects.length === 0) return run();
    const savedOut = this.io.out;
    const savedErr = this.io.err;
    const savedStdin = this.stdinData;
    const toClose: number[] = [];
    // fd -> writer; 1 and 2 start at the current io.
    const writers: Record<number, (s: string) => void> = { 1: savedOut, 2: savedErr };
    try {
      for (const r of redirects) {
        if (!this.applyRedirect(r, r.target, writers, toClose)) {
          this.status = 1;
          return 1; // redirect failed (noclobber): don't run the command
        }
      }
      this.io = { out: writers[1] ?? savedOut, err: writers[2] ?? savedErr };
      return await run();
    } finally {
      this.io = { out: savedOut, err: savedErr };
      this.stdinData = savedStdin;
      for (const fd of toClose) {
        try {
          closeSync(fd);
        } catch {
          /* already closed */
        }
      }
    }
  }

  /** Apply one redirection. Returns false (with a diagnostic) when it fails —
   *  currently only a noclobber violation — so the command is not run. */
  private applyRedirect(
    r: RedirIO,
    target: string,
    writers: Record<number, (s: string) => void>,
    toClose: number[],
  ): boolean {
    const openFile = (flags: string): ((s: string) => void) => {
      const fd = openSync(resolve(this.cwd, target), flags);
      toClose.push(fd);
      return (s: string) => void writeSync(fd, s);
    };
    // set -C: `>` / `&>` won't truncate an existing regular file (`>|` will).
    const clobberBlocked = (): boolean => {
      if (!this.opts.noclobber) return false;
      try {
        return statSync(resolve(this.cwd, target)).isFile();
      } catch {
        return false;
      }
    };
    switch (r.op) {
      case ">":
        if (clobberBlocked()) { this.io.err(`${this.name}: ${target}: cannot overwrite existing file\n`); return false; }
        writers[r.fd] = openFile("w");
        break;
      case ">|": writers[r.fd] = openFile("w"); break;
      case ">>": writers[r.fd] = openFile("a"); break;
      case "&>": {
        if (clobberBlocked()) { this.io.err(`${this.name}: ${target}: cannot overwrite existing file\n`); return false; }
        const w = openFile("w"); writers[1] = w; writers[2] = w; break;
      }
      case "&>>": { const w = openFile("a"); writers[1] = w; writers[2] = w; break; }
      case "<": this.stdinData = readFileSync(resolve(this.cwd, target), "utf8"); break;
      case "<>": {
        // Open read/write, creating the file if absent (O_RDWR|O_CREAT).
        const p = resolve(this.cwd, target);
        try { closeSync(openSync(p, "a")); } catch { /* create failed */ }
        if (r.fd === 0) {
          this.stdinData = readFileSync(p, "utf8");
        } else {
          const fd = openSync(p, "r+");
          toClose.push(fd);
          let off = 0;
          writers[r.fd] = (s: string) => { writeSync(fd, s, off); off += Buffer.byteLength(s); };
        }
        break;
      }
      case "<<<": this.stdinData = target + "\n"; break;
      case "<<": case "<<-": this.stdinData = target; break;
      case ">&": case "<&": {
        if (target === "-") {
          writers[r.fd] = () => {};
          break;
        }
        const t = parseInt(target, 10);
        if (Number.isNaN(t)) {
          if (r.op === ">&") {
            const w = openFile("w");
            writers[1] = w;
            writers[2] = w;
            break;
          }
          throw new Error(`${target}: ambiguous redirect`);
        }
        if (r.op === ">&") writers[r.fd] = writers[t] ?? (() => {});
        // `<&` (dup input) is uncommon; left as inherit for now.
        break;
      }
      default:
        throw new Error(`redirection \`${r.op}\` not supported yet`);
    }
    return true;
  }

  private external(name: string, args: string[], extraEnv: Record<string, string>): Promise<number> {
    // An empty command name (e.g. `''` or a var that expanded to nothing) is
    // "command not found", not a spawn crash.
    if (name === "") {
      this.io.err(`${this.name}: ${name}: command not found\n`);
      return Promise.resolve(127);
    }
    return new Promise<number>((resolvePromise) => {
      let settled = false;
      const done = (code: number): void => {
        if (!settled) {
          settled = true;
          resolvePromise(code);
        }
      };
      const stdin = this.stdinData;
      const child = spawn(name, args, {
        cwd: this.cwd,
        env: this.childEnv(extraEnv),
        stdio: [stdin !== null ? "pipe" : "inherit", "pipe", "pipe"],
      });
      if (stdin !== null && child.stdin) {
        child.stdin.write(stdin);
        child.stdin.end();
      }
      child.stdout?.on("data", (d: Buffer) => this.io.out(d.toString()));
      child.stderr?.on("data", (d: Buffer) => this.io.err(d.toString()));
      child.on("error", (err: NodeJS.ErrnoException) => {
        if (err.code === "ENOENT") {
          this.io.err(`${this.name}: ${name}: command not found\n`);
          done(127);
        } else if (err.code === "EACCES") {
          this.io.err(`${this.name}: ${name}: Permission denied\n`);
          done(126);
        } else {
          this.io.err(`${this.name}: ${name}: ${err.message}\n`);
          done(127);
        }
      });
      child.on("close", (code, signal) => done(signal ? 128 + 1 : code ?? 0));
    });
  }

  /* ---------------- subshells ---------------- */

  private snapshotVars(): Scope {
    const flat = new Scope();
    let s: Scope | null = this.scope;
    while (s !== null) {
      for (const [k, v] of s.vars) {
        if (!flat.vars.has(k)) {
          const nv = new Var(v.value, v.exported);
          if (v.arr !== null) nv.arr = new Map(v.arr);
          if (v.assoc !== null) nv.assoc = new Map(v.assoc);
          nv.integer = v.integer;
          nv.lower = v.lower;
          nv.upper = v.upper;
          nv.readonly = v.readonly;
          nv.ref = v.ref;
          nv.unset = v.unset;
          flat.vars.set(k, nv);
        }
      }
      s = s.parent;
    }
    return flat;
  }

  private cloneForSubshell(io?: IO): Shell {
    const sub = new Shell(io ?? this.io);
    const vars = this.snapshotVars();
    sub.globalScope = vars;
    sub.scope = vars;
    sub.functions = Object.create(this.functions) as Record<string, unknown>;
    sub.positional = [...this.positional];
    sub.status = this.status;
    sub.name = this.name;
    sub.cwd = this.cwd;
    sub.dirStack = [...this.dirStack];
    sub.opts = { ...this.opts };
    sub.shopts = { ...this.shopts }; // a subshell inherits, but can't leak, shopt
    sub.stdinBuf = this.stdinBuf; // share stdin by reference: a read in the subshell advances the parent's position too
    sub.fatalStatus = this.fatalStatus; // same invocation mode (-c vs file)
    sub.condDepth = this.condDepth; // a subshell in a condition (`if ( … )`) inherits errexit suppression
    // Trap settings are inherited (visible to `trap -p`); a subshell can't leak.
    sub.traps = Object.assign(Object.create(null) as Record<string, string>, this.traps);
    return sub;
  }

  /** Enter an errexit-suppressed scope (conditions, `!`, `&&`/`||` non-final).
   *  Used by generated code via `using _ = sh.suppress();` so the scope is
   *  restored automatically at block exit (including on throw). */
  suppress(): Disposable {
    this.condDepth++;
    return {
      [Symbol.dispose]: () => {
        this.condDepth--;
      },
    };
  }

  /** Pathname expansion of already-split fields (unquoted words only): a field
   *  containing a glob metacharacter is replaced by its sorted matches, or kept
   *  literal if none match. Shared by interpreter and generated code. */
  glob(fields: string[]): string[] {
    if (this.opts.noglob) return fields; // `set -f`: pathname expansion disabled
    const eg = this.shopts.extglob;
    // GLOBIGNORE (set and non-null): matches are filtered against its patterns,
    // and its presence enables dotglob so leading-dot names become candidates.
    const giVar = this.lookup("GLOBIGNORE");
    const gi = giVar !== undefined && !giVar.unset ? giVar.value : "";
    const dot = this.shopts.dotglob || gi !== "";
    const out: string[] = [];
    for (const f of fields) {
      if (hasGlobMeta(f) || (eg && hasExtglob(f))) {
        let m = globExpand(this.cwd, f, dot, this.shopts.globstar, eg);
        if (gi !== "") m = m.filter((p) => !globIgnored(p, gi, eg));
        if (m.length > 0) out.push(...m);
        else if (this.shopts.nullglob) continue; // drop patterns that match nothing
        else out.push(f);
      } else {
        out.push(f);
      }
    }
    return out;
  }

  /** Pattern match (used by generated `case` / `[[ == ]]` with dynamic patterns). */
  match(subject: string, pattern: string): boolean {
    return globMatch(subject, pattern, this.shopts.nocasematch, this.shopts.extglob);
  }

  /** Whether a variable is set (used by generated `${x-…}` / `${x+…}`). */
  has(name: string): boolean {
    // Special parameters aren't stored as Vars: `$@`/`$*` are set only with
    // positional params, `$1`.. only within range, and `$0 $? $$ $# $! $- $_`
    // are always set.
    if (name === "@" || name === "*") return this.positional.length > 0;
    if (/^[0-9]+$/.test(name)) return name === "0" || Number(name) <= this.positional.length;
    if (name.length === 1 && "?$#!-_".includes(name)) return true;
    const v = this.lookup(name);
    if (v === undefined || v.unset) return false;
    // `$a` on an array/assoc is `${a[0]}` / key "0": set only if it exists.
    if (v.arr !== null || v.assoc !== null) return this.elemValueSync(name, "0") !== undefined;
    return true;
  }

  /* Parameter-expansion string ops (used by generated code). */
  trimPrefix(v: string, pat: string, longest: boolean): string {
    return pTrimPrefix(v, pat, longest, this.shopts.extglob);
  }
  trimSuffix(v: string, pat: string, longest: boolean): string {
    return pTrimSuffix(v, pat, longest, this.shopts.extglob);
  }
  replaceGlob(v: string, pat: string, repl: string, all: boolean, anchor: string): string {
    return pReplaceGlob(v, pat, repl, all, anchor, this.shopts.extglob);
  }
  async substr(v: string, offExpr: string, lenExpr: string): Promise<string> {
    const off = Number(await this.arithValue(offExpr));
    const len = lenExpr === "" ? undefined : Number(await this.arithValue(lenExpr));
    return pSubstr(v, off, len);
  }
  /** `${v:off:len}` with offset/length already computed (compiled arith). */
  substrN(v: string, off: bigint, len: bigint | null): string {
    return pSubstr(v, Number(off), len === null ? undefined : Number(len));
  }
  private async doSlice(list: string[], offExpr: string, lenExpr: string): Promise<string[]> {
    const off = Number(await this.arithValue(offExpr));
    const len = lenExpr === "" ? undefined : Number(await this.arithValue(lenExpr));
    // Unlike a string slice, a negative length on an array/positional slice is a
    // fatal expansion error that aborts the command (bash: "substring expression
    // < 0"); ArithError routes through the same per-command abort as arithmetic.
    if (len !== undefined && len < 0) throw new ArithError(`${len}: substring expression < 0`);
    return pSliceArr(list, off, len);
  }
  /** `${parameter@op}` transformation of a scalar value. */
  transform(op: string, v: string): string {
    return pTransform(op, v);
  }
  /** `${v^}` `${v^^}` `${v,}` `${v,,}` case modification. */
  changeCase(v: string, op: string, pat: string): string {
    return pChangeCase(v, op, pat);
  }
  /** `${arr[@]:offset:length}` — slice an array's values. */
  async sliceArr(name: string, offExpr: string, lenExpr: string): Promise<string[]> {
    return this.doSlice(this.arrayValues(name), offExpr, lenExpr);
  }
  /** `${@:offset:length}` — slice the positional params ([$0, $1, …]). */
  async slicePos(offExpr: string, lenExpr: string): Promise<string[]> {
    return this.doSlice([this.name, ...this.positional], offExpr, lenExpr);
  }

  /** `-v x` / `-v arr[i]` / `-v arr[@]` — is the variable/element set?
   *  Shared by `[[ -v ]]`, the `test` builtin, and generated code. */
  isSet(arg: string): boolean {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)\[([\s\S]*)\]$/.exec(arg);
    if (m === null) return this.has(arg);
    const v = this.lookup(m[1]!);
    if (v === undefined || v.unset) return false;
    const sub = m[2]!;
    // For an associative array @/* are literal keys, not "any element".
    if (v.assoc !== null) return v.assoc.has(sub);
    if (sub === "@" || sub === "*") {
      if (v.arr !== null) return v.arr.size > 0;
      return true; // a set scalar has element 0
    }
    let idx: number;
    try {
      idx = Number(evalArith(this, sub));
    } catch {
      return false;
    }
    if (v.arr !== null) return v.arr.has(idx < 0 ? this.maxIndex(v) + 1 + idx : idx);
    return idx === 0; // a scalar is element 0
  }

  condUnary(op: string, arg: string): boolean {
    if (op === "-z") return arg.length === 0;
    if (op === "-n") return arg.length > 0;
    if (op === "-v") return this.isSet(arg);
    if (op === "-o") return false; // shopt option — unsupported
    const p = resolve(this.cwd, arg);
    let st: ReturnType<typeof statSync> | null = null;
    try {
      st = statSync(p);
    } catch {
      st = null;
    }
    const access = (m: number): boolean => {
      try {
        accessSync(p, m);
        return true;
      } catch {
        return false;
      }
    };
    switch (op) {
      case "-e": case "-a": return st !== null;
      case "-f": return st?.isFile() ?? false;
      case "-d": return st?.isDirectory() ?? false;
      case "-s": return (st?.size ?? 0) > 0;
      case "-r": return access(constants.R_OK);
      case "-w": return access(constants.W_OK);
      case "-x": return access(constants.X_OK);
      case "-b": return st?.isBlockDevice() ?? false;
      case "-c": return st?.isCharacterDevice() ?? false;
      case "-p": return st?.isFIFO() ?? false;
      case "-S": return st?.isSocket() ?? false;
      case "-h": case "-L":
        try {
          return lstatSync(p).isSymbolicLink();
        } catch {
          return false;
        }
      default:
        return false;
    }
  }

  /** `[[ ]]` binary test (used by generated code and the interpreter). */
  /** Final status of a `[[ ]]`: 2 if the evaluation errored, else 0/1. */
  condStatus(ok: boolean): number {
    return this.condFatal ? 2 : ok ? 0 : 1;
  }

  condBinary(l: string, op: string, r: string): boolean {
    const intOf = (s: string): bigint => {
      try {
        return evalArith(this, s);
      } catch {
        return 0n;
      }
    };
    const mtime = (s: string): number => {
      try {
        return statSync(resolve(this.cwd, s)).mtimeMs;
      } catch {
        return -Infinity;
      }
    };
    switch (op) {
      case "==": case "=": return globMatch(l, r, this.shopts.nocasematch, this.shopts.extglob);
      case "!=": return !globMatch(l, r, this.shopts.nocasematch, this.shopts.extglob);
      case "<": return l < r;
      case ">": return l > r;
      case "-eq": return intOf(l) === intOf(r);
      case "-ne": return intOf(l) !== intOf(r);
      case "-lt": return intOf(l) < intOf(r);
      case "-le": return intOf(l) <= intOf(r);
      case "-gt": return intOf(l) > intOf(r);
      case "-ge": return intOf(l) >= intOf(r);
      case "-nt": return mtime(l) > mtime(r);
      case "-ot": return mtime(l) < mtime(r);
      case "-ef": {
        try {
          const a = statSync(resolve(this.cwd, l));
          const b = statSync(resolve(this.cwd, r));
          return a.dev === b.dev && a.ino === b.ino;
        } catch {
          return false;
        }
      }
      default:
        return false;
    }
  }

  /** `[[ str =~ re ]]` — match against an ERE and populate BASH_REMATCH.
   *  `rawRhs` is the unexpanded RHS word: unquoted text and unquoted
   *  expansions are regex; quoted/escaped portions match literally. */
  async condMatch(subject: string, rawRhs: string): Promise<boolean> {
    let re: RegExp;
    try {
      re = new RegExp(await this.condRegex(rawRhs));
    } catch (e) {
      this.io.err(`${this.name}: ${rawRhs}: ${errMsg(e)}\n`);
      this.condFatal = true;
      return false;
    }
    const m = re.exec(subject);
    this.setArray("BASH_REMATCH", m === null ? [] : Array.from(m, (g) => g ?? ""));
    return m !== null;
  }

  /** Build a JS regex source from a `[[ =~ ]]` RHS word. */
  /** Walk a `[[ ]]` RHS word: quoted/escaped spans are passed through `esc`
   *  (making their metacharacters literal), unquoted text and expansions stay
   *  active. Shared by `=~` (regex) and `==` (glob) matching. */
  private async condWalk(raw: string, esc: (s: string) => string, tilde = false): Promise<string> {
    let out = "";
    let i = 0;
    // A leading unquoted `~` / `~/…` in a `[[ ]]`, `case`, or `=~` pattern
    // tilde-expands to $HOME as a literal (bash; not done for `${v#pat}` ops).
    if (tilde && raw[0] === "~" && (raw.length === 1 || raw[1] === "/")) {
      out += esc(this.getVar("HOME") ?? "");
      i = 1;
    }
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
          if (raw[i] === "\\" && i + 1 < raw.length) { seg += raw[i]! + raw[i + 1]!; i += 2; continue; }
          seg += raw[i]!; i++;
        }
        i++;
        out += esc(await expandNoSplit(this, seg));
        continue;
      }
      if (c === "$") {
        const end = expansionEnd(raw, i);
        if (end > i) { out += await expandNoSplit(this, raw.slice(i, end)); i = end; continue; }
      }
      out += c;
      i++;
    }
    return out;
  }

  private condRegex(raw: string): Promise<string> {
    return this.condWalk(raw, (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), true);
  }
  /** `[[ x == pat ]]` / case / `${v/pat/…}` pattern — expand a word into a glob
   *  pattern where quoted or backslash-escaped metacharacters are escaped (so
   *  they match literally) while unquoted globs stay active, as bash does. */
  patExpand(raw: string, tilde = false): Promise<string> {
    return this.condWalk(raw, (s) => s.replace(/[^A-Za-z0-9]/g, "\\$&"), tilde);
  }
  /** Quote-aware glob match for `==`/`!=` and case, honouring nocasematch.
   *  `[[ ]]` always recognises extended patterns; `case`/globbing need the
   *  extglob option, so callers pass the flag they want. */
  async matchGlob(subject: string, rawPat: string, extglob = this.shopts.extglob): Promise<boolean> {
    return globMatch(subject, await this.patExpand(rawPat, true), this.shopts.nocasematch, extglob);
  }

  /** `$-` — the current single-letter option flags (bash order: e h u x B;
   *  h and B are on by default in a non-interactive shell). */
  optionFlags(): string {
    let s = "";
    if (this.opts.errexit) s += "e";
    if (this.opts.noglob) s += "f";
    s += "h";
    if (this.opts.nounset) s += "u";
    if (this.opts.xtrace) s += "x";
    s += "B";
    if (this.opts.noclobber) s += "C";
    return s;
  }

  /** Apply `!` inversion in generated code. */
  invert(): void {
    this.status = this.status === 0 ? 1 : 0;
  }

  /** Run a pipeline: each stage in its own subshell, stdout wired to the next
   *  stage's stdin (buffered). The pipeline's status is the last stage's. */
  async pipeline(stages: Array<(sh: Shell) => Promise<unknown>>): Promise<number> {
    let input = this.stdinData;
    let status = 0;
    let lastNonZero = 0;
    const statuses: number[] = [];
    for (let idx = 0; idx < stages.length; idx++) {
      const isLast = idx === stages.length - 1;
      const chunks: string[] = [];
      const io: IO = isLast ? this.io : { out: (s) => void chunks.push(s), err: (s) => this.io.err(s) };
      const sub = this.cloneForSubshell(io);
      sub.stdinBuf = { data: input }; // its own slice of the upstream output, not the shared parent box
      status = await runBody(sub, stages[idx]!);
      statuses.push(status);
      if (status !== 0) lastNonZero = status;
      if (!isLast) input = chunks.join("");
    }
    this.setArray("PIPESTATUS", statuses.map(String));
    this.status = this.opts.pipefail ? lastNonZero : status;
    await this.afterCommand();
    return this.status;
  }

  /** Start a command in the background (a subshell); sets `$!`, returns 0. */
  background(fn: (sh: Shell) => Promise<unknown>): number {
    const sub = this.cloneForSubshell();
    const pid = ++this.nextPid;
    this.lastBgPid = pid;
    this.jobs.push({ pid, promise: runBody(sub, fn).catch(() => 1) });
    this.status = 0;
    return 0;
  }

  async waitAll(): Promise<void> {
    const pending = this.jobs;
    this.jobs = [];
    await Promise.allSettled(pending.map((j) => j.promise));
  }

  async waitFor(pid: number): Promise<number> {
    const idx = this.jobs.findIndex((j) => j.pid === pid);
    if (idx < 0) return 127;
    const [job] = this.jobs.splice(idx, 1);
    return job!.promise;
  }

  /** Run a body in a subshell (used by generated subshells). */
  async runSubshell(fn: (sh: Shell) => Promise<void>): Promise<number> {
    const sub = this.cloneForSubshell();
    this.status = await runBody(sub, fn);
    return this.status;
  }

  /* ---------------- interpreter (JIT / eval path) ---------------- */

  /** Run the EXIT trap (once) as the shell exits. $? starts at the triggering
   *  status and is preserved afterwards unless the handler runs `exit`. */
  async runExitTrap(): Promise<void> {
    const handler = this.traps["EXIT"];
    if (handler === undefined || handler === "" || this.ranExitTrap) return;
    this.ranExitTrap = true;
    const saved = this.status;
    try {
      const cmd = parse(handler);
      if (cmd !== null) await this.execute(cmd);
      this.status = saved;
    } catch (e) {
      if (e instanceof ExitSignal || e instanceof ReturnSignal) this.status = e.code;
      else throw e;
    }
  }

  /** `eval` / `source`: parse `src` and run it in THIS shell (shared scope),
   *  letting return/exit/break propagate to the caller. This is the JIT path —
   *  generated code reaches it through the eval/source builtins. */
  /** Run a `source`d file in this shell. AOT where possible: transpile the file
   *  to a cached fragment (re-transpiled only when the file changes — so even
   *  `source "$dynamic"` is cached by the resolved file's content) and run it
   *  against this shell. Falls back to interpreting when the file can't be
   *  compiled to an importable module (parse failure, unwritable cache, …). */
  async sourceFile(path: string): Promise<number> {
    let frag: ((sh: Shell) => Promise<number>) | null = null;
    try {
      const [{ emit }, { cachedModulePath }] = await Promise.all([
        import("../compiler/emit.mts"),
        import("../cli/cache.mts"),
      ]);
      const rt = new URL("./shell.mts", import.meta.url).href;
      const modPath = cachedModulePath(
        path, rt, (src) => emit(parse(src), { runtimeSpecifier: rt, fragment: true }), "frag",
      );
      if (modPath !== null) {
        const mod = await import(pathToFileURL(modPath).href) as { default: (sh: Shell) => Promise<number> };
        frag = mod.default;
      }
    } catch {
      frag = null; // compile/import failed → interpret instead
    }
    // Running the fragment propagates control flow (exit) and real errors — no
    // fallback here, or a half-run source would double-execute.
    if (frag !== null) return frag(this);
    return this.evalString(readFileSync(path, "utf8"));
  }

  async evalString(src: string): Promise<number> {
    let cmd: Command | null;
    try {
      cmd = parse(src);
    } catch (e) {
      this.io.err(`${this.name}: ${errMsg(e)}\n`);
      this.status = 2;
      return 2;
    }
    if (cmd === null) return this.status;
    return this.execute(cmd);
  }

  async runString(src: string): Promise<number> {
    const cmd = parse(src);
    if (cmd === null) {
      this.status = 0;
      return 0;
    }
    try {
      return await this.execute(cmd);
    } catch (e) {
      if (e instanceof ExitSignal) { this.exited = true; this.status = e.code; return e.code; }
      if (e instanceof ReturnSignal) { this.status = e.code; return e.code; }
      if (e instanceof LoopSignal) return this.status; // break/continue outside a loop
      throw e;
    }
  }

  async execute(cmd: Command): Promise<number> {
    const invert = cmd.flags !== undefined && (cmd.flags & CMD_INVERT_RETURN) !== 0;
    if (invert) this.condDepth++; // `! cmd` is exempt from errexit
    let status: number;
    try {
      if (cmd.redirects !== undefined && cmd.redirects.length > 0) {
        const reds: RedirIO[] = [];
        for (const r of cmd.redirects) {
          const target =
            r.op === "<<" || r.op === "<<-"
              ? await expandParsed(this, parseHeredoc(r.target.text, r.expand !== false))
              : await expandNoSplit(this, r.target.text);
          reds.push({ op: r.op, fd: r.fd, target });
        }
        status = await this.withRedirects(reds, () => this.dispatch(cmd));
      } else {
        status = await this.dispatch(cmd);
      }
    } catch (e) {
      // A fatal arithmetic error during this command's expansion (div by zero,
      // a bad constant, an invalid base) aborts just this command with status 1
      // and continues, exactly like bash — it is not a shell-fatal signal.
      if (!(e instanceof ArithError)) throw e;
      this.io.err(`${this.name}: ${e.message}\n`);
      status = this.status = 1;
    } finally {
      if (invert) this.condDepth--;
    }
    if (invert) {
      status = status === 0 ? 1 : 0;
      this.status = status;
    }
    return status;
  }

  /** `set -e`: throw to exit when a command fails outside a suppressed context
   *  (conditions, `!`, and the non-final operands of && / ||). Called at the
   *  shared choke points (callByName, pipeline) so both the interpreter and the
   *  AOT-generated code honor it. */
  /** After a command completes at the top level (not in a condition / `&&` /
   *  `||` / `!`): a non-zero status fires the ERR trap, then errexit exits.
   *  Also called from generated code for subshell/arith/cond commands. */
  async afterCommand(): Promise<void> {
    if (this.status === 0 || this.condDepth !== 0) return;
    const h = this.traps["ERR"];
    if (h !== undefined && h !== "" && !this.inErrTrap) {
      this.inErrTrap = true;
      const saved = this.status;
      try {
        const cmd = parse(h);
        if (cmd !== null) await this.execute(cmd);
      } catch (e) {
        if (!(e instanceof ExitSignal || e instanceof ReturnSignal)) throw e;
        this.status = e.code;
        this.inErrTrap = false;
        throw e;
      }
      this.status = saved; // the failing command's status is preserved
      this.inErrTrap = false;
    }
    if (this.opts.errexit) throw new ExitSignal(this.status);
  }

  /** Called from AOT-generated per-command guards: a fatal arithmetic error
   *  aborts just that command with status 1 and the program continues, matching
   *  bash (and the interpreter's catch in `execute`). Non-arith errors re-throw. */
  arithAbort(e: unknown): void {
    if (!(e instanceof ArithError)) throw e;
    this.io.err(`${this.name}: ${e.message}\n`);
    this.status = 1;
  }

  private async dispatch(cmd: Command): Promise<number> {
    let status: number;
    switch (cmd.type) {
      case "connection":
        status = await this.execConnection(cmd.connector, cmd.first, cmd.second);
        break;
      case "simple":
        status = await this.execSimpleCore(cmd);
        break;
      case "pipeline": {
        const stages = cmd.stages;
        status = await this.pipeline(stages.map((c) => (sh: Shell) => sh.execute(c)));
        break;
      }
      case "background":
        status = this.background((sh) => sh.execute(cmd.command));
        break;
      case "function":
        this.defineFunction(cmd);
        status = 0;
        this.status = 0;
        break;
      case "group":
        status = await this.execute(cmd.body);
        break;
      case "subshell": {
        const body = cmd.body;
        status = await runBody(this.cloneForSubshell(), (sh) => sh.execute(body));
        this.status = status;
        await this.afterCommand();
        break;
      }
      case "if":
        status = await this.execIf(cmd);
        break;
      case "while":
        status = await this.execWhile(cmd);
        break;
      case "for":
        status = await this.execFor(cmd);
        break;
      case "select":
        status = await this.execSelect(cmd);
        break;
      case "arith_for":
        status = await this.execArithFor(cmd);
        break;
      case "arith":
        status = await this.arithCommand(cmd.expression);
        await this.afterCommand();
        break;
      case "case":
        status = await this.execCase(cmd);
        break;
      case "cond":
        this.condFatal = false;
        this.status = this.condStatus(await this.evalCond(cmd.expr));
        status = this.status;
        await this.afterCommand();
        break;
      case "array_assign": {
        // Assoc-ness of a standalone `name=( … )` isn't known statically, so
        // stay indexed here for interp/AOT parity (the emitter does the same);
        // the `declare -A name=( … )` form carries the flag and is handled below.
        this.readonlyHit = false;
        const fields = await expandArrayElems(this, cmd.elems, false);
        if (cmd.append) this.appendArrayFields(cmd.name, fields);
        else this.setArrayFields(cmd.name, fields);
        this.status = this.readonlyHit ? 1 : 0; // a readonly target fails the assignment
        status = this.status;
        break;
      }
      default: {
        const unhandled: never = cmd;
        throw new Error(`unhandled command type: ${String(unhandled)}`);
      }
    }
    return status;
  }

  private defineFunction(cmd: FunctionDef): void {
    const body = cmd.body;
    this.functions[cmd.name] = this.func(async (sh) => {
      await sh.execute(body);
    });
  }

  private async execConnection(connector: string, first: Command, second: Command): Promise<number> {
    if (connector === ";") {
      await this.execute(first);
      return this.execute(second);
    }
    if (connector === "&&") {
      this.condDepth++;
      let s: number;
      try {
        s = await this.execute(first);
      } finally {
        this.condDepth--;
      }
      return s === 0 ? this.execute(second) : s;
    }
    if (connector === "||") {
      this.condDepth++;
      let s: number;
      try {
        s = await this.execute(first);
      } finally {
        this.condDepth--;
      }
      return s !== 0 ? this.execute(second) : s;
    }
    throw new Error(`connector \`${connector}\` not supported yet`);
  }

  private async execSimpleCore(cmd: SimpleCommand): Promise<number> {
    const words = cmd.words;
    const assignWords: string[] = [];
    let k = 0;
    for (; k < words.length; k++) {
      if (ASSIGN.test(words[k]!.text)) assignWords.push(words[k]!.text);
      else break;
    }
    const rest = words.slice(k);

    if (rest.length === 0) {
      // A pure assignment's status is 0, unless a command sub in the RHS ran —
      // then it's that sub's status (bash) — or a readonly target rejected it.
      // Apply first so a RHS `$?` still sees the previous command's status.
      this.beginAssign();
      for (const wt of assignWords) await this.applyAssign(wt);
      this.endAssign();
      return this.status;
    }
    const subBefore = this.subCount;
    const argv = ASSIGN_BUILTINS.has(rest[0]!.text)
      ? await expandWordsAssign(this, rest)
      : await expandWords(this, rest);
    if (argv.length === 0) {
      // An empty command (every word expanded away) takes the status of the
      // last command substitution that ran during expansion, else 0 — but $?
      // stays visible to that expansion, so only reset when no sub ran.
      if (this.subCount === subBefore) this.status = 0;
      this.readonlyHit = false;
      for (const wt of assignWords) await this.applyAssign(wt);
      if (this.readonlyHit) this.status = 1;
      return this.status;
    }
    if (cmd.arrayArgs !== undefined) await this.applyArrayArgs(cmd.arrayArgs, argv);
    // `declare d=(…)` / `local a=(…)` with no other operands is just the array
    // assignment; don't fall through to the builtin's bare (no-arg) listing.
    if (cmd.arrayArgs !== undefined && cmd.arrayArgs.length > 0 && argv.length === 1) {
      this.status = 0;
      return 0;
    }
    if (this.opts.xtrace) this.io.err("+ " + argv.join(" ") + "\n");
    if (assignWords.length > 0) {
      const env: Record<string, string> = {};
      for (const wt of assignWords) {
        const m = ASSIGN.exec(wt)!;
        if (m[2] === undefined && m[4] === undefined) env[m[1]!] = await expandAssign(this, m[5]!);
      }
      return this.withEnv(env, () => this.callByName(argv[0]!, argv.slice(1)));
    }
    return this.callByName(argv[0]!, argv.slice(1));
  }

  /** Apply `declare -a arr=(...)` / `local m=(...)` array-literal arguments. */
  private async applyArrayArgs(args: ArrayArg[], argv: string[]): Promise<void> {
    const isLocal = argv[0] === "local";
    let isAssoc = false;
    const attrs: { integer?: boolean; lower?: boolean; upper?: boolean; readonly?: boolean } = {};
    let exported = false;
    for (const a of argv.slice(1)) {
      if (a.length > 1 && (a[0] === "-" || a[0] === "+")) {
        const on = a[0] === "-";
        for (const ch of a.slice(1)) {
          if (ch === "A") isAssoc = true;
          else if (ch === "i") attrs.integer = on;
          else if (ch === "l") attrs.lower = on;
          else if (ch === "u") attrs.upper = on;
          else if (ch === "r") attrs.readonly ||= on;
          else if (ch === "x") exported = exported || on;
        }
      }
    }
    for (const aa of args) {
      if (isLocal) this.local(aa.name);
      if (isAssoc) this.declareAssoc(aa.name);
      const fields = await expandArrayElems(this, aa.elems, isAssoc);
      if (aa.append) this.appendArrayFields(aa.name, fields);
      else this.setArrayFields(aa.name, fields);
      this.setAttrs(aa.name, attrs);
      if (exported) this.exportVar(aa.name);
    }
  }

  /** Apply an assignment word: `name=v`, `name+=v`, `name[i]=v`, `name[i]+=v`. */
  private async applyAssign(text: string): Promise<void> {
    const m = ASSIGN.exec(text)!;
    const name = m[1]!;
    const sub = m[3];
    const append = m[4] === "+";
    const value = await expandAssign(this, m[5]!);
    if (m[2] !== undefined) {
      const raw = sub ?? "";
      if (append) await this.elemSet(name, raw, ((await this.elemGet(name, raw)) ?? "") + value);
      else await this.elemSet(name, raw, value);
    } else if (append) {
      this.appendVar(name, value);
    } else {
      this.setVar(name, value);
    }
  }

  /** Run a command as a condition: exempt from errexit. */
  private async condition(cmd: Command): Promise<number> {
    this.condDepth++;
    try {
      return await this.execute(cmd);
    } finally {
      this.condDepth--;
    }
  }

  private async execIf(cmd: IfCommand): Promise<number> {
    if ((await this.condition(cmd.test)) === 0) return this.execute(cmd.consequent);
    if (cmd.alternate !== null) return this.execute(cmd.alternate);
    this.status = 0;
    return 0;
  }

  /** Run a loop body once, consuming this level's share of a break/continue N.
   *  Returns "break"/"continue" to act on here, or null to fall through. */
  private async loopStep(body: Command): Promise<"break" | "continue" | null> {
    try {
      await this.execute(body);
      return null;
    } catch (e) {
      if (e instanceof LoopSignal) {
        if (--e.count > 0) throw e; // outer loop's turn
        return e.kind;
      }
      throw e;
    }
  }

  private async execWhile(cmd: WhileCommand): Promise<number> {
    let last = 0;
    this.loopDepth++;
    try {
      for (;;) {
        // `break`/`continue` may appear in the condition itself (`while break`);
        // it acts on this loop like it would in the body.
        let s: number;
        try {
          s = await this.condition(cmd.test);
        } catch (e) {
          if (!(e instanceof LoopSignal)) throw e;
          if (--e.count > 0) throw e; // targets an enclosing loop
          if (e.kind === "break") break;
          continue; // `continue` re-tests the condition
        }
        if (cmd.until ? s === 0 : s !== 0) break;
        const sig = await this.loopStep(cmd.body);
        last = this.status;
        if (sig === "break") break;
      }
    } finally {
      this.loopDepth--;
    }
    this.status = last;
    return last;
  }

  private async execFor(cmd: ForCommand): Promise<number> {
    const items = await expandWords(this, cmd.words);
    let last = 0;
    this.loopDepth++;
    try {
      for (const item of items) {
        this.setVar(cmd.name, item);
        const sig = await this.loopStep(cmd.body);
        last = this.status;
        if (sig === "break") break;
      }
    } finally {
      this.loopDepth--;
    }
    this.status = last;
    return last;
  }

  private async evalCond(e: CondExpr): Promise<boolean> {
    switch (e.k) {
      case "and": return (await this.evalCond(e.l)) && (await this.evalCond(e.r));
      case "or": return (await this.evalCond(e.l)) || (await this.evalCond(e.r));
      case "not": return !(await this.evalCond(e.e));
      case "word": return (await expandNoSplit(this, e.w.text)) !== "";
      case "unary": return this.condUnary(e.op, await expandNoSplit(this, e.arg.text));
      case "binary": {
        const l = await expandNoSplit(this, e.l.text);
        // `=~`/`==`/`!=` keep the RHS unexpanded so its quoting stays literal.
        if (e.op === "=~") return this.condMatch(l, e.r.text);
        if (e.op === "==" || e.op === "=") return this.matchGlob(l, e.r.text, true);
        if (e.op === "!=") return !(await this.matchGlob(l, e.r.text, true));
        return this.condBinary(l, e.op, await expandNoSplit(this, e.r.text));
      }
    }
  }

  private async execCase(cmd: CaseCommand): Promise<number> {
    const subject = await expandNoSplit(this, cmd.word.text);
    this.status = 0;
    let falling = false;
    for (const clause of cmd.clauses) {
      let run = falling;
      if (!run) {
        for (const pat of clause.patterns) {
          if (await this.matchGlob(subject, pat.text)) {
            run = true;
            break;
          }
        }
      }
      if (!run) continue;
      if (clause.body) this.status = await this.execute(clause.body);
      if (clause.term === "break") return this.status;
      falling = clause.term === "fall"; // ";&" runs the next body, ";;&" resumes testing
    }
    return this.status;
  }

  private async execSelect(cmd: SelectCommand): Promise<number> {
    const items = await expandWords(this, cmd.words);
    await this.runSelect(cmd.name, items, (sh) => sh.execute(cmd.body));
    return this.status;
  }

  /** Read one line from stdin (like `read`), or null at EOF. */
  private readInputLine(): string | null {
    if (this.stdinData === null || this.stdinData === "") return null;
    const data = this.stdinData;
    const nl = data.indexOf("\n");
    const line = nl >= 0 ? data.slice(0, nl) : data;
    this.stdinData = nl >= 0 ? data.slice(nl + 1) : "";
    return line;
  }

  /** The `select` loop, shared by the interpreter and generated code. The menu
   *  and PS3 prompt go to stderr; REPLY holds the raw line, `name` the chosen
   *  item (empty for an out-of-range choice). Ends on EOF or `break`. */
  async runSelect(name: string, items: string[], runBody: (sh: Shell) => Promise<unknown>): Promise<void> {
    this.loopDepth++;
    let showMenu = true;
    try {
      for (;;) {
        if (showMenu) {
          for (let k = 0; k < items.length; k++) this.io.err(`${k + 1}) ${items[k]}\n`);
        }
        this.io.err(this.getVar("PS3") ?? "#? ");
        const line = this.readInputLine();
        if (line === null) {
          this.io.out("\n"); // bash emits a newline to stdout on EOF
          break;
        }
        this.setVar("REPLY", line);
        if (line.trim() === "") {
          showMenu = true;
          continue;
        }
        showMenu = false;
        const n = Number(line.trim());
        this.setVar(name, Number.isInteger(n) && n >= 1 && n <= items.length ? items[n - 1]! : "");
        try {
          await runBody(this);
        } catch (e) {
          if (e instanceof LoopSignal) {
            if (--e.count > 0) throw e;
            if (e.kind === "break") break;
            continue;
          }
          throw e;
        }
      }
    } finally {
      this.loopDepth--;
    }
  }

  private async execArithFor(cmd: ArithForCommand): Promise<number> {
    let last = 0;
    this.loopDepth++;
    try {
      await this.arithRun(cmd.init);
      for (;;) {
        if (!(await this.arithTest(cmd.test))) break;
        const sig = await this.loopStep(cmd.body);
        last = this.status;
        if (sig === "break") break;
        await this.arithRun(cmd.step);
      }
    } catch (e) {
      if (e instanceof LoopSignal || e instanceof ReturnSignal || e instanceof ExitSignal) throw e;
      this.io.err(`${this.name}: ((: ${errMsg(e)}\n`);
      this.status = 1;
      return 1;
    } finally {
      this.loopDepth--;
    }
    this.status = last;
    return last;
  }
}
