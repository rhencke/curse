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
  ArithForCommand, CaseCommand, Command, CondCommand, CondExpr, ForCommand,
  FunctionDef, IfCommand, Redirect, SimpleCommand, WhileCommand, Word,
} from "../ast/nodes.mts";
import { CMD_INVERT_RETURN } from "../ast/nodes.mts";
import { parse } from "../parser/parser.mts";
import { expandNoSplit, expandWords, splitTaggedFields } from "./expand.mts";
import { evalArith } from "./arith.mts";
import { globMatch } from "./glob.mts";
import {
  replaceGlob as pReplaceGlob, substr as pSubstr, trimPrefix as pTrimPrefix, trimSuffix as pTrimSuffix,
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

const errMsg = (e: unknown): string => (e instanceof Error ? e.message : String(e));

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
      owner[name]!.value = s;
    } else {
      this.globalScope[name] = new Var(s, process.env[name] !== undefined);
    }
  }

  getVar(name: string): string | undefined {
    return this.lookup(name)?.value;
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
          flat[k] = new Var(v.value, v.exported);
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
    return sub;
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
      case "=~":
        try {
          return new RegExp(r).test(l);
        } catch {
          return false;
        }
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

  /** Apply `!` inversion in generated code. */
  invert(): void {
    this.status = this.status === 0 ? 1 : 0;
  }

  /** Run a pipeline: each stage in its own subshell, stdout wired to the next
   *  stage's stdin (buffered). The pipeline's status is the last stage's. */
  async pipeline(stages: Array<(sh: Shell) => Promise<unknown>>): Promise<number> {
    let input = this.stdinData;
    let status = 0;
    for (let idx = 0; idx < stages.length; idx++) {
      const isLast = idx === stages.length - 1;
      const chunks: string[] = [];
      const io: IO = isLast ? this.io : { out: (s) => void chunks.push(s), err: (s) => this.io.err(s) };
      const sub = this.cloneForSubshell(io);
      sub.stdinData = input;
      status = await runBody(sub, stages[idx]!);
      if (!isLast) input = chunks.join("");
    }
    this.status = status;
    return status;
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
    let status: number;
    if (cmd.redirects !== undefined && cmd.redirects.length > 0) {
      const reds: RedirIO[] = [];
      for (const r of cmd.redirects) {
        reds.push({ op: r.op, fd: r.fd, target: await expandNoSplit(this, r.target.text) });
      }
      status = await this.withRedirects(reds, () => this.dispatch(cmd));
    } else {
      status = await this.dispatch(cmd);
    }
    if (cmd.flags !== undefined && (cmd.flags & CMD_INVERT_RETURN) !== 0) {
      status = status === 0 ? 1 : 0;
      this.status = status;
    }
    return status;
  }

  private async dispatch(cmd: Command): Promise<number> {
    let status: number;
    switch (cmd.type) {
      case "connection":
        status = await this.execConnection(cmd.connector, cmd.first, cmd.second);
        break;
      case "simple":
        status = await this.execSimpleCore(cmd.words);
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
      const s = await this.execute(first);
      return s === 0 ? this.execute(second) : s;
    }
    if (connector === "||") {
      const s = await this.execute(first);
      return s !== 0 ? this.execute(second) : s;
    }
    throw new Error(`connector \`${connector}\` not supported yet`);
  }

  private async execSimpleCore(words: Word[]): Promise<number> {
    const assigns: Array<[string, string]> = [];
    let k = 0;
    for (; k < words.length; k++) {
      const m = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(words[k]!.text);
      if (!m) break;
      assigns.push([m[1]!, await expandNoSplit(this, words[k]!.text.slice(m[0].length))]);
    }
    const rest = words.slice(k);
    if (rest.length === 0) {
      for (const [n, v] of assigns) this.setVar(n, v);
      this.status = 0;
      return 0;
    }
    const argv = await expandWords(this, rest);
    if (argv.length === 0) {
      for (const [n, v] of assigns) this.setVar(n, v);
      this.status = 0;
      return 0;
    }
    if (assigns.length > 0) {
      const env: Record<string, string> = {};
      for (const [n, v] of assigns) env[n] = v;
      return this.withEnv(env, () => this.callByName(argv[0]!, argv.slice(1)));
    }
    return this.callByName(argv[0]!, argv.slice(1));
  }

  private async execIf(cmd: IfCommand): Promise<number> {
    if ((await this.execute(cmd.test)) === 0) return this.execute(cmd.consequent);
    if (cmd.alternate !== null) return this.execute(cmd.alternate);
    this.status = 0;
    return 0;
  }

  private async execWhile(cmd: WhileCommand): Promise<number> {
    let last = 0;
    for (;;) {
      const s = await this.execute(cmd.test);
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
        return this.condBinary(
          await expandNoSplit(this, e.l.text),
          e.op,
          await expandNoSplit(this, e.r.text),
        );
    }
  }

  private async execCase(cmd: CaseCommand): Promise<number> {
    const subject = await expandNoSplit(this, cmd.word.text);
    for (const clause of cmd.clauses) {
      for (const pat of clause.patterns) {
        if (globMatch(subject, await expandNoSplit(this, pat.text))) {
          this.status = clause.body ? await this.execute(clause.body) : 0;
          return this.status;
        }
      }
    }
    this.status = 0;
    return 0;
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
