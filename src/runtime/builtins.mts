/* Shell builtins — the M0 subset. Behaviour follows bash (GPLv3+; see
 * NOTICE.md). argv[0] is the builtin name; arguments begin at argv[1]. */

import { resolve } from "node:path";
import { statSync } from "node:fs";
import type { Shell } from "./shell.mts";

export type Builtin = (argv: string[], shell: Shell) => number | Promise<number>;

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
  const n = t.startsWith("0x") || t.startsWith("0X")
    ? parseInt(t, 16)
    : parseInt(t, 10);
  return Number.isNaN(n) ? 0 : n;
};

const echo: Builtin = (argv, shell) => {
  let args = argv.slice(1);
  let newline = true;
  let escapes = false;
  while (args.length > 0 && /^-[neE]+$/.test(args[0]!)) {
    for (const ch of args[0]!.slice(1)) {
      if (ch === "n") newline = false;
      else if (ch === "e") escapes = true;
      else if (ch === "E") escapes = false;
    }
    args = args.slice(1);
  }
  let text = args.join(" ");
  if (escapes) {
    const r = unescape(text);
    text = r.text;
    if (r.stop) newline = false;
  }
  shell.io.out(text + (newline ? "\n" : ""));
  return 0;
};

const printf: Builtin = (argv, shell) => {
  const args = argv.slice(1);
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
        const r = unescape(fmt.slice(i, i + 2));
        out += r.text;
        i += 2;
        continue;
      }
      if (c !== "%") {
        out += c;
        i++;
        continue;
      }
      // %[flags][width][.prec]conv  — flags/width/prec parsed but mostly ignored in M0
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

const pwd: Builtin = (_argv, shell) => {
  shell.io.out(shell.cwd + "\n");
  return 0;
};

const cd: Builtin = (argv, shell) => {
  const target = argv[1] ?? shell.getVar("HOME") ?? "";
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

const exportBuiltin: Builtin = (argv, shell) => {
  for (const a of argv.slice(1)) {
    const eq = a.indexOf("=");
    if (eq >= 0) {
      const name = a.slice(0, eq);
      shell.setVar(name, a.slice(eq + 1));
      shell.markExport(name);
    } else {
      shell.markExport(a);
    }
  }
  return 0;
};

const unset: Builtin = (argv, shell) => {
  for (const a of argv.slice(1)) shell.unset(a);
  return 0;
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
  unset,
};
