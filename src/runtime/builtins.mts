/* Shell builtins. Behaviour follows bash (GPLv3+; see NOTICE.md).
 *
 * A builtin is `(shell, ...args) => status`. It is stored as the prototype of
 * the command registry, so a bash function of the same name shadows it (and
 * `unset -f` reveals it again). Called via the shell, never bound to `this`. */

import { resolve } from "node:path";
import { accessSync, constants, lstatSync, statSync } from "node:fs";
import type { Shell } from "./shell.mts";
import { ExitSignal, ReturnSignal } from "./types.mts";

export type Builtin = (shell: Shell, ...args: string[]) => number | Promise<number>;

/** Process C-style backslash escapes (for `echo -e`, `printf %b`). */
const unescape = (s: string): { text: string; stop: boolean } => {
  let out = "";
  let i = 0;
  while (i < s.length) {
    const c = s[i]!;
    if (c !== "\\" || i + 1 >= s.length) {
      out += c;
      i++;
      continue;
    }
    const e = s[i + 1]!;
    i += 2;
    switch (e) {
      case "n": out += "\n"; break;
      case "t": out += "\t"; break;
      case "r": out += "\r"; break;
      case "\\": out += "\\"; break;
      case "a": out += "\x07"; break;
      case "b": out += "\b"; break;
      case "f": out += "\f"; break;
      case "v": out += "\v"; break;
      case "e": out += "\x1b"; break;
      case "c": return { text: out, stop: true };
      case "0": {
        let oct = "";
        while (oct.length < 3 && i < s.length && s[i]! >= "0" && s[i]! <= "7") {
          oct += s[i];
          i++;
        }
        out += String.fromCharCode(oct === "" ? 0 : parseInt(oct, 8));
        break;
      }
      default:
        out += "\\" + e;
    }
  }
  return { text: out, stop: false };
};

const toInt = (s: string): number => {
  const t = s.trim();
  if (t === "") return 0;
  const n = t.startsWith("0x") || t.startsWith("0X") ? parseInt(t, 16) : parseInt(t, 10);
  return Number.isNaN(n) ? 0 : n;
};

const echo: Builtin = (shell, ...args) => {
  let rest = args;
  let newline = true;
  let escapes = false;
  while (rest.length > 0 && /^-[neE]+$/.test(rest[0]!)) {
    for (const ch of rest[0]!.slice(1)) {
      if (ch === "n") newline = false;
      else if (ch === "e") escapes = true;
      else if (ch === "E") escapes = false;
    }
    rest = rest.slice(1);
  }
  let text = rest.join(" ");
  if (escapes) {
    const r = unescape(text);
    text = r.text;
    if (r.stop) newline = false;
  }
  shell.io.out(text + (newline ? "\n" : ""));
  return 0;
};

const printf: Builtin = (shell, ...args) => {
  if (args.length === 0) {
    shell.io.err("printf: usage: printf [-v var] format [arguments]\n");
    return 2;
  }
  const fmt = args[0]!;
  const values = args.slice(1);
  let vi = 0;
  const nextArg = (): string => (vi < values.length ? values[vi++]! : "");

  let out = "";
  const once = (): void => {
    let i = 0;
    while (i < fmt.length) {
      const c = fmt[i]!;
      if (c === "\\") {
        out += unescape(fmt.slice(i, i + 2)).text;
        i += 2;
        continue;
      }
      if (c !== "%") {
        out += c;
        i++;
        continue;
      }
      let j = i + 1;
      if (fmt[j] === "%") {
        out += "%";
        i = j + 1;
        continue;
      }
      while (j < fmt.length && "-+ 0#".includes(fmt[j]!)) j++;
      while (j < fmt.length && fmt[j]! >= "0" && fmt[j]! <= "9") j++;
      if (fmt[j] === ".") {
        j++;
        while (j < fmt.length && fmt[j]! >= "0" && fmt[j]! <= "9") j++;
      }
      const conv = fmt[j];
      if (conv === undefined) {
        out += fmt.slice(i);
        i = fmt.length;
        break;
      }
      switch (conv) {
        case "s": out += nextArg(); break;
        case "b": out += unescape(nextArg()).text; break;
        case "d": case "i": out += String(toInt(nextArg())); break;
        case "u": out += String(toInt(nextArg()) >>> 0); break;
        case "x": out += (toInt(nextArg()) >>> 0).toString(16); break;
        case "X": out += (toInt(nextArg()) >>> 0).toString(16).toUpperCase(); break;
        case "o": out += (toInt(nextArg()) >>> 0).toString(8); break;
        case "c": out += nextArg().slice(0, 1); break;
        default: out += "%" + conv;
      }
      i = j + 1;
    }
  };

  do {
    once();
  } while (vi < values.length);

  shell.io.out(out);
  return 0;
};

