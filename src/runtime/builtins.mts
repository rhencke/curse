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

const printf: Builtin = async (shell, ...args) => {
  // -v VAR: capture the output into a variable (or array element) instead
  // of writing it to stdout.
  let target: string | null = null;
  if (args[0] === "-v") {
    target = args[1] ?? "";
    args = args.slice(2);
  }
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
      let flags = "";
      while (j < fmt.length && "-+ 0#".includes(fmt[j]!)) flags += fmt[j++]!;
      let width = "";
      while (j < fmt.length && fmt[j]! >= "0" && fmt[j]! <= "9") width += fmt[j++]!;
      let prec = "";
      let hasPrec = false;
      if (fmt[j] === ".") {
        hasPrec = true;
        j++;
        while (j < fmt.length && fmt[j]! >= "0" && fmt[j]! <= "9") prec += fmt[j++]!;
      }
      const conv = fmt[j];
      if (conv === undefined) {
        out += fmt.slice(i);
        i = fmt.length;
        break;
      }
      // Apply precision (string truncation / numeric min-digits) then width
      // padding (left `-`, zero `0`, else spaces), matching C printf.
      const format = (s: string, numeric: boolean): string => {
        if (hasPrec) {
          const p = prec === "" ? 0 : parseInt(prec, 10);
          if (numeric) {
            const neg = s.startsWith("-") || s.startsWith("+") || s.startsWith(" ");
            const sign = neg ? s[0]! : "";
            let d = neg ? s.slice(1) : s;
            while (d.length < p) d = "0" + d;
            s = sign + d;
          } else {
            s = s.slice(0, p);
          }
        }
        const w = width === "" ? 0 : parseInt(width, 10);
        if (s.length >= w) return s;
        const fill = w - s.length;
        if (flags.includes("-")) return s + " ".repeat(fill);
        if (flags.includes("0") && numeric && !hasPrec) {
          const signed = s.startsWith("-") || s.startsWith("+") || s.startsWith(" ");
          return signed ? s[0]! + "0".repeat(fill) + s.slice(1) : "0".repeat(fill) + s;
        }
        return " ".repeat(fill) + s;
      };
      const signed = (n: number): string => {
        const s = String(n);
        if (n >= 0 && flags.includes("+")) return "+" + s;
        if (n >= 0 && flags.includes(" ")) return " " + s;
        return s;
      };
      switch (conv) {
        case "s": out += format(nextArg(), false); break;
        case "b": out += format(unescape(nextArg()).text, false); break;
        case "d": case "i": out += format(signed(toInt(nextArg())), true); break;
        case "u": out += format(String(toInt(nextArg()) >>> 0), true); break;
        case "x": out += format((toInt(nextArg()) >>> 0).toString(16), true); break;
        case "X": out += format((toInt(nextArg()) >>> 0).toString(16).toUpperCase(), true); break;
        case "o": out += format((toInt(nextArg()) >>> 0).toString(8), true); break;
        case "c": out += format(nextArg().slice(0, 1), false); break;
        default: out += "%" + conv;
      }
      i = j + 1;
    }
  };

  do {
    once();
  } while (vi < values.length);

  if (target !== null) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)\[([^\]]*)\]$/.exec(target);
    if (m) await shell.elemSet(m[1]!, m[2]!, out);
    else shell.setVar(target, out);
    return 0;
  }
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

