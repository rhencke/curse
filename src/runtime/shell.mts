/* The bash runtime, in TypeScript. Holds shell state (variables, exit status,
 * cwd) and executes commands. Both the interpreter (`execute`, used by
 * `curse run` and — later — by `eval`/`source`) and the AOT-generated `.mts`
 * funnel through the same primitives, so their behaviour matches.
 *
 * M0: simple commands, `;` / `&&` / `||`, assignments, command substitution,
 * builtins, and external process spawning. */

import type { ArithForCommand, Command, ForCommand, IfCommand, WhileCommand } from "../ast/nodes.mts";
import { CMD_INVERT_RETURN, makeWord } from "../ast/nodes.mts";
import { parse } from "../parser/parser.mts";
import { expandNoSplit, expandWords } from "./expand.mts";
import { evalArith } from "./arith.mts";
import { builtins } from "./builtins.mts";
import { spawn } from "node:child_process";

const errMsg = (e: unknown): string => (e instanceof Error ? e.message : String(e));

export interface IO {
  out: (s: string) => void;
  err: (s: string) => void;
}

const defaultIO = (): IO => ({
  out: (s) => void process.stdout.write(s),
  err: (s) => void process.stderr.write(s),
});

const ASSIGN = /^([A-Za-z_][A-Za-z0-9_]*)=/;

export class Shell {
  vars = new Map<string, string>();
  exported = new Set<string>();
  status = 0;
  cwd = process.cwd();
  name = "curse";
  io: IO;

  constructor(io?: IO) {
    this.io = io ?? defaultIO();
  }

  getVar(name: string): string | undefined {
    const v = this.vars.get(name);
    if (v !== undefined) return v;
    return process.env[name];
  }

  setVar(name: string, value: string): void {
    this.vars.set(name, value);
  }

  markExport(name: string): void {
    this.exported.add(name);
  }

  unset(name: string): void {
    this.vars.delete(name);
    this.exported.delete(name);
  }