const pwd: Builtin = (shell) => {
  shell.io.out(shell.cwd + "\n");
  return 0;
};

const cd: Builtin = (shell, ...args) => {
  const target = args[0] ?? shell.getVar("HOME") ?? "";
  if (target === "") {
    shell.io.err("cd: HOME not set\n");
    return 1;
  }
  const dest = resolve(shell.cwd, target);
  try {
    if (!statSync(dest).isDirectory()) {
      shell.io.err(`cd: ${target}: Not a directory\n`);
      return 1;
    }
  } catch {
    shell.io.err(`cd: ${target}: No such file or directory\n`);
    return 1;
  }
  shell.cwd = dest;
  shell.setVar("PWD", dest);
  return 0;
};

const exportBuiltin: Builtin = (shell, ...args) => {
  for (const a of args) {
    const eq = a.indexOf("=");
    if (eq >= 0) {
      shell.setVar(a.slice(0, eq), a.slice(eq + 1));
      shell.exportVar(a.slice(0, eq));
    } else {
      shell.exportVar(a);
    }
  }
  return 0;
};

const local: Builtin = (shell, ...args) => {
  for (const a of args) {
    const eq = a.indexOf("=");
    if (eq >= 0) shell.local(a.slice(0, eq), a.slice(eq + 1));
    else shell.local(a);
  }
  return 0;
};

const unset: Builtin = (shell, ...args) => {
  let mode: "v" | "f" | "" = "";
  for (const a of args) {
    if (a === "-f") mode = "f";
    else if (a === "-v") mode = "v";
    else if (mode === "f") shell.unsetFunc(a);
    else shell.unsetVar(a);
  }
  return 0;
};

const returnBuiltin: Builtin = (shell, ...args) => {
  throw new ReturnSignal(args.length > 0 ? toInt(args[0]!) : shell.status);
};

const exitBuiltin: Builtin = (shell, ...args) => {
  throw new ExitSignal(args.length > 0 ? toInt(args[0]!) : shell.status);
};

const shift: Builtin = (shell, ...args) => {
  const n = args.length > 0 ? toInt(args[0]!) : 1;
  if (n < 0 || n > shell.positional.length) return 1;
  shell.positional = shell.positional.slice(n);
  return 0;
};

const wait: Builtin = async (shell, ...args) => {
  if (args.length === 0) {
    await shell.waitAll();
    return 0;
  }
  let status = 0;
  for (const a of args) status = await shell.waitFor(toInt(a));
  return status;
};

const read: Builtin = (shell, ...args) => {
  const names = args.filter((a) => !a.startsWith("-"));
  if (shell.stdinData === null || shell.stdinData === "") return 1;
  const data = shell.stdinData;
  const nl = data.indexOf("\n");
  const line = nl >= 0 ? data.slice(0, nl) : data;
  shell.stdinData = nl >= 0 ? data.slice(nl + 1) : "";

  if (names.length === 0) {
    shell.setVar("REPLY", line);
    return 0;
  }
  const trimmed = line.replace(/^[ \t]+/, "");
  const fields = trimmed === "" ? [] : trimmed.split(/[ \t]+/);
  for (let idx = 0; idx < names.length; idx++) {
    const value = idx < names.length - 1
      ? fields[idx] ?? ""
      : fields.slice(idx).join(" ").replace(/[ \t]+$/, "");
    shell.setVar(names[idx]!, value);
  }
  return 0;
};

/* ---- test / [ ---- */

