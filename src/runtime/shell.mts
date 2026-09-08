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
  FunctionDef, IfCommand, Redirect, SimpleCommand, WhileCommand, Word,
} from "../ast/nodes.mts";
import { CMD_INVERT_RETURN } from "../ast/nodes.mts";
import { parse } from "../parser/parser.mts";
import { parseHeredoc } from "../parser/word.mts";
import { expandNoSplit, expandParsed, expandWords, splitTaggedFields } from "./expand.mts";
import { evalArith } from "./arith.mts";
import { globExpand, globMatch, hasGlobMeta } from "./glob.mts";
import {
  replaceGlob as pReplaceGlob, sliceArr as pSliceArr, substr as pSubstr,
  trimPrefix as pTrimPrefix, trimSuffix as pTrimSuffix,
} from "./param.mts";
import { builtins } from "./builtins.mts";
import { ExitSignal, ReturnSignal, Var } from "./types.mts";
import type { IO } from "./types.mts";
import { spawn } from "node:child_process";
import {
  accessSync, closeSync, constants, lstatSync, openSync, readFileSync, statSync, writeSync,
} from "node:fs";
import { resolve } from "node:path";

export type { IO } from "./types.mts";
export { ExitSignal, ReturnSignal, Var } from "./types.mts";

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

const errMsg = (e: unknown): string => (e instanceof Error ? e.message : String(e));

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
    else throw e;
  }
  return sub.status;
};

type Scope = Record<string, Var>;
type BashFunc = { __bashFunc: (sh: Shell) => Promise<void> };

export class Shell {
  io: IO;
  status = 0;
  name = "curse";
  cwd = process.cwd();
  positional: string[] = [];
  /** Redirected stdin for this command (file contents / here-string), or null
   *  to inherit. Read by the `read` builtin and passed to external stdin. */
  stdinData: string | null = null;

  /** Background jobs and `$!`. */
  lastBgPid = 0;
  private jobs: Array<{ pid: number; promise: Promise<number> }> = [];
  private nextPid = 10000;

  /** `set` options. */
  opts = { errexit: false, nounset: false, xtrace: false, pipefail: false };
  /** Depth of errexit-suppressed contexts (conditions, `!`, `&&`/`||` non-final). */
  condDepth = 0;

