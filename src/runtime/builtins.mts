/* Shell builtins. Behaviour follows bash (GPLv3+; see NOTICE.md).
 *
 * A builtin is `(shell, ...args) => status`. It is stored as the prototype of
 * the command registry, so a bash function of the same name shadows it (and
 * `unset -f` reveals it again). Called via the shell, never bound to `this`. */

import { isAbsolute, resolve } from "node:path";
import { accessSync, constants, lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import type { Shell } from "./shell.mts";
import { ExitSignal, LoopSignal, ReturnSignal } from "./types.mts";

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
    const isHex = (ch: string | undefined): boolean =>
      ch !== undefined && /[0-9a-fA-F]/.test(ch);
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
        out += String.fromCharCode(oct === "" ? 0 : parseInt(oct, 8) & 0xff);
        break;
      }
      case "x": {
        // \xHH: one or two hex digits -> a byte. Empty stays literal.
        let hex = "";
        while (hex.length < 2 && isHex(s[i])) { hex += s[i]; i++; }
        if (hex === "") { out += "\\x"; break; }
        out += String.fromCharCode(parseInt(hex, 16) & 0xff);
        break;
      }
      case "u":
      case "U": {
        // \uHHHH (<=4) / \UHHHHHHHH (<=8): a Unicode code point. Empty stays literal.
        const max = e === "u" ? 4 : 8;
        let hex = "";
        while (hex.length < max && isHex(s[i])) { hex += s[i]; i++; }
        if (hex === "") { out += "\\" + e; break; }
        const cp = parseInt(hex, 16);
        out += cp <= 0x10ffff ? String.fromCodePoint(cp) : "�";
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

/** Parse a printf numeric argument (bash rules: leading ws, 0x/0 bases, 'c
 *  char code, 64-bit) into a BigInt; invalid -> 0 with a stderr diagnostic. */
const U64 = (1n << 64n) - 1n;
const s64 = (v: bigint): bigint => {
  const m = v & U64;
  return m >= 1n << 63n ? m - (1n << 64n) : m;
};
const pfNum = (shell: Shell, raw: string): bigint => {
  const t = raw.replace(/^[ \t\n]+/, "");
  if (t === "") return 0n;
  if (t[0] === "'" || t[0] === '"') return BigInt(t.codePointAt(1) ?? 0);
  const m = /^[+-]?(0[xX][0-9a-fA-F]+|0[0-7]+|[0-9]+)/.exec(t);
  if (m === null) {
    shell.io.err(`printf: ${raw}: invalid number\n`);
    return 0n;
  }
  let str = m[0];
  const neg = str[0] === "-";
  if (str[0] === "+" || str[0] === "-") str = str.slice(1);
  let val: bigint;
  if (/^0[xX]/.test(str)) val = BigInt(str);
  else if (/^0[0-7]+$/.test(str)) val = BigInt("0o" + str.slice(1));
  else val = BigInt(str);
  return neg ? -val : val;
};
const pfFloat = (raw: string): number => {
  const n = Number(raw.replace(/^[ \t\n]+/, "").replace(/[ \t\n]+$/, ""));
  return Number.isNaN(n) ? 0 : n;
};

/** printf %q: quote a value so it can be reused as shell input. */
const shellBackslashQuote = (v: string): string => {
  if (v === "") return "''";
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
  return v.replace(/[^A-Za-z0-9_@%+=:,./-]/g, "\\$&");
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
      if (fmt[j] === "*") {
        let wn = Number(pfNum(shell, nextArg()));
        if (wn < 0) { flags += "-"; wn = -wn; }
        width = String(wn);
        j++;
      } else {
        while (j < fmt.length && fmt[j]! >= "0" && fmt[j]! <= "9") width += fmt[j++]!;
      }
      let prec = "";
      let hasPrec = false;
      if (fmt[j] === ".") {
        hasPrec = true;
        j++;
        if (fmt[j] === "*") {
          prec = String(Math.max(0, Number(pfNum(shell, nextArg()))));
          j++;
        } else {
          while (j < fmt.length && fmt[j]! >= "0" && fmt[j]! <= "9") prec += fmt[j++]!;
        }
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
      const sign = (n: bigint, s: string): string =>
        n >= 0n ? (flags.includes("+") ? "+" + s : flags.includes(" ") ? " " + s : s) : s;
      const alt = (pfx: string, s: string): string => (flags.includes("#") && s !== "0" ? pfx + s : s);
      const efmt = (n: number, upper: boolean): string => {
        const p = hasPrec ? (prec === "" ? 0 : parseInt(prec, 10)) : 6;
        // pad the exponent to at least two digits, as C printf does
        const s = n.toExponential(p).replace(/e([+-])(\d)$/, "e$10$2");
        return upper ? s.toUpperCase() : s;
      };
      const gfmt = (n: number, upper: boolean): string => {
        const p = hasPrec ? (prec === "" ? 0 : parseInt(prec, 10)) || 1 : 6;
        let s = n.toPrecision(p);
        if (s.includes("e")) s = s.replace(/e([+-])(\d)$/, "e$10$2");
        else if (s.includes(".")) s = s.replace(/\.?0+$/, ""); // %g trims trailing zeros
        return upper ? s.toUpperCase() : s;
      };
      switch (conv) {
        case "s": out += format(nextArg(), false); break;
        case "b": out += format(unescape(nextArg()).text, false); break;
        case "d": case "i": { const n = s64(pfNum(shell, nextArg())); out += format(sign(n, String(n)), true); break; }
        case "u": out += format(String(pfNum(shell, nextArg()) & U64), true); break;
        case "x": out += format(alt("0x", (pfNum(shell, nextArg()) & U64).toString(16)), true); break;
        case "X": out += format(alt("0X", (pfNum(shell, nextArg()) & U64).toString(16).toUpperCase()), true); break;
        case "o": {
          const s = (pfNum(shell, nextArg()) & U64).toString(8);
          out += format(flags.includes("#") && s[0] !== "0" ? "0" + s : s, true);
          break;
        }
        case "c": out += format(nextArg().slice(0, 1), false); break;
        case "q": out += format(shellBackslashQuote(nextArg()), false); break;
        case "f": case "F": {
          const n = pfFloat(nextArg());
          out += format(sign(BigInt(Math.trunc(n)), n.toFixed(hasPrec ? (prec === "" ? 0 : parseInt(prec, 10)) : 6)), true);
          break;
        }
        case "e": case "E": { const n = pfFloat(nextArg()); out += format(sign(n >= 0 ? 0n : -1n, efmt(n, conv === "E")), true); break; }
        case "g": case "G": { const n = pfFloat(nextArg()); out += format(sign(n >= 0 ? 0n : -1n, gfmt(n, conv === "G")), true); break; }
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

const pwd: Builtin = (shell, ...args) => {
  // pwd -P prints the physical path (symlinks resolved); -L (default) logical.
  let dir = shell.cwd;
  if (args.includes("-P")) {
    try { dir = realpathSync(shell.cwd); } catch { /* keep logical */ }
  }
  shell.io.out(dir + "\n");
  return 0;
};

const cd: Builtin = (shell, ...args) => {
  let physical = false;
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--") { i++; break; }
    if (a === "-L") physical = false;
    else if (a === "-P") physical = true;
    else break;
  }
  if (args.length - i > 1) {
    shell.io.err("cd: too many arguments\n");
    return 1;
  }
  let target = args[i];
  const oldpwd = shell.getVar("PWD") ?? shell.cwd;
  let announce = false; // `cd -` and CDPATH hits echo the destination
  if (target === undefined) {
    target = shell.getVar("HOME");
    if (target === undefined || target === "") { shell.io.err("cd: HOME not set\n"); return 1; }
  } else if (target === "-") {
    const old = shell.getVar("OLDPWD");
    if (old === undefined) { shell.io.err("cd: OLDPWD not set\n"); return 1; }
    target = old;
    announce = true;
  } else if (
    !isAbsolute(target) && target !== "." && target !== ".." &&
    !target.startsWith("./") && !target.startsWith("../")
  ) {
    // CDPATH: search each entry for the target directory.
    const cdpath = shell.getVar("CDPATH");
    if (cdpath !== undefined && cdpath !== "") {
      for (const entry of cdpath.split(":")) {
        const cand = resolve(shell.cwd, entry === "" ? "." : entry, target);
        try {
          if (statSync(cand).isDirectory()) { target = cand; announce = true; break; }
        } catch { /* try next entry */ }
      }
    }
  }
  // Existence check uses the raw (un-collapsed) path so a missing intermediate
  // in `cd BAD/..` is caught, matching bash rather than Node's path collapsing.
  const raw = isAbsolute(target) ? target : shell.cwd + "/" + target;
  try {
    if (!statSync(raw).isDirectory()) { shell.io.err(`cd: ${target}: Not a directory\n`); return 1; }
  } catch {
    shell.io.err(`cd: ${target}: No such file or directory\n`);
    return 1;
  }
  const dest = physical ? realpathSync(raw) : resolve(shell.cwd, target);
  shell.cwd = dest;
  if (announce) shell.io.out(dest + "\n");
  shell.setVar("OLDPWD", oldpwd);
  shell.exportVar("OLDPWD");
  shell.setVar("PWD", dest);
  shell.exportVar("PWD");
  return 0;
};

const exportBuiltin: Builtin = (shell, ...args) => {
  const nonFlag = args.filter((a) => !a.startsWith("-"));
  // `export` / `export -p` (no names) lists all exported variables.
  if (nonFlag.length === 0) {
    for (const line of shell.declareLinesWhere((v) => v.exported)) shell.io.out(line + "\n");
    return 0;
  }
  for (const a of nonFlag) {
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
  const { flags, names } = parseDeclFlags(args);
  for (const n of names) {
    const eq = n.indexOf("=");
    const name = eq >= 0 ? n.slice(0, eq) : n;
    shell.local(name);
    if (flags.nameref) {
      shell.setRef(name, eq >= 0 ? n.slice(eq + 1) : "");
      continue;
    }
    shell.setAttrs(name, flags);
    if (eq >= 0) shell.setVar(name, n.slice(eq + 1));
  }
  return 0;
};

const unset: Builtin = (shell, ...args) => {
  let mode: "v" | "f" | "" = "";
  shell.readonlyHit = false;
  for (const a of args) {
    if (a === "-f") mode = "f";
    else if (a === "-v") mode = "v";
    else if (mode === "f") shell.unsetFunc(a);
    else {
      const m = /^([A-Za-z_][A-Za-z0-9_]*)\[([\s\S]*)\]$/.exec(a);
      if (m) shell.unsetElem(m[1]!, m[2]!);
      else shell.unsetVar(a);
    }
  }
  return shell.readonlyHit ? 1 : 0;
};

const returnBuiltin: Builtin = (shell, ...args) => {
  // Exit codes are a single byte: bash truncates mod 256 (so 257 -> 1, -1 -> 255).
  throw new ReturnSignal(args.length > 0 ? toInt(args[0]!) & 0xff : shell.status);
};

const exitBuiltin: Builtin = (shell, ...args) => {
  throw new ExitSignal(args.length > 0 ? toInt(args[0]!) & 0xff : shell.status);
};

const shift: Builtin = (shell, ...args) => {
  const n = args.length > 0 ? toInt(args[0]!) : 1;
  if (n < 0 || n > shell.positional.length) return 1;
  shell.positional = shell.positional.slice(n);
  return 0;
};

const evalBuiltin: Builtin = (shell, ...args) => shell.evalString(args.join(" "));

const sourceBuiltin: Builtin = async (shell, ...args) => {
  const file = args[0];
  if (file === undefined) {
    shell.io.err("source: filename argument required\n");
    return 2;
  }
  let src: string;
  try {
    src = readFileSync(resolve(shell.cwd, file), "utf8");
  } catch {
    shell.io.err(`${shell.name}: ${file}: No such file or directory\n`);
    return 1;
  }
  const saved = shell.positional;
  if (args.length > 1) shell.positional = args.slice(1);
  try {
    return await shell.evalString(src);
  } finally {
    shell.positional = saved;
  }
};

const letBuiltin: Builtin = async (shell, ...args) => {
  if (args.length === 0) {
    shell.io.err("let: expression expected\n");
    return 1;
  }
  let nonzero = false;
  for (const a of args) {
    try {
      nonzero = a.trim() !== "" && (await shell.arithTest(a));
    } catch (e) {
      shell.io.err(`let: ${a}: ${e instanceof Error ? e.message : String(e)}\n`);
      return 1;
    }
  }
  return nonzero ? 0 : 1;
};

const breakBuiltin: Builtin = (shell, ...args) => {
  if (shell.loopDepth <= 0) return 0; // no-op outside a loop (bash warns to stderr)
  throw new LoopSignal("break", args.length > 0 ? Math.max(1, toInt(args[0]!)) : 1);
};
const continueBuiltin: Builtin = (shell, ...args) => {
  if (shell.loopDepth <= 0) return 0;
  throw new LoopSignal("continue", args.length > 0 ? Math.max(1, toInt(args[0]!)) : 1);
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

interface DeclFlags {
  integer?: boolean;
  lower?: boolean;
  upper?: boolean;
  readonly: boolean;
  exported: boolean;
  array: boolean;
  assoc: boolean;
  nameref: boolean;
}
const parseDeclFlags = (args: string[]): { flags: DeclFlags; names: string[] } => {
  const flags: DeclFlags = { readonly: false, exported: false, array: false, assoc: false, nameref: false };
  const names: string[] = [];
  for (const a of args) {
    if (a.length > 1 && (a[0] === "-" || a[0] === "+")) {
      const on = a[0] === "-";
      for (const ch of a.slice(1)) {
        if (ch === "i") flags.integer = on;
        else if (ch === "l") flags.lower = on;
        else if (ch === "u") flags.upper = on;
        else if (ch === "r") flags.readonly ||= on;
        else if (ch === "x") flags.exported ||= on;
        else if (ch === "a") flags.array = true;
        else if (ch === "A") flags.assoc = true;
        else if (ch === "n") flags.nameref = on;
      }
      continue;
    }
    names.push(a);
  }
  return { flags, names };
};

const declareBuiltin: Builtin = (shell, ...args) => {
  // Bare `declare` lists every variable in `set` (name=value) form.
  if (args.length === 0) {
    for (const line of shell.varListing()) shell.io.out(line + "\n");
    return 0;
  }
  const dashFlags = args.filter((a) => a[0] === "-" || a[0] === "+");
  const opNames = (): string[] =>
    args.filter((a) => a[0] !== "-" && a[0] !== "+").map((a) => {
      const eq = a.indexOf("=");
      return eq >= 0 ? a.slice(0, eq) : a;
    });
  // declare -F: list function names (or, with names, test each is a function).
  if (dashFlags.some((f) => f[0] === "-" && f.includes("F"))) {
    const names = opNames();
    if (names.length === 0) {
      for (const fn of shell.functionNames()) shell.io.out(`declare -f ${fn}\n`);
      return 0;
    }
    let status = 0;
    for (const n of names) {
      if (shell.hasFunction(n)) shell.io.out(`${n}\n`);
      else status = 1;
    }
    return status;
  }
  // declare -f: exit status reflects function existence (body printing TODO).
  if (dashFlags.some((f) => f[0] === "-" && f.includes("f"))) {
    const names = opNames();
    return names.every((n) => shell.hasFunction(n)) ? 0 : 1;
  }
  // declare -p [name...]: print definitions.
  if (args.includes("-p")) {
    const targets = args.filter((a) => a[0] !== "-" && a[0] !== "+").map((a) => {
      const eq = a.indexOf("=");
      return eq >= 0 ? a.slice(0, eq) : a;
    });
    // `declare -p` with no names prints every variable in declare form.
    if (targets.length === 0) {
      for (const name of shell.matchNames("")) {
        if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) continue;
        const line = shell.declareLine(name);
        if (line !== null) shell.io.out(line + "\n");
      }
      return 0;
    }
    let status = 0;
    for (const name of targets) {
      const line = shell.declareLine(name);
      if (line === null) {
        shell.io.err(`${shell.name}: declare: ${name}: not found\n`);
        status = 1;
      } else {
        shell.io.out(line + "\n");
      }
    }
    return status;
  }
  const { flags, names } = parseDeclFlags(args);
  const clearRef = dashFlags.some((f) => f[0] === "+" && f.includes("n"));
  for (const n of names) {
    const eq = n.indexOf("=");
    const name = eq >= 0 ? n.slice(0, eq) : n;
    if (clearRef) { shell.clearRef(name); continue; }
    if (flags.nameref) {
      shell.setRef(name, eq >= 0 ? n.slice(eq + 1) : "");
      continue;
    }
    // Establish array/assoc shape before setAttrs, so an empty `declare -a x`
    // stays a 0-element array rather than a "" scalar.
    if (flags.assoc) shell.declareAssoc(name);
    else if (eq < 0 && flags.array && shell.arrayLen(name) === 0) shell.setArray(name, []);
    // Apply -i/-l/-u before the value (so it's coerced), but readonly after
    // (so this very assignment isn't rejected).
    shell.setAttrs(name, { ...flags, readonly: false });
    if (eq >= 0) shell.setVar(name, n.slice(eq + 1));
    if (flags.readonly) shell.setAttrs(name, { readonly: true });
    if (flags.exported) shell.exportVar(name);
  }
  return 0;
};

const readonlyBuiltin: Builtin = (shell, ...args) => {
  const nonFlag = args.filter((a) => !a.startsWith("-"));
  // `readonly` / `readonly -p` (no names) lists all readonly variables.
  if (nonFlag.length === 0) {
    for (const line of shell.declareLinesWhere((v) => v.readonly)) shell.io.out(line + "\n");
    return 0;
  }
  for (const a of nonFlag) {
    const eq = a.indexOf("=");
    const name = eq >= 0 ? a.slice(0, eq) : a;
    if (eq >= 0) shell.setVar(name, a.slice(eq + 1));
    shell.setAttrs(name, { readonly: true });
  }
  return 0;
};

const setBuiltin: Builtin = (shell, ...args) => {
  // `set` with no arguments lists all shell variables.
  if (args.length === 0) {
    for (const line of shell.varListing()) shell.io.out(line + "\n");
    return 0;
  }
  const opt = (name: string, on: boolean): void => {
    if (name === "errexit") shell.opts.errexit = on;
    else if (name === "nounset") shell.opts.nounset = on;
    else if (name === "xtrace") shell.opts.xtrace = on;
    else if (name === "pipefail") shell.opts.pipefail = on;
    else if (name === "noclobber") shell.opts.noclobber = on;
    else if (name === "noglob") shell.opts.noglob = on;
  };
  const flag = (ch: string, on: boolean): void => {
    if (ch === "e") opt("errexit", on);
    else if (ch === "u") opt("nounset", on);
    else if (ch === "x") opt("xtrace", on);
    else if (ch === "C") opt("noclobber", on);
    else if (ch === "f") opt("noglob", on);
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

/** Split a line into fields per IFS (bash's read splitting). `limit` caps the
 *  field count — the last field keeps the raw remainder (trailing IFS
 *  whitespace stripped); Infinity splits fully (for `read -a`). */
const readFields = (line: string, ifs: string, limit: number): string[] => {
  const ws = new Set<string>();
  const sep = new Set<string>();
  for (const c of ifs) (c === " " || c === "\t" || c === "\n" ? ws : sep).add(c);
  const isWs = (c: string): boolean => ws.has(c);
  const isSep = (c: string): boolean => sep.has(c);
  const fields: string[] = [];
  let i = 0;
  while (i < line.length && isWs(line[i]!)) i++;
  while (i < line.length) {
    if (fields.length === limit - 1) {
      let rest = line.slice(i);
      while (rest.length > 0 && isWs(rest[rest.length - 1]!)) rest = rest.slice(0, -1);
      fields.push(rest);
      return fields;
    }
    let f = "";
    while (i < line.length && !isWs(line[i]!) && !isSep(line[i]!)) f += line[i++];
    fields.push(f);
    while (i < line.length && isWs(line[i]!)) i++;
    if (i < line.length && isSep(line[i]!)) {
      i++;
      while (i < line.length && isWs(line[i]!)) i++;
    }
  }
  return fields;
};

const read: Builtin = (shell, ...args) => {
  let raw = false;
  let arrayName: string | null = null;
  let delim = "\n";
  let nchars = -1;
  let exactN = -1;
  const names: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "-r") raw = true;
    else if (a === "-s") continue; // silent: no tty here
    else if (a === "-a") arrayName = args[++i] ?? "";
    else if (a === "-d") { const d = args[++i] ?? ""; delim = d === "" ? "\0" : d[0]!; }
    else if (a === "-n") nchars = toInt(args[++i] ?? "0");
    else if (a === "-N") exactN = toInt(args[++i] ?? "0");
    else if (a === "-p") shell.io.err(args[++i] ?? "");
    else if (a === "-t" || a === "-u") i++; // timeout / fd: ignore + consume
    else if (a.length > 1 && a[0] === "-") continue; // other flags: ignore
    else names.push(a);
  }

  if (shell.stdinData === null || shell.stdinData === "") return 1;
  let data = shell.stdinData;
  let chunk: string;
  let eof = false;
  let line: string;
  if (exactN >= 0) {
    chunk = data.slice(0, exactN);
    if (chunk.length < exactN) eof = true;
    data = data.slice(chunk.length);
    line = chunk;
  } else if (nchars >= 0 || raw) {
    let end = data.indexOf(delim);
    if (end < 0) { end = data.length; eof = true; }
    const stop = nchars >= 0 && nchars < end ? nchars : end;
    chunk = data.slice(0, stop);
    data = stop === end && !eof ? data.slice(end + delim.length) : data.slice(stop);
    line = raw ? chunk : chunk.replace(/\\([\s\S])/g, "$1");
  } else {
    // Non-raw line read: a backslash escapes the next char; `\`+delimiter is a
    // line continuation (both dropped, reading continues past the delimiter).
    let k = 0;
    let out = "";
    for (;;) {
      if (k >= data.length) { eof = true; break; }
      const c = data[k]!;
      if (c === "\\") {
        const n = data[k + 1];
        if (n === undefined) { k = data.length; eof = true; break; }
        if (n !== "\n") out += n; // \<newline> is a line continuation (dropped)
        k += 2;
        continue;
      }
      if (data.startsWith(delim, k)) { k += delim.length; break; }
      out += c;
      k++;
    }
    data = data.slice(k);
    line = out;
  }
  shell.stdinData = data;

  const ifs = shell.getVar("IFS");
  const ifsVal = ifs === undefined ? " \t\n" : ifs;

  if (arrayName !== null) {
    shell.setArray(arrayName, ifsVal === "" ? (line === "" ? [] : [line]) : readFields(line, ifsVal, Infinity));
  } else if (names.length === 0) {
    shell.setVar("REPLY", line);
  } else {
    const fields = ifsVal === "" ? [line] : readFields(line, ifsVal, names.length);
    for (let idx = 0; idx < names.length; idx++) shell.setVar(names[idx]!, fields[idx] ?? "");
  }
  return eof ? 1 : 0;
};

const KEYWORDS = new Set([
  "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
  "case", "esac", "function", "select", "time", "in", "{", "}", "!", "[[", "]]", "coproc",
]);

type Kind = "alias" | "keyword" | "function" | "builtin" | "file";
const classify = (shell: Shell, name: string): Kind | null => {
  if (KEYWORDS.has(name)) return "keyword";
  if (shell.hasFunction(name)) return "function";
  if (shell.hasBuiltin(name)) return "builtin";
  if (shell.lookupPath(name) !== null) return "file";
  return null;
};

const type: Builtin = (shell, ...args) => {
  let mode: "t" | "p" | "P" | "" = "";
  const names: string[] = [];
  for (const a of args) {
    if (a === "-t") mode = "t";
    else if (a === "-p") mode = "p";
    else if (a === "-P") mode = "P";
    else if (a === "-a" || a === "-f") continue; // -a all / -f no-functions: ignore
    else if (a === "--") continue;
    else names.push(a);
  }
  let status = 0;
  for (const name of names) {
    const kind = classify(shell, name);
    if (kind === null) {
      shell.io.err(`${shell.name}: type: ${name}: not found\n`);
      status = 1;
      continue;
    }
    if (mode === "t") {
      shell.io.out(kind + "\n");
      continue;
    }
    if (mode === "p" || mode === "P") {
      // -p prints a path only for files; -P forces a PATH search.
      const path = kind === "file" || mode === "P" ? shell.lookupPath(name) : null;
      if (path !== null) shell.io.out(path + "\n");
      else if (mode === "P") status = 1;
      continue;
    }
    switch (kind) {
      case "keyword": shell.io.out(`${name} is a shell keyword\n`); break;
      case "function": shell.io.out(`${name} is a function\n`); break;
      case "builtin": shell.io.out(`${name} is a shell builtin\n`); break;
      case "file": shell.io.out(`${name} is ${shell.lookupPath(name)}\n`); break;
      case "alias": break;
    }
  }
  return status;
};

const command: Builtin = async (shell, ...args) => {
  let verbose: "v" | "V" | "" = "";
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i]!;
    if (a === "-v") verbose = "v";
    else if (a === "-V") verbose = "V";
    else if (a === "-p") continue; // default PATH: ignore
    else if (a === "--") { i++; break; }
    else if (a.length > 1 && a[0] === "-") continue;
    else break;
  }
  const rest = args.slice(i);
  if (verbose !== "") {
    let status = 0;
    for (const name of rest) {
      const kind = classify(shell, name);
      if (kind === null) { status = 1; continue; }
      if (verbose === "v") {
        shell.io.out((kind === "file" ? shell.lookupPath(name)! : name) + "\n");
      } else {
        switch (kind) {
          case "keyword": shell.io.out(`${name} is a shell keyword\n`); break;
          case "function": shell.io.out(`${name} is a function\n`); break;
          case "builtin": shell.io.out(`${name} is a shell builtin\n`); break;
          case "file": shell.io.out(`${name} is ${shell.lookupPath(name)}\n`); break;
          case "alias": break;
        }
      }
    }
    return status;
  }
  if (rest.length === 0) return 0;
  return shell.runBypassFunc(rest[0]!, rest.slice(1));
};

const builtinBuiltin: Builtin = async (shell, ...args) => {
  if (args.length === 0) return 0;
  return shell.runBuiltin(args[0]!, args.slice(1));
};

const shopt: Builtin = (shell, ...args) => {
  let mode: "s" | "u" | "" = "";
  let quiet = false;
  let print = false;
  let oflag = false; // -o: operate on `set -o` options, not shopt options
  const names: string[] = [];
  for (const a of args) {
    if (a === "-s") mode = "s";
    else if (a === "-u") mode = "u";
    else if (a === "-q") quiet = true;
    else if (a === "-p") print = true;
    else if (a === "-o") oflag = true;
    else if (a.startsWith("-") && a.length > 1) continue;
    else names.push(a);
  }
  // `set -o` option namespace mapped onto shell.opts; unlisted ones are fixed.
  const setOpts: Record<string, boolean> = {
    braceexpand: true, emacs: false, errexit: shell.opts.errexit, errtrace: false,
    functrace: false, hashall: true, histexpand: false, history: false,
    ignoreeof: false, keyword: false, monitor: false, noclobber: shell.opts.noclobber,
    noexec: false, noglob: shell.opts.noglob, notify: false, nounset: shell.opts.nounset,
    onecmd: false, physical: false, pipefail: shell.opts.pipefail, posix: false,
    verbose: false, vi: false, xtrace: shell.opts.xtrace,
  };
  const setSetOpt = (n: string, on: boolean): void => {
    if (n === "errexit") shell.opts.errexit = on;
    else if (n === "nounset") shell.opts.nounset = on;
    else if (n === "xtrace") shell.opts.xtrace = on;
    else if (n === "pipefail") shell.opts.pipefail = on;
    else if (n === "noclobber") shell.opts.noclobber = on;
    else if (n === "noglob") shell.opts.noglob = on;
  };
  const state = (n: string): boolean | undefined => (oflag ? setOpts[n] : shell.shopts[n]);
  const line = (n: string, on: boolean): string =>
    print
      ? oflag ? `set ${on ? "-" : "+"}o ${n}\n` : `shopt -${on ? "s" : "u"} ${n}\n`
      : `${n.padEnd(15)}\t${on ? "on" : "off"}\n`;

  if (mode === "") {
    // Query / print. `shopt`/`shopt -q` returns 0 iff every named option is set.
    const list = names.length > 0 ? names : Object.keys(oflag ? setOpts : shell.shopts).sort();
    let status = 0;
    for (const n of list) {
      const on = state(n) ?? false;
      if (!quiet) shell.io.out(line(n, on));
      if (!on) status = 1;
    }
    return status;
  }
  for (const n of names) {
    if (oflag) setSetOpt(n, mode === "s");
    else shell.shopts[n] = mode === "s";
  }
  return 0;
};

const signalName = (s: string): string => {
  const up = s.toUpperCase();
  if (up === "0") return "EXIT";
  return up.startsWith("SIG") ? up.slice(3) : up;
};
const SIGNALS = new Set([
  "EXIT", "ERR", "DEBUG", "RETURN", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT",
  "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "CHLD",
  "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM",
  "PROF", "WINCH", "IO", "PWR", "SYS", "STKFLT",
]);
const isSignalSpec = (s: string): boolean => SIGNALS.has(signalName(s)) || /^[0-9]+$/.test(s);

const trap: Builtin = (shell, ...args) => {
  const quote = (h: string): string => "'" + h.replace(/'/g, "'\\''") + "'";
  const pseudo = new Set(["EXIT", "ERR", "DEBUG", "RETURN"]);
  const printTraps = (names: string[]): void => {
    for (const n of names) {
      const h = shell.traps[n];
      if (h !== undefined) shell.io.out(`trap -- ${quote(h)} ${pseudo.has(n) ? n : "SIG" + n}\n`);
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
  if (rest.length === 0) return 0;
  // When the first operand is itself a signal (or `-`), every operand is a
  // signal to reset (`trap EXIT`, `trap 0 INT`, `trap - INT TERM`).
  if (rest[0] === "-" || isSignalSpec(rest[0]!)) {
    for (const s of rest[0] === "-" ? rest.slice(1) : rest) delete shell.traps[signalName(s)];
    return 0;
  }
  const action = rest[0]!;
  for (const s of rest.slice(1)) shell.traps[signalName(s)] = action;
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

const UNARY = new Set([
  "-z", "-n", "-e", "-a", "-f", "-d", "-s", "-r", "-w", "-x", "-h", "-L",
  "-b", "-c", "-p", "-S", "-k", "-g", "-u", "-t", "-v", "-o", "-G", "-O", "-N", "-R",
]);
const BINARY = new Set([
  "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef",
]);

const unaryTest = (op: string, arg: string, shell: Shell): boolean => {
  if (op === "-z") return arg.length === 0;
  if (op === "-n") return arg.length > 0;
  if (op === "-t") return false; // stdio is piped in this environment
  if (op === "-v" || op === "-R") return shell.isSet(arg);
  if (op === "-o") return false; // shell option — unsupported
  const p = resolve(shell.cwd, arg);
  const st = statOf(p);
  const mode = st?.mode ?? 0;
  switch (op) {
    case "-e": case "-a": return st !== null;
    case "-f": return st?.isFile() ?? false;
    case "-d": return st?.isDirectory() ?? false;
    case "-b": return st?.isBlockDevice() ?? false;
    case "-c": return st?.isCharacterDevice() ?? false;
    case "-p": return st?.isFIFO() ?? false;
    case "-S": return st?.isSocket() ?? false;
    case "-s": return (st?.size ?? 0) > 0;
    case "-r": return canAccess(p, constants.R_OK);
    case "-w": return canAccess(p, constants.W_OK);
    case "-x": return canAccess(p, constants.X_OK);
    case "-k": return st !== null && (mode & 0o1000) !== 0; // sticky
    case "-g": return st !== null && (mode & 0o2000) !== 0; // setgid
    case "-u": return st !== null && (mode & 0o4000) !== 0; // setuid
    case "-G": return st !== null && st.gid === process.getgid?.();
    case "-O": return st !== null && st.uid === process.getuid?.();
    case "-N": return st !== null && st.mtimeMs > st.atimeMs;
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
    case "-nt": return (statOf(a)?.mtimeMs ?? -Infinity) > (statOf(b)?.mtimeMs ?? -Infinity);
    case "-ot": return (statOf(a)?.mtimeMs ?? -Infinity) < (statOf(b)?.mtimeMs ?? -Infinity);
    case "-ef": {
      const x = statOf(a), y = statOf(b);
      return x !== null && y !== null && x.dev === y.dev && x.ino === y.ino;
    }
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
  // bash's argc-based rules (test.c) for 0–2 args, where an operator name can
  // itself be an operand.
  switch (a.length) {
    case 0:
      return false;
    case 1:
      return a[0]!.length > 0;
    case 2:
      if (a[0] === "!") return !(a[1]!.length > 0);
      if (UNARY.has(a[0]!)) return unaryTest(a[0]!, a[1]!, shell);
      throw new Error(`${a[0]}: unary operator expected`);
  }
  // 3+ args: `-a`/`-o` at the top level bind the whole expression.
  if (a.includes("-a") || a.includes("-o")) {
    return splitTop(a, "-o").some((orPart) =>
      splitTop(orPart, "-a").every((andPart) => evalTest(andPart, shell)),
    );
  }
  switch (a.length) {
    case 3:
      if (BINARY.has(a[1]!)) return binaryTest(a[0]!, a[1]!, a[2]!);
      if (a[0] === "!") return !evalTest(a.slice(1), shell);
      if (a[0] === "(" && a[2] === ")") return evalTest([a[1]!], shell);
      throw new Error(`${a[1]}: binary operator expected`);
    case 4:
      if (a[0] === "!") return !evalTest(a.slice(1), shell);
      if (a[0] === "(" && a[3] === ")") return evalTest(a.slice(1, 3), shell);
      throw new Error("too many arguments");
    default:
      throw new Error("too many arguments");
  }
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
  eval: evalBuiltin,
  source: sourceBuiltin,
  ".": sourceBuiltin,
  let: letBuiltin,
  break: breakBuiltin,
  continue: continueBuiltin,
  getopts,
  wait,
  set: setBuiltin,
  declare: declareBuiltin,
  typeset: declareBuiltin,
  readonly: readonlyBuiltin,
  read,
  trap,
  shopt,
  type,
  command,
  builtin: builtinBuiltin,
  mapfile,
  readarray: mapfile,
  test,
  "[": bracket,
};