const statOf = (p: string) => {
  try {
    return statSync(p);
  } catch {
    return null;
  }
};
const canAccess = (p: string, mode: number): boolean => {
  try {
    accessSync(p, mode);
    return true;
  } catch {
    return false;
  }
};

const UNARY = new Set(["-z", "-n", "-e", "-f", "-d", "-s", "-r", "-w", "-x", "-h", "-L"]);
const BINARY = new Set(["=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge"]);

const unaryTest = (op: string, arg: string, shell: Shell): boolean => {
  if (op === "-z") return arg.length === 0;
  if (op === "-n") return arg.length > 0;
  const p = resolve(shell.cwd, arg);
  switch (op) {
    case "-e": return statOf(p) !== null;
    case "-f": return statOf(p)?.isFile() ?? false;
    case "-d": return statOf(p)?.isDirectory() ?? false;
    case "-s": return (statOf(p)?.size ?? 0) > 0;
    case "-r": return canAccess(p, constants.R_OK);
    case "-w": return canAccess(p, constants.W_OK);
    case "-x": return canAccess(p, constants.X_OK);
    case "-h": case "-L":
      try {
        return lstatSync(p).isSymbolicLink();
      } catch {
        return false;
      }
    default:
      throw new Error(`${op}: unary operator expected`);
  }
};

const binaryTest = (a: string, op: string, b: string): boolean => {
  switch (op) {
    case "=": case "==": return a === b;
    case "!=": return a !== b;
    case "<": return a < b;
    case ">": return a > b;
    case "-eq": return toInt(a) === toInt(b);
    case "-ne": return toInt(a) !== toInt(b);
    case "-lt": return toInt(a) < toInt(b);
    case "-le": return toInt(a) <= toInt(b);
    case "-gt": return toInt(a) > toInt(b);
    case "-ge": return toInt(a) >= toInt(b);
    default: throw new Error(`${op}: binary operator expected`);
  }
};

const splitTop = (a: string[], sep: string): string[][] => {
  const groups: string[][] = [];
  let cur: string[] = [];
  for (const x of a) {
    if (x === sep) {
      groups.push(cur);
      cur = [];
    } else {
      cur.push(x);
    }
  }
  groups.push(cur);
  return groups;
};

const evalTest = (a: string[], shell: Shell): boolean => {
  switch (a.length) {
    case 0:
      return false;
    case 1:
      return a[0]!.length > 0;
    case 2:
      if (a[0] === "!") return !(a[1]!.length > 0);
      if (UNARY.has(a[0]!)) return unaryTest(a[0]!, a[1]!, shell);
      throw new Error(`${a[0]}: unary operator expected`);
    case 3:
      if (BINARY.has(a[1]!)) return binaryTest(a[0]!, a[1]!, a[2]!);
      if (a[0] === "!") return !evalTest(a.slice(1), shell);
      if (a[0] === "(" && a[2] === ")") return evalTest([a[1]!], shell);
      throw new Error(`${a[1]}: binary operator expected`);
    case 4:
      if (a[0] === "!") return !evalTest(a.slice(1), shell);
      if (a[0] === "(" && a[3] === ")") return evalTest(a.slice(1, 3), shell);
      break;
  }
  return splitTop(a, "-o").some((orPart) =>
    splitTop(orPart, "-a").every((andPart) => evalTest(andPart, shell)),
  );
};

const testImpl = (shell: Shell, args: string[]): number => {
  try {
    return evalTest(args, shell) ? 0 : 1;
  } catch (e) {
    shell.io.err(`test: ${e instanceof Error ? e.message : String(e)}\n`);
    return 2;
  }
};

const test: Builtin = (shell, ...args) => testImpl(shell, args);

const bracket: Builtin = (shell, ...args) => {
  if (args[args.length - 1] !== "]") {
    shell.io.err("[: missing `]'\n");
    return 2;
  }
  return testImpl(shell, args.slice(0, -1));
};

export const builtins: Record<string, Builtin> = {
  ":": () => 0,
  true: () => 0,
  false: () => 1,
  echo,
  printf,
  pwd,
  cd,
  export: exportBuiltin,
  local,
  unset,
  return: returnBuiltin,
  exit: exitBuiltin,
  shift,
  wait,
  read,
  test,
  "[": bracket,
};