const getopts: Builtin = (shell, ...args) => {
  if (args.length < 2) {
    shell.io.err("getopts: usage: getopts optstring name [arg ...]\n");
    return 2;
  }
  const optstring = args[0]!;
  const name = args[1]!;
  const words = args.length > 2 ? args.slice(2) : shell.positional;
  const silent = optstring.startsWith(":");
  const errPrint = !silent && shell.getVar("OPTERR") !== "0";

  let optind = toInt(shell.getVar("OPTIND") ?? "1");
  if (optind < 1) optind = 1;
  // An external `OPTIND=1` (reparse) restarts the per-word char scan.
  if (optind !== shell.optsInd) shell.optsPos = 1;

  const finish = (result: string, optarg: string | null): number => {
    shell.setVar(name, result);
    if (optarg === null) shell.unsetVar("OPTARG");
    else shell.setVar("OPTARG", optarg);
    shell.setVar("OPTIND", String(optind));
    shell.optsInd = optind;
    return 0;
  };
  const noMore = (): number => {
    shell.optsPos = 1;
    shell.setVar("OPTIND", String(optind));
    shell.optsInd = optind;
    shell.setVar(name, "?");
    shell.unsetVar("OPTARG");
    return 1;
  };

  for (;;) {
    if (optind > words.length) return noMore();
    const word = words[optind - 1]!;
    if (shell.optsPos === 1) {
      if (word === "" || word[0] !== "-" || word === "-") return noMore();
      if (word === "--") { optind++; return noMore(); }
    }
    const c = word[shell.optsPos];
    if (c === undefined) { optind++; shell.optsPos = 1; continue; }

    const specIdx = c === ":" ? -1 : optstring.indexOf(c, silent ? 1 : 0);
    if (specIdx < 0) {
      // Unknown option letter; consume it and report `?`.
      shell.optsPos++;
      if (shell.optsPos >= word.length) { optind++; shell.optsPos = 1; }
      if (errPrint) shell.io.err(`${shell.name}: illegal option -- ${c}\n`);
      return finish("?", silent ? c! : null);
    }
    if (optstring[specIdx + 1] === ":") {
      // Option takes an argument: rest of this word, else the next word.
      const rest = word.slice(shell.optsPos + 1);
      if (rest !== "") { optind++; shell.optsPos = 1; return finish(c!, rest); }
      if (optind + 1 > words.length) {
        optind++;
        shell.optsPos = 1;
        if (silent) return finish(":", c!);
        if (errPrint) shell.io.err(`${shell.name}: option requires an argument -- ${c}\n`);
        return finish("?", null);
      }
      const optarg = words[optind]!;
      optind += 2;
      shell.optsPos = 1;
      return finish(c!, optarg);
    }
    // Simple flag.
    shell.optsPos++;
    if (shell.optsPos >= word.length) { optind++; shell.optsPos = 1; }
    return finish(c!, null);
  }
};

const declareBuiltin: Builtin = (shell, ...args) => {
  let makeArray = false;
  let makeAssoc = false;
  const names: string[] = [];
  for (const a of args) {
    if (a.startsWith("-") || a.startsWith("+")) {
      if (a.includes("a")) makeArray = true;
      if (a.includes("A")) makeAssoc = true;
      continue;
    }
    names.push(a);
  }
  for (const n of names) {
    if (makeAssoc) shell.declareAssoc(n.includes("=") ? n.slice(0, n.indexOf("=")) : n);
    const eq = n.indexOf("=");
    if (eq >= 0) shell.setVar(n.slice(0, eq), n.slice(eq + 1));
    else if (makeArray && shell.arrayLen(n) === 0) shell.setArray(n, []);
  }
  return 0;
};

const readonlyBuiltin: Builtin = (shell, ...args) => {
  // We don't enforce read-only-ness; just perform the assignments.
  for (const a of args) {
    if (a.startsWith("-")) continue;
    const eq = a.indexOf("=");
    if (eq >= 0) shell.setVar(a.slice(0, eq), a.slice(eq + 1));
  }
  return 0;
};