  private globalScope: Scope = Object.create(null) as Scope;
  private scope: Scope = this.globalScope;
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
  }

  get pid(): number {
    return process.pid;
  }

  /* ---------------- variables / scope ---------------- */

  private lookup(name: string): Var | undefined {
    let s: Scope | null = this.scope;
    while (s !== null) {
      if (Object.prototype.hasOwnProperty.call(s, name)) return s[name];
      s = Object.getPrototypeOf(s) as Scope | null;
    }
    const e = process.env[name];
    return e === undefined ? undefined : new Var(e, true);
  }

  private ownerScope(name: string): Scope | undefined {
    let s: Scope | null = this.scope;
    while (s !== null) {
      if (Object.prototype.hasOwnProperty.call(s, name)) return s;
      s = Object.getPrototypeOf(s) as Scope | null;
    }
    return undefined;
  }

  private assign(name: string, value: unknown): void {
    if (value instanceof Var) {
      this.scope[name] = value;
      return;
    }
    const s = String(value);
    const owner = this.ownerScope(name);
    if (owner) {
      const v = owner[name]!;
      if (v.assoc !== null) v.assoc.set("0", s);
      else if (v.arr !== null) v.arr.set(0, s);
      else v.value = s;
    } else {
      this.globalScope[name] = new Var(s, process.env[name] !== undefined);
    }
  }

  getVar(name: string): string | undefined {
    return this.lookup(name)?.scalar();
  }

  /* ---- indexed arrays ---- */

  private varForWrite(name: string): Var {
    const owner = this.ownerScope(name);
    if (owner) return owner[name]!;
    const v = new Var("", process.env[name] !== undefined);
    this.globalScope[name] = v;
    return v;
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
    values.forEach((val, i) => v.arr!.set(i, val));
  }
  setElem(name: string, index: number, value: string): void {
    const arr = this.toArray(this.varForWrite(name));
    const i = index < 0 ? this.maxIndex(this.varForWrite(name)) + 1 + index : index;
    arr.set(i < 0 ? 0 : i, value);
  }
  appendArray(name: string, values: string[]): void {
    const v = this.varForWrite(name);
    const arr = this.toArray(v);
    let next = this.maxIndex(v) + 1;
    for (const val of values) arr.set(next++, val);
  }
  arrayGet(name: string, index: number): string | undefined {
    const v = this.lookup(name);
    if (!v) return undefined;
    if (v.arr === null) return index === 0 ? v.value : undefined;
    return v.arr.get(index < 0 ? this.maxIndex(v) + 1 + index : index);
  }
  arrayValues(name: string): string[] {
    const v = this.lookup(name);
    if (!v) return [];
    if (v.assoc !== null) return [...v.assoc.values()];
    if (v.arr === null) return [v.value];
    return [...v.arr.entries()].sort((a, b) => a[0] - b[0]).map((e) => e[1]);
  }
  arrayIndices(name: string): string[] {
    const v = this.lookup(name);
    if (!v) return [];
    if (v.assoc !== null) return [...v.assoc.keys()];
    if (v.arr === null) return ["0"];
    return [...v.arr.keys()].sort((a, b) => a - b).map(String);
  }
  arrayLen(name: string): number {
    const v = this.lookup(name);
    if (!v) return 0;
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
    const v = this.varForWrite(name);
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
    const v = this.varForWrite(name);
    if (v.assoc !== null) {
      this.fillAssoc(v.assoc, fields);
      return;
    }
    this.fillArray(this.toArray(v), fields, this.maxIndex(v) + 1);
  }
  private fillAssoc(assoc: Map<string, string>, fields: string[]): void {
    for (const f of fields) {
      const m = /^\[([\s\S]*?)\]=([\s\S]*)$/.exec(f);
      if (m) assoc.set(m[1]!, m[2]!);
    }
  }

  /** `${x:?msg}` / `${x?msg}`: report the error and exit. */
  paramError(name: string, msg: string): never {
    this.io.err(`${this.name}: ${name}: ${msg === "" ? "parameter null or not set" : msg}\n`);
    throw new ExitSignal(1);
  }

  /** `${!name}`: the value of the variable named by `$name`. */
  indirect(name: string): string {
    return this.getVar(this.getVar(name) ?? "") ?? "";
  }

  /** Read a plain `$name` reference, honoring `set -u` (used by generated code). */
  ref(name: string): string {
    const v = this.lookup(name);
    if (v === undefined) {
      if (this.opts.nounset) {
        this.io.err(`${this.name}: ${name}: unbound variable\n`);
        throw new ExitSignal(1);
      }
      return "";
    }
    return v.scalar();
  }
  setVar(name: string, value: string): void {
    this.assign(name, value);
  }
  unsetVar(name: string): void {
    const owner = this.ownerScope(name);
    if (owner) delete owner[name];
  }
  local(name: string, value?: string): void {
    this.scope[name] = new Var(value ?? "");
  }
  exportVar(name: string): void {
    const owner = this.ownerScope(name);
    if (owner) owner[name]!.exported = true;
    else this.globalScope[name] = new Var(process.env[name] ?? "", true);
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
      for (const k of Object.getOwnPropertyNames(s)) {
        if (!seen.has(k)) {
          seen.add(k);
          const v = s[k]!;
          if (v.exported) env[k] = v.value;
        }
      }
      s = Object.getPrototypeOf(s) as Scope | null;
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
    return splitTaggedFields(chars, sp, anchored);
  }

  /** Command substitution (compiled): run body capturing stdout. */
  async sub(fn: (sh: Shell) => Promise<void>): Promise<string> {
    const chunks: string[] = [];
    const subsh = this.cloneForSubshell({ out: (s) => void chunks.push(s), err: (s) => this.io.err(s) });
    this.status = await runBody(subsh, fn);
    return chunks.join("").replace(/\n+$/, "");
  }

  /** Command substitution (interpreter): parse + run a source string. */
  async subSrc(src: string): Promise<string> {
    return this.sub(async (sh) => {
      await sh.runString(src);
    });
  }

  /* ---------------- arithmetic (shared with generated code) ---------------- */

  private async arithValue(expr: string): Promise<bigint> {
    return evalArith(this, await expandNoSplit(this, expr));
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
      this.io.err(`${this.name}: ((: ${expr}: ${errMsg(e)}\n`);
      this.status = 1;
    }
    return this.status;
  }
  async arithRun(expr: string): Promise<void> {
    if (expr !== "") await this.arithValue(expr);
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
    this.scope = Object.create(savedScope) as Scope;
    this.positional = args;
    try {
      await body(this);
    } catch (e) {
      if (e instanceof ReturnSignal) this.status = e.code;
      else throw e;
    } finally {
      this.scope = savedScope;
      this.positional = savedPos;
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
    this.checkErrexit();
    return code;
  }

  /** Dispatch when the command name itself came from an expansion. */
  async exec(...fields: string[]): Promise<number> {
    if (fields.length === 0) {
      this.status = 0;
      return 0;
    }
    return this.callByName(fields[0]!, fields.slice(1));
  }

  /** Run `fn` with temporary (exported) assignments, e.g. `FOO=bar cmd`. */
  async withEnv(assignments: Record<string, string>, fn: () => Promise<number>): Promise<number> {
    const saved: Array<[string, Var | undefined]> = [];
    for (const [k, v] of Object.entries(assignments)) {
      saved.push([k, Object.prototype.hasOwnProperty.call(this.scope, k) ? this.scope[k] : undefined]);
      this.scope[k] = new Var(v, true);
    }
    try {
      return await fn();
    } finally {
      for (const [k, prev] of saved) {
        if (prev === undefined) delete this.scope[k];
        else this.scope[k] = prev;
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
        this.applyRedirect(r, r.target, writers, toClose);
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

  private applyRedirect(
    r: RedirIO,
    target: string,
    writers: Record<number, (s: string) => void>,
    toClose: number[],
  ): void {
    const openFile = (flags: string): ((s: string) => void) => {
      const fd = openSync(resolve(this.cwd, target), flags);
      toClose.push(fd);
      return (s: string) => void writeSync(fd, s);
    };
    switch (r.op) {
      case ">": case ">|": writers[r.fd] = openFile("w"); break;
      case ">>": writers[r.fd] = openFile("a"); break;
      case "&>": { const w = openFile("w"); writers[1] = w; writers[2] = w; break; }
      case "&>>": { const w = openFile("a"); writers[1] = w; writers[2] = w; break; }
      case "<": this.stdinData = readFileSync(resolve(this.cwd, target), "utf8"); break;
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
  }

  private external(name: string, args: string[], extraEnv: Record<string, string>): Promise<number> {
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
    const flat: Scope = Object.create(null) as Scope;
    const seen = new Set<string>();
    let s: Scope | null = this.scope;
    while (s !== null) {
      for (const k of Object.getOwnPropertyNames(s)) {
        if (!seen.has(k)) {
          seen.add(k);
          const v = s[k]!;
          const nv = new Var(v.value, v.exported);
          if (v.arr !== null) nv.arr = new Map(v.arr);
          if (v.assoc !== null) nv.assoc = new Map(v.assoc);
          flat[k] = nv;
        }
      }
      s = Object.getPrototypeOf(s) as Scope | null;
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
    sub.opts = { ...this.opts };
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
    const out: string[] = [];
    for (const f of fields) {
      if (hasGlobMeta(f)) {
        const m = globExpand(this.cwd, f);
        if (m.length > 0) out.push(...m);
        else out.push(f);
      } else {
        out.push(f);
      }
    }
    return out;
  }

  /** Pattern match (used by generated `case` / `[[ == ]]` with dynamic patterns). */
  match(subject: string, pattern: string): boolean {
    return globMatch(subject, pattern);
  }

  /** Whether a variable is set (used by generated `${x-…}` / `${x+…}`). */
  has(name: string): boolean {
    return this.lookup(name) !== undefined;
  }

  /* Parameter-expansion string ops (used by generated code). */
  trimPrefix(v: string, pat: string, longest: boolean): string {
    return pTrimPrefix(v, pat, longest);
  }
  trimSuffix(v: string, pat: string, longest: boolean): string {
    return pTrimSuffix(v, pat, longest);
  }
  replaceGlob(v: string, pat: string, repl: string, all: boolean, anchor: string): string {
    return pReplaceGlob(v, pat, repl, all, anchor);
  }
  async substr(v: string, offExpr: string, lenExpr: string): Promise<string> {
    const off = Number(await this.arithValue(offExpr));
    const len = lenExpr === "" ? undefined : Number(await this.arithValue(lenExpr));
    return pSubstr(v, off, len);
  }
  private async doSlice(list: string[], offExpr: string, lenExpr: string): Promise<string[]> {
    const off = Number(await this.arithValue(offExpr));
    const len = lenExpr === "" ? undefined : Number(await this.arithValue(lenExpr));
    return pSliceArr(list, off, len);
  }
  /** `${arr[@]:offset:length}` — slice an array's values. */
  async sliceArr(name: string, offExpr: string, lenExpr: string): Promise<string[]> {
    return this.doSlice(this.arrayValues(name), offExpr, lenExpr);
  }
  /** `${@:offset:length}` — slice the positional params ([$0, $1, …]). */
  async slicePos(offExpr: string, lenExpr: string): Promise<string[]> {
    return this.doSlice([this.name, ...this.positional], offExpr, lenExpr);
  }

  /** `[[ ]]` unary test (used by generated code and the interpreter). */
  condUnary(op: string, arg: string): boolean {
    if (op === "-z") return arg.length === 0;
    if (op === "-n") return arg.length > 0;
    if (op === "-v") return this.lookup(arg) !== undefined;
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
      case "==": case "=": return globMatch(l, r);
      case "!=": return !globMatch(l, r);
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
      this.status = 2;
      return false;
    }
    const m = re.exec(subject);
    this.setArray("BASH_REMATCH", m === null ? [] : Array.from(m, (g) => g ?? ""));
    return m !== null;
  }

  /** Build a JS regex source from a `[[ =~ ]]` RHS word. */
  private async condRegex(raw: string): Promise<string> {
    const esc = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    let src = "";
    let i = 0;
    while (i < raw.length) {
      const c = raw[i]!;
      if (c === "\\") {
        const n = raw[i + 1];
        if (n === undefined) { src += "\\\\"; i++; } else { src += esc(n); i += 2; }
        continue;
      }
      if (c === "'") {
        i++;
        while (i < raw.length && raw[i] !== "'") { src += esc(raw[i]!); i++; }
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
        src += esc(await expandNoSplit(this, seg));
        continue;
      }
      if (c === "$") {
        const end = expansionEnd(raw, i);
        if (end > i) { src += await expandNoSplit(this, raw.slice(i, end)); i = end; continue; }
      }
      src += c;
      i++;
    }
    return src;
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
    for (let idx = 0; idx < stages.length; idx++) {
      const isLast = idx === stages.length - 1;
      const chunks: string[] = [];
      const io: IO = isLast ? this.io : { out: (s) => void chunks.push(s), err: (s) => this.io.err(s) };
      const sub = this.cloneForSubshell(io);
      sub.stdinData = input;
      status = await runBody(sub, stages[idx]!);
      if (status !== 0) lastNonZero = status;
      if (!isLast) input = chunks.join("");
    }
    this.status = this.opts.pipefail ? lastNonZero : status;
    this.checkErrexit();
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

  async runString(src: string): Promise<number> {
    const cmd = parse(src);
    if (cmd === null) {
      this.status = 0;
      return 0;
    }
    try {
      return await this.execute(cmd);
    } catch (e) {
      if (e instanceof ReturnSignal || e instanceof ExitSignal) {
        this.status = e.code;
        return e.code;
      }
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
  private checkErrexit(): void {
    if (this.opts.errexit && this.status !== 0 && this.condDepth === 0) {
      throw new ExitSignal(this.status);
    }
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
      case "arith_for":
        status = await this.execArithFor(cmd);
        break;
      case "arith":
        status = await this.arithCommand(cmd.expression);
        break;
      case "case":
        status = await this.execCase(cmd);
        break;
      case "cond":
        this.status = (await this.evalCond(cmd.expr)) ? 0 : 1;
        status = this.status;
        break;
      case "array_assign": {
        const fields = await expandWords(this, cmd.elems);
        if (cmd.append) this.appendArrayFields(cmd.name, fields);
        else this.setArrayFields(cmd.name, fields);
        this.status = 0;
        status = 0;
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
      for (const wt of assignWords) await this.applyAssign(wt);
      this.status = 0;
      return 0;
    }
    const argv = await expandWords(this, rest);
    if (argv.length === 0) {
      for (const wt of assignWords) await this.applyAssign(wt);
      this.status = 0;
      return 0;
    }
    if (cmd.arrayArgs !== undefined) await this.applyArrayArgs(cmd.arrayArgs, argv);
    if (this.opts.xtrace) this.io.err("+ " + argv.join(" ") + "\n");
    if (assignWords.length > 0) {
      const env: Record<string, string> = {};
      for (const wt of assignWords) {
        const m = ASSIGN.exec(wt)!;
        if (m[2] === undefined && m[4] === undefined) env[m[1]!] = await expandNoSplit(this, m[5]!);
      }
      return this.withEnv(env, () => this.callByName(argv[0]!, argv.slice(1)));
    }
    return this.callByName(argv[0]!, argv.slice(1));
  }

  /** Apply `declare -a arr=(...)` / `local m=(...)` array-literal arguments. */
  private async applyArrayArgs(args: ArrayArg[], argv: string[]): Promise<void> {
    const isLocal = argv[0] === "local";
    const isAssoc = argv.includes("-A");
    for (const aa of args) {
      if (isLocal) this.local(aa.name);
      if (isAssoc) this.declareAssoc(aa.name);
      const fields = await expandWords(this, aa.elems);
      if (aa.append) this.appendArrayFields(aa.name, fields);
      else this.setArrayFields(aa.name, fields);
    }
  }

  /** Apply an assignment word: `name=v`, `name+=v`, `name[i]=v`, `name[i]+=v`. */
  private async applyAssign(text: string): Promise<void> {
    const m = ASSIGN.exec(text)!;
    const name = m[1]!;
    const sub = m[3];
    const append = m[4] === "+";
    const value = await expandNoSplit(this, m[5]!);
    if (m[2] !== undefined) {
      const raw = sub ?? "";
      if (append) await this.elemSet(name, raw, ((await this.elemGet(name, raw)) ?? "") + value);
      else await this.elemSet(name, raw, value);
    } else if (append) {
      this.setVar(name, (this.getVar(name) ?? "") + value);
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

  private async execWhile(cmd: WhileCommand): Promise<number> {
    let last = 0;
    for (;;) {
      const s = await this.condition(cmd.test);
      if (cmd.until ? s === 0 : s !== 0) break;
      last = await this.execute(cmd.body);
    }
    this.status = last;
    return last;
  }

  private async execFor(cmd: ForCommand): Promise<number> {
    const items = await expandWords(this, cmd.words);
    let last = 0;
    for (const item of items) {
      this.setVar(cmd.name, item);
      last = await this.execute(cmd.body);
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
      case "binary":
        // `=~` keeps its RHS unexpanded: quoting there is regex-literal, and
        // the match populates BASH_REMATCH.
        if (e.op === "=~") return this.condMatch(await expandNoSplit(this, e.l.text), e.r.text);
        return this.condBinary(
          await expandNoSplit(this, e.l.text),
          e.op,
          await expandNoSplit(this, e.r.text),
        );
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
          if (globMatch(subject, await expandNoSplit(this, pat.text))) {
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

  private async execArithFor(cmd: ArithForCommand): Promise<number> {
    let last = 0;
    try {
      await this.arithRun(cmd.init);
      for (;;) {
        if (!(await this.arithTest(cmd.test))) break;
        last = await this.execute(cmd.body);
        await this.arithRun(cmd.step);
      }
    } catch (e) {
      this.io.err(`${this.name}: ((: ${errMsg(e)}\n`);
      this.status = 1;
      return 1;
    }
    this.status = last;
    return last;
  }
}