  private childEnv(extra: Record<string, string>): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env };
    for (const n of this.exported) {
      const v = this.vars.get(n);
      if (v !== undefined) env[n] = v;
    }
    return { ...env, ...extra };
  }

  /** Execute a parsed command tree, returning its exit status. */
  async execute(cmd: Command): Promise<number> {
    let status: number;
    switch (cmd.type) {
      case "connection":
        status = await this.execConnection(cmd.connector, cmd.first, cmd.second);
        break;
      case "simple":
        status = await this.simpleRaw(cmd.words.map((w) => w.text));
        break;
      case "group":
        status = await this.execute(cmd.body);
        break;
      case "subshell":
        status = await this.execSubshell(cmd.body);
        break;
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
      default:
        throw new Error(`command type \`${cmd.type}\` not supported yet`);
    }

    if (cmd.flags !== undefined && (cmd.flags & CMD_INVERT_RETURN) !== 0) {
      status = status === 0 ? 1 : 0;
      this.status = status;
    }
    return status;
  }

  private async execConnection(
    connector: string,
    first: Command,
    second: Command,
  ): Promise<number> {
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

  private async execSubshell(body: Command): Promise<number> {
    const sub = this.cloneForSubshell();
    const s = await sub.execute(body);
    this.status = s;
    return s;
  }

  private cloneForSubshell(): Shell {
    const sub = new Shell(this.io);
    sub.vars = new Map(this.vars);
    sub.exported = new Set(this.exported);
    sub.cwd = this.cwd;
    sub.name = this.name;
    sub.status = this.status;
    return sub;
  }

  /* ---- arithmetic entry points (shared with generated code) ---- */

  private async arithValue(expr: string): Promise<bigint> {
    return evalArith(this, await expandNoSplit(this, expr));
  }

  /** `(( expr ))` command: status 0 if the value is non-zero, else 1. */
  async arithCommand(expr: string): Promise<number> {
    try {
      this.status = (await this.arithValue(expr)) !== 0n ? 0 : 1;
    } catch (e) {
      this.io.err(`${this.name}: ((: ${expr}: ${errMsg(e)}\n`);
      this.status = 1;
    }
    return this.status;
  }

  /** Evaluate for side effects (arith-for init/step); empty is a no-op. */
  async arithRun(expr: string): Promise<void> {
    if (expr !== "") await this.arithValue(expr);
  }

  /** Arith-for test: an empty test is always true. */
  async arithTest(expr: string): Promise<boolean> {
    if (expr === "") return true;
    return (await this.arithValue(expr)) !== 0n;
  }

  /** Expand a word list to fields (used by generated `for` loops). */
  async expandList(rawWords: string[]): Promise<string[]> {
    return expandWords(this, rawWords.map((t) => makeWord(t)));
  }

  /** Run a body in a subshell (used by generated subshells). */
  async runSubshell(fn: (sh: Shell) => Promise<void>): Promise<number> {
    const sub = this.cloneForSubshell();
    await fn(sub);
    this.status = sub.status;
    return sub.status;
  }

  /** Apply `!` inversion in generated code. */
  invert(): void {
    this.status = this.status === 0 ? 1 : 0;
  }

  /** Execute a simple command given the raw (unexpanded) word texts. This is the
   *  single entry point shared by the interpreter and the AOT-generated code. */
  async simpleRaw(rawWords: string[]): Promise<number> {
    // Separate leading assignments (name=value) from the command + arguments.
    const assigns: Array<[string, string]> = [];
    let k = 0;
    while (k < rawWords.length) {
      const w = rawWords[k]!;
      const m = ASSIGN.exec(w);
      if (!m) break;
      assigns.push([m[1]!, w.slice(m[0].length)]);
      k++;
    }
    const rest = rawWords.slice(k);

    if (rest.length === 0) {
      // Assignment-only command: apply to the shell, no command run.
      for (const [n, rhs] of assigns) this.setVar(n, await expandNoSplit(this, rhs));
      this.status = 0;
      return 0;
    }

    const argv = await expandWords(this, rest.map((t) => makeWord(t)));
    if (argv.length === 0) {
      for (const [n, rhs] of assigns) this.setVar(n, await expandNoSplit(this, rhs));
      this.status = 0;
      return 0;
    }

    const extraEnv: Record<string, string> = {};
    for (const [n, rhs] of assigns) extraEnv[n] = await expandNoSplit(this, rhs);

    const name = argv[0]!;
    const bi = builtins[name];
    let status: number;
    if (bi) {
      // Assignment prefix is visible to the builtin, then restored.
      const saved: Array<[string, string | undefined]> = [];
      for (const [n, v] of Object.entries(extraEnv)) {
        saved.push([n, this.vars.get(n)]);
        this.vars.set(n, v);
      }
      try {
        status = await bi(argv, this);
      } finally {
        for (const [n, old] of saved) {
          if (old === undefined) this.vars.delete(n);
          else this.vars.set(n, old);
        }
      }
    } else {
      status = await this.spawnExternal(argv, extraEnv);
    }

    this.status = status;
    return status;
  }

  private spawnExternal(argv: string[], extraEnv: Record<string, string>): Promise<number> {
    const name = argv[0]!;
    return new Promise<number>((resolvePromise) => {
      let settled = false;
      const done = (code: number): void => {
        if (!settled) {
          settled = true;
          resolvePromise(code);
        }
      };

      const child = spawn(name, argv.slice(1), {
        cwd: this.cwd,
        env: this.childEnv(extraEnv),
        stdio: ["inherit", "pipe", "pipe"],
      });

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

      child.on("close", (code, signal) => {
        if (signal) done(128 + 1);
        else done(code ?? 0);
      });
    });
  }

  /** Parse and execute a source string (used by `curse run`, and later `eval`). */
  async runString(src: string): Promise<number> {
    const cmd = parse(src);
    if (cmd === null) {
      this.status = 0;
      return 0;
    }
    return this.execute(cmd);
  }

  /** Run source in a capturing subshell for `$(...)`; returns stdout with
   *  trailing newlines stripped. Variable changes do not leak out (subshell). */
  async runCommandSub(src: string): Promise<string> {
    const chunks: string[] = [];
    const sub = new Shell({
      out: (s) => void chunks.push(s),
      err: (s) => this.io.err(s),
    });
    sub.vars = new Map(this.vars);
    sub.exported = new Set(this.exported);
    sub.cwd = this.cwd;
    sub.name = this.name;
    await sub.runString(src);
    this.status = sub.status;
    return chunks.join("").replace(/\n+$/, "");
  }
}
