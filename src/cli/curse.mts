#!/usr/bin/env node
/* curse CLI — a bash-compatible entry point.
 *
 *   curse [opts] <file> [args...]     run a script  ($0=file, $1.. = args)
 *   curse [opts] -c <string> [name [args...]]   run a command string
 *   curse [opts] -s [args...]         read the program from stdin
 *   curse [opts]                      interactive REPL (tty) / read stdin (pipe)
 *   opts: -e -x -u -f -n -i -s, -o/+o <name>, -- (as in bash)
 *
 * Developer tooling (kept as leading subcommands):
 *   curse transpile <file> [-o out]   emit .mts (AOT)
 *   curse parse <file>                print the AST as JSON
 *   curse run <file> [args...]        run a script (alias of the bare form)
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createInterface } from "node:readline";
import { Shell } from "../runtime/shell.mts";
import { parse, ParseError } from "../parser/parser.mts";
import { CondError } from "../parser/cond.mts";
import { LexError } from "../parser/lexer.mts";
import { emit } from "../compiler/emit.mts";
import { transpileFile } from "./cache.mts";

/** Bash `set` options settable from the command line, and their short flags. */
const SHORT_OPT: Record<string, string> = {
  e: "errexit", x: "xtrace", u: "nounset", f: "noglob",
};
const LONG_OPTS = new Set(["errexit", "xtrace", "nounset", "pipefail", "noclobber", "noglob"]);
type OptSet = Array<[string, boolean]>;

const here = dirname(fileURLToPath(import.meta.url));
const runtimeSpecifier = pathToFileURL(join(here, "../runtime/shell.mts")).href;

const usage = (): void => {
  process.stderr.write(
    "usage:\n" +
      "  curse run <file>                  run a bash script\n" +
      "  curse -c <string>                 run a command string\n" +
      "  curse transpile <file> [-o out]   emit .mts (AOT)\n" +
      "  curse parse <file>                print the AST as JSON\n" +
      "  curse <file>                      same as: curse run <file>\n",
  );
};

const die = (msg: string): never => {
  process.stderr.write(`curse: ${msg}\n`);
  process.exit(2);
};

const readSource = (file: string | undefined): string => {
  if (file === undefined) die("missing file argument");
  try {
    // "-" means standard input (fd 0), matching the usual CLI convention.
    return readFileSync(file === "-" ? 0 : (file as string), "utf8");
  } catch {
    return die(`${file}: cannot read file`);
  }
};

const applyOpts = (sh: Shell, opts: OptSet): void => {
  for (const [name, on] of opts) {
    if (LONG_OPTS.has(name)) (sh.opts as Record<string, boolean>)[name] = on;
  }
};

const run = async (src: string, name: string, positional: string[] = [], opts: OptSet = []): Promise<void> => {
  const sh = new Shell();
  sh.name = name;
  sh.positional = positional;
  applyOpts(sh, opts);
  sh.status = await sh.runString(src);
  await sh.runExitTrap();
  process.exitCode = sh.status;
};

/** A `[[ ]]` / quote / heredoc that isn't closed yet — the REPL reads more. */
const needMore = (src: string): boolean => {
  try {
    parse(src);
    return false;
  } catch (e) {
    const m = e instanceof Error ? e.message : "";
    return /unterminated|<eof>|unexpected end/.test(m);
  }
};

/** Interactive read-eval-print loop (node:readline v1): one persistent Shell,
 *  multi-line continuation via re-parse, prompts on stderr like bash. */
const repl = async (opts: OptSet, positional: string[]): Promise<void> => {
  const sh = new Shell();
  applyOpts(sh, opts);
  sh.positional = positional;
  const tty = process.stdin.isTTY === true;
  const rl = createInterface({ input: process.stdin, output: process.stderr, terminal: tty });
  let buf = "";
  const reprompt = (): void => { rl.setPrompt(buf === "" ? "curse$ " : "> "); rl.prompt(); };
  rl.on("SIGINT", () => { buf = ""; process.stderr.write("\n"); reprompt(); });
  reprompt();
  for await (const line of rl) {
    buf = buf === "" ? line : buf + "\n" + line;
    if (buf.trim() !== "" && needMore(buf)) { reprompt(); continue; }
    if (buf.trim() !== "") {
      try {
        await sh.runString(buf);
        if (sh.exited) { rl.close(); await sh.runExitTrap(); process.exit(sh.status); }
      } catch (e) {
        process.stderr.write(`curse: ${e instanceof Error ? e.message : String(e)}\n`);
      }
    }
    buf = "";
    reprompt();
  }
  if (tty) process.stderr.write("\n");
  await sh.runExitTrap();
  process.exit(sh.status);
};

