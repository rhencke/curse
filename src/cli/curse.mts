#!/usr/bin/env node
/* curse CLI.
 *
 *   curse run <file>                    run a bash script (interpreter)
 *   curse -c <string>                   run a command string
 *   curse transpile <file> [-o out]     emit .mts (AOT)
 *   curse parse <file>                  print the AST as JSON
 *   curse <file>                        same as `curse run <file>`
 */

import { readFileSync, writeFileSync } from "node:fs";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Shell } from "../runtime/shell.mts";
import { parse } from "../parser/parser.mts";
import { emit } from "../compiler/emit.mts";

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
    return readFileSync(file as string, "utf8");
  } catch {
    return die(`${file}: cannot read file`);
  }
};

const run = async (src: string, name: string, positional: string[] = []): Promise<void> => {
  const sh = new Shell();
  sh.name = name;
  sh.positional = positional;
  sh.status = await sh.runString(src);
  await sh.runExitTrap();
  process.exitCode = sh.status;
};

const main = async (): Promise<void> => {
  const args = process.argv.slice(2);
  const sub = args[0];

  if (sub === undefined || sub === "-h" || sub === "--help") {
    usage();
    process.exit(sub === undefined ? 2 : 0);
  }

  if (sub === "-c") {
    await run(args[1] ?? "", args[2] ?? "curse", args.slice(3));
    return;
  }

  if (sub === "run") {
    const file = args[1];
    await run(readSource(file), file ?? "curse", args.slice(2));
    return;
  }

  if (sub === "parse") {
    const cmd = parse(readSource(args[1]));
    process.stdout.write(JSON.stringify(cmd, null, 2) + "\n");
    return;
  }

  if (sub === "transpile") {
    const file = args[1];
    const src = readSource(file);
    const cmd = parse(src);
    const code = emit(cmd, { runtimeSpecifier });
    const oi = args.indexOf("-o");
    if (oi >= 0 && args[oi + 1] !== undefined) {
      writeFileSync(args[oi + 1]!, code);
    } else {
      process.stdout.write(code);
    }
    return;
  }

  // Bare file argument → run it.
  if (existsSync(sub)) {
    await run(readSource(sub), sub);
    return;
  }

  die(`unknown command \`${sub}\``);
};

await main();