const setBuiltin: Builtin = (shell, ...args) => {
  const opt = (name: string, on: boolean): void => {
    if (name === "errexit") shell.opts.errexit = on;
    else if (name === "nounset") shell.opts.nounset = on;
    else if (name === "xtrace") shell.opts.xtrace = on;
    else if (name === "pipefail") shell.opts.pipefail = on;
  };
  const flag = (ch: string, on: boolean): void => {
    if (ch === "e") opt("errexit", on);
    else if (ch === "u") opt("nounset", on);
    else if (ch === "x") opt("xtrace", on);
  };

  let i = 0;
  let setPositional = false;
  for (; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--") {
      i++;
      setPositional = true;
      break;
    }
    if (a === "-o" || a === "+o") {
      const name = args[i + 1];
      if (name !== undefined) {
        opt(name, a === "-o");
        i++;
      }
      continue;
    }
    if (a.length > 1 && (a[0] === "-" || a[0] === "+")) {
      const on = a[0] === "-";
      for (const ch of a.slice(1)) flag(ch, on);
      continue;
    }
    break; // start of positional parameters
  }
  const rest = args.slice(i);
  if (setPositional || rest.length > 0) shell.positional = rest;
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

const signalName = (s: string): string => {
  const up = s.toUpperCase();
  if (up === "0") return "EXIT";
  return up.startsWith("SIG") ? up.slice(3) : up;
};

const trap: Builtin = (shell, ...args) => {
  const quote = (h: string): string => "'" + h.replace(/'/g, "'\\''") + "'";
  const printTraps = (names: string[]): void => {
    for (const n of names) {
      const h = shell.traps[n];
      if (h !== undefined) shell.io.out(`trap -- ${quote(h)} ${n}\n`);
    }
  };
  // `trap` / `trap -p [sig...]`: print current handlers.
  if (args.length === 0 || args[0] === "-p") {
    const specs = args.slice(args[0] === "-p" ? 1 : 0);
    printTraps(specs.length > 0 ? specs.map(signalName) : Object.keys(shell.traps));
    return 0;
  }
  if (args[0] === "-l") return 0; // signal listing: not supported
  let rest = args;
  if (rest[0] === "--") rest = rest.slice(1);
  const action = rest[0] ?? "";
  const sigs = rest.slice(1);
  // A bare number/name as the sole argument with no action resets nothing.
  for (const s of sigs) {
    const n = signalName(s);
    if (action === "-") delete shell.traps[n];
    else shell.traps[n] = action;
  }
  return 0;
};

const mapfile: Builtin = (shell, ...args) => {
  let strip = false;
  let delim = "\n";
  let count = 0; // 0 = read all
  let skip = 0;
  let origin = 0;
  let haveOrigin = false;
  let name = "MAPFILE";
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i]!;
    if (a === "-t") { strip = true; continue; }
    if (a === "-d") { const d = args[++i] ?? ""; delim = d === "" ? "\0" : d[0]!; continue; }
    if (a === "-n") { count = toInt(args[++i] ?? "0"); continue; }
    if (a === "-s") { skip = toInt(args[++i] ?? "0"); continue; }
    if (a === "-O") { origin = toInt(args[++i] ?? "0"); haveOrigin = true; continue; }
    if (a === "-c" || a === "-C" || a === "-u") { i++; continue; } // consume + ignore
    if (a.length > 1 && a[0] === "-") continue; // other flags: ignore
    break; // first operand: the array name (options after it are ignored)
  }
  if (i < args.length) name = args[i]!;

  const data = shell.stdinData ?? "";
  shell.stdinData = "";
  // Split into records that each still carry their trailing delimiter.
  const records: string[] = [];
  let start = 0;
  let idx: number;
  while ((idx = data.indexOf(delim, start)) >= 0) {
    records.push(data.slice(start, idx + delim.length));
    start = idx + delim.length;
  }
  if (start < data.length) records.push(data.slice(start));

  let lines = records;
  if (skip > 0) lines = lines.slice(skip);
  if (count > 0) lines = lines.slice(0, count);
  const values = strip
    ? lines.map((r) => (r.endsWith(delim) ? r.slice(0, -delim.length) : r))
    : lines;

  if (haveOrigin) values.forEach((v, i) => shell.setElem(name, origin + i, v));
  else shell.setArray(name, values);
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
  getopts,
  wait,
  set: setBuiltin,
  declare: declareBuiltin,
  typeset: declareBuiltin,
  readonly: readonlyBuiltin,
  read,
  trap,
  mapfile,
  readarray: mapfile,
  test,
  "[": bracket,
};