const main = async (): Promise<void> => {
  const argv = process.argv.slice(2);

  // Developer subcommands, recognized only as the first argument.
  if (argv[0] === "--help") { usage(); process.exit(0); }
  if (argv[0] === "parse") {
    process.stdout.write(JSON.stringify(parse(readSource(argv[1])), null, 2) + "\n");
    return;
  }
  if (argv[0] === "run") {
    const file = argv[1];
    await run(readSource(file), file ?? "curse", argv.slice(2));
    return;
  }
  if (argv[0] === "transpile") {
    const file = argv[1];
    const compile = (src: string): string => emit(parse(src), { runtimeSpecifier });
    const code = file !== undefined && file !== "-" && !argv.includes("--no-cache")
      ? transpileFile(file, runtimeSpecifier, compile)
      : compile(readSource(file));
    const oi = argv.indexOf("-o");
    if (oi >= 0 && argv[oi + 1] !== undefined) writeFileSync(argv[oi + 1]!, code);
    else process.stdout.write(code);
    return;
  }

  // Bash-compatible option parsing.
  const opts: OptSet = [];
  let i = 0;
  let cmdString: string | null = null;
  let wantStdin = false;
  let interactive = false;
  let noexec = false;
  while (i < argv.length) {
    const a = argv[i]!;
    if (a === "--" || a === "-") { i++; break; } // `-` is bash's obsolescent `--`
    if (a[0] !== "-" && a[0] !== "+") break; // first operand = script (or args)
    if (a === "-o" || a === "+o") {
      const nm = argv[i + 1];
      if (nm !== undefined && LONG_OPTS.has(nm)) opts.push([nm, a === "-o"]);
      i += 2;
      continue;
    }
    const on = a[0] === "-";
    let cmdMode = false;
    for (let k = 1; k < a.length; k++) {
      const c = a[k]!;
      if (c === "c" && on) cmdMode = true;
      else if (c === "s") wantStdin = true;
      else if (c === "i") interactive = true;
      else if (c === "n") noexec = true;
      else if (c === "h") { usage(); process.exit(0); }
      else if (c === "o") { const nm = argv[i + 1]; if (nm !== undefined && LONG_OPTS.has(nm)) { opts.push([nm, on]); i++; } }
      else if (c in SHORT_OPT) opts.push([SHORT_OPT[c]!, on]);
      // unknown flags are ignored (lenient)
    }
    i++;
    if (cmdMode) { cmdString = argv[i] ?? ""; i++; break; }
  }

  if (cmdString !== null) {
    // -c command [name [args...]]  → $0 = name, $1.. = args
    if (noexec) { parse(cmdString); return; }
    await run(cmdString, argv[i] ?? "curse", argv.slice(i + 1), opts);
    return;
  }

  const rest = argv.slice(i);
  if (!wantStdin && rest.length > 0) {
    // script file: $0 = file, $1.. = the rest
    const src = readSource(rest[0]);
    if (noexec) { parse(src); return; }
    await run(src, rest[0]!, rest.slice(1), opts);
    return;
  }

  // No script given: interactive REPL on a tty (or when forced with -i),
  // otherwise read the whole program from stdin.
  if (interactive || (!wantStdin && process.stdin.isTTY === true)) {
    await repl(opts, rest);
    return;
  }
  const src = readFileSync(0, "utf8");
  if (noexec) { parse(src); return; }
  await run(src, "curse", rest, opts);
};

// No top-level await, so the `./curse` shim can load this module with require().
main().catch((e: unknown) => {
  // A syntax error (lexer/parser/conditional) exits with status 2, as bash does.
  if (e instanceof ParseError || e instanceof CondError || e instanceof LexError) {
    process.stderr.write(`curse: ${e.message}\n`);
    process.exit(2);
  }
  throw e; // unexpected: let Node report it and exit non-zero
});
