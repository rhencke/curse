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

const isHexDigit = (ch: string | undefined): boolean =>
  ch !== undefined && /[0-9a-fA-F]/.test(ch);
const isOctDigit = (ch: string | undefined): boolean => ch !== undefined && ch >= "0" && ch <= "7";

/** Decode one C-style backslash escape at `s[i]` (`s[i] === "\\"`). Returns the
 *  decoded text, the index just past it, and whether it was `\c` (stop). When
 *  `octalBare` (printf `%b` / a printf format string), `\NNN` without a leading
 *  0 is octal too; `echo -e` requires the `\0NNN` form. */
const decodeEscape = (
  s: string, i: number, octalBare: boolean, cStop: boolean,
): { text: string; next: number; stop: boolean } => {
  const e = s[i + 1];
  if (e === undefined) return { text: "\\", next: i + 1, stop: false };
  let j = i + 2;
  const simple: Record<string, string> = {
    n: "\n", t: "\t", r: "\r", "\\": "\\", a: "\x07", b: "\b", f: "\f", v: "\v", e: "\x1b",
  };
  if (e in simple) return { text: simple[e]!, next: j, stop: false };
  // `\c` ends output for echo -e and printf %b, but is literal in a printf format.
  if (e === "c" && cStop) return { text: "", next: j, stop: true };
  if (e === "0" || (octalBare && e >= "1" && e <= "7")) {
    let oct = e === "0" ? "" : e;
    while (oct.length < 3 && isOctDigit(s[j])) { oct += s[j]; j++; }
    return { text: String.fromCharCode((oct === "" ? 0 : parseInt(oct, 8)) & 0xff), next: j, stop: false };
  }
  if (e === "x") {
    let hex = "";
    while (hex.length < 2 && isHexDigit(s[j])) { hex += s[j]; j++; }
    if (hex === "") return { text: "\\x", next: j, stop: false };
    return { text: String.fromCharCode(parseInt(hex, 16) & 0xff), next: j, stop: false };
  }
  if (e === "u" || e === "U") {
    const max = e === "u" ? 4 : 8;
    let hex = "";
    while (hex.length < max && isHexDigit(s[j])) { hex += s[j]; j++; }
    if (hex === "") return { text: "\\" + e, next: j, stop: false };
    const cp = parseInt(hex, 16);
    return { text: cp <= 0x10ffff ? String.fromCodePoint(cp) : "�", next: j, stop: false };
  }
  return { text: "\\" + e, next: j, stop: false };
};

/** Process C-style backslash escapes (for `echo -e`, `printf %b`). */
const unescape = (s: string, octalBare = false): { text: string; stop: boolean } => {
  let out = "";
  let i = 0;
  while (i < s.length) {
    if (s[i] !== "\\") { out += s[i]; i++; continue; }
    const r = decodeEscape(s, i, octalBare, true); // echo -e / %b: \c ends output
    out += r.text;
    i = r.next;
    if (r.stop) return { text: out, stop: true };
  }
  return { text: out, stop: false };
};

const toInt = (s: string): number => {
  const t = s.trim();
  if (t === "") return 0;
  const n = t.startsWith("0x") || t.startsWith("0X") ? parseInt(t, 16) : parseInt(t, 10);
  return Number.isNaN(n) ? 0 : n;
};

// `test`/`[` numeric comparisons use bash's legal_number (strtoimax base 10),
// NOT arithmetic: plain signed decimal, surrounding whitespace allowed, leading
// `0` is still decimal (no octal/hex/base-N), and no expressions. Anything else
// is an "integer expression expected" error — caught by testImpl as status 2.
// 64-bit range via BigInt so large operands compare exactly like bash.
const testInt = (s: string): bigint => {
  const m = /^\s*([+-]?[0-9]+)\s*$/.exec(s);
  if (m === null) throw new Error(`${s}: integer expression expected`);
  return BigInt(m[1]!);
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
const S64MAX = (1n << 63n) - 1n;
const S64MIN = -(1n << 63n);
// bash's printf parses with strtoimax/strtoumax, which clamp on overflow rather
// than wrap: %d/%i saturate to the signed 64-bit range; %u/%x/%X/%o saturate to
// the unsigned max but wrap a negative input as two's complement.
const clampS = (v: bigint): bigint => (v > S64MAX ? S64MAX : v < S64MIN ? S64MIN : v);
const clampU = (v: bigint): bigint => (v < 0n ? v & U64 : v > U64 ? U64 : v);
const pfNum = (shell: Shell, raw: string, onErr?: () => void): bigint => {
  const t = raw.replace(/^[ \t\n]+/, "");
  if (t === "") return 0n;
  if (t[0] === "'" || t[0] === '"') return BigInt(t.codePointAt(1) ?? 0);
  const m = /^[+-]?(0[xX][0-9a-fA-F]+|0[0-7]+|[0-9]+)/.exec(t);
  if (m === null) {
    shell.io.err(`printf: ${raw}: invalid number\n`);
    onErr?.();
    return 0n;
  }
  let str = m[0];
  const neg = str[0] === "-";
  if (str[0] === "+" || str[0] === "-") str = str.slice(1);
  let val: bigint;
  if (/^0[xX]/.test(str)) val = BigInt(str);
  else if (/^0[0-7]+$/.test(str)) val = BigInt("0o" + str.slice(1));
  else val = BigInt(str);
  // A valid numeric prefix followed by leftover characters (e.g. `3abc`,
  // `64#a`, or a trailing space) is an error in bash, but the parsed value is
  // still emitted.
  if (m[0].length !== t.length) {
    shell.io.err(`printf: ${raw}: value not completely converted\n`);
    onErr?.();
  }
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

/** strftime for printf `%(FORMAT)T`. Uses Intl for timezone-aware components
 *  (honoring $TZ); supports the common conversions. */
const strftime = (f: string, epoch: number, tz: string | undefined): string => {
  const d = new Date(epoch * 1000);
  const zone = tz !== undefined && tz !== "" ? tz : undefined;
  const p: Record<string, string> = {};
  try {
    const dtf = new Intl.DateTimeFormat("en-US", {
      timeZone: zone, hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", weekday: "long",
    });
    for (const part of dtf.formatToParts(d)) p[part.type] = part.value;
  } catch {
    return f; // invalid TZ: best effort
  }
  const name = (opt: Intl.DateTimeFormatOptions): string => {
    try {
      return new Intl.DateTimeFormat("en-US", { timeZone: zone, ...opt }).format(d);
    } catch {
      return "";
    }
  };
  return f.replace(/%(.)/g, (_m, c: string): string => {
    switch (c) {
      case "Y": return p.year ?? "";
      case "y": return (p.year ?? "").slice(-2);
      case "m": return p.month ?? "";
      case "d": return p.day ?? "";
      case "e": return String(Number(p.day)).padStart(2, " ");
      case "H": return p.hour === "24" ? "00" : (p.hour ?? "");
      case "M": return p.minute ?? "";
      case "S": return p.second ?? "";
      case "A": return p.weekday ?? "";
      case "a": return name({ weekday: "short" });
      case "B": return name({ month: "long" });
      case "b": case "h": return name({ month: "short" });
      case "Z": return name({ timeZoneName: "short" }).split(" ").pop() ?? "";
      case "%": return "%";
      case "n": return "\n";
      case "t": return "\t";
      default: return "%" + c;
    }
  });
};

const printf: Builtin = async (shell, ...args) => {
  // Options: `-v VAR` captures the output into a variable (or array element)
  // instead of stdout; `--` ends option processing.
  let target: string | null = null;
  while (args.length > 0) {
    if (args[0] === "-v" && args.length >= 2) { target = args[1]!; args = args.slice(2); continue; }
    if (args[0] === "--") { args = args.slice(1); break; }
    break;
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
  let status = 0; // 1 if any argument was an invalid number or format char
  let stopped = false; // a `\c` in the format string or a %b argument ends output
  const once = (): void => {
    let i = 0;
    while (i < fmt.length) {
      if (stopped) return;
      const c = fmt[i]!;
      if (c === "\\") {
        const r = decodeEscape(fmt, i, true, false); // format string: \c is literal
        out += r.text;
        i = r.next;
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
      // `floatVal` values already carry their precision (decimal places), so
      // skip the integer min-digits step and allow 0-padding despite precision.
      const format = (s: string, numeric: boolean, floatVal = false): string => {
        if (hasPrec && !floatVal) {
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
        if (flags.includes("0") && numeric && (!hasPrec || floatVal)) {
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
        const alt = flags.includes("#");
        let s = n.toPrecision(p);
        if (s.includes("e")) s = s.replace(/e([+-])(\d)$/, "e$10$2");
        // %g trims trailing zeros, but the `#` flag keeps them (and the point).
        else if (!alt && s.includes(".")) s = s.replace(/\.?0+$/, "");
        else if (alt && !s.includes(".")) s += ".";
        return upper ? s.toUpperCase() : s;
      };
      const num = (raw: string): bigint => pfNum(shell, raw, () => { status = 1; });
      switch (conv) {
        case "s": out += format(nextArg(), false); break;
        case "b": { const r = unescape(nextArg(), true); out += format(r.text, false); if (r.stop) { stopped = true; return; } break; }
        case "d": case "i": { const n = clampS(num(nextArg())); out += format(sign(n, String(n)), true); break; }
        case "u": out += format(String(clampU(num(nextArg()))), true); break;
        case "x": out += format(alt("0x", clampU(num(nextArg())).toString(16)), true); break;
        case "X": out += format(alt("0X", clampU(num(nextArg())).toString(16).toUpperCase()), true); break;
        case "o": {
          const s = clampU(num(nextArg())).toString(8);
          out += format(flags.includes("#") && s[0] !== "0" ? "0" + s : s, true);
          break;
        }
        case "c": out += format(nextArg().slice(0, 1), false); break;
        case "q": out += format(shellBackslashQuote(nextArg()), false); break;
        case "(": {
          // %(FORMAT)T — strftime. The arg is epoch seconds; empty or negative
          // (-1/-2) means "now".
          const close = fmt.indexOf(")", j);
          if (close < 0 || fmt[close + 1] !== "T") {
            shell.io.err(`printf: \`%(': invalid format character\n`);
            status = 1; stopped = true; return;
          }
          const tfmt = fmt.slice(j + 1, close);
          j = close + 1; // now at 'T'
          const raw = nextArg();
          let epoch = raw === "" ? Math.floor(Date.now() / 1000) : Number(pfNum(shell, raw, () => { status = 1; }));
          if (!Number.isFinite(epoch) || epoch < 0) epoch = Math.floor(Date.now() / 1000);
          out += format(strftime(tfmt, epoch, shell.getVar("TZ")), false);
          break;
        }
        case "f": case "F": {
          const n = pfFloat(nextArg());
          let fs = n.toFixed(hasPrec ? (prec === "" ? 0 : parseInt(prec, 10)) : 6);
          if (flags.includes("#") && !fs.includes(".")) fs += "."; // # keeps the point
          out += format(sign(BigInt(Math.trunc(n)), fs), true, true);
          break;
        }
        case "e": case "E": { const n = pfFloat(nextArg()); out += format(sign(n >= 0 ? 0n : -1n, efmt(n, conv === "E")), true, true); break; }
        case "g": case "G": { const n = pfFloat(nextArg()); out += format(sign(n >= 0 ? 0n : -1n, gfmt(n, conv === "G")), true, true); break; }
        default:
          // An invalid conversion aborts printf, keeping only the output so far.
          shell.io.err(`printf: \`%${conv}': invalid format character\n`);
          status = 1;
          stopped = true;
          return;
      }
      i = j + 1;
    }
  };

  do {
    const before = vi;
    once();
    // If the format consumed no arguments, don't reuse it (bash avoids the
    // otherwise-infinite loop for e.g. `printf x y`).
    if (vi === before) break;
  } while (vi < values.length && !stopped);

  if (target !== null) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)\[([^\]]*)\]$/.exec(target);
    if (m) await shell.elemSet(m[1]!, m[2]!, out);
    else if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(target)) shell.setVar(target, out);
    else {
      shell.io.err(`printf: \`${target}': not a valid identifier\n`);
      return 2;
    }
    return status;
  }
  shell.io.out(out);
  return status;
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

/** umask as a 4-digit octal string, e.g. 0022. */
const umaskOctal = (mask: number): string => "0" + mask.toString(8).padStart(3, "0");
/** umask as symbolic *permissions* (the complement), e.g. u=rwx,g=rx,o=rx. */
const umaskSymbolic = (mask: number): string => {
  const allowed = ~mask & 0o777;
  const cls = (bits: number): string =>
    (bits & 4 ? "r" : "") + (bits & 2 ? "w" : "") + (bits & 1 ? "x" : "");
  return `u=${cls((allowed >> 6) & 7)},g=${cls((allowed >> 3) & 7)},o=${cls(allowed & 7)}`;
};
/** Apply chmod-style symbolic clauses to the current umask; null if malformed. */
const applyUmaskSymbolic = (mask: number, spec: string): number | null => {
  let allowed = ~mask & 0o777; // symbolic mode describes permissions, not the mask
  const shifts: Record<string, number> = { u: 6, g: 3, o: 0 };
  for (const clause of spec.split(",")) {
    const m = /^([ugoa]*)([-+=])([rwx]*)$/.exec(clause);
    if (m === null) return null;
    const who = m[1] === "" || m[1]!.includes("a") ? "ugo" : m[1]!;
    const op = m[2]!;
    const perm = (m[3]!.includes("r") ? 4 : 0) | (m[3]!.includes("w") ? 2 : 0) | (m[3]!.includes("x") ? 1 : 0);
    for (const w of new Set(who)) {
      const sh = shifts[w]!;
      const old = (allowed >> sh) & 7;
      const next = op === "+" ? old | perm : op === "-" ? old & ~perm : perm;
      allowed = (allowed & ~(7 << sh)) | (next << sh);
    }
  }
  return ~allowed & 0o777;
};

const umaskBuiltin: Builtin = (shell, ...args) => {
  let symbolic = false;
  let printForm = false;
  const rest: string[] = [];
  for (const a of args) {
    if (a === "-S") symbolic = true;
    else if (a === "-p") printForm = true;
    else if (a === "--") continue;
    else if (a.startsWith("-") && a !== "-") {
      // A leading `-` is an option; anything but -S/-p is an invalid option
      // (bash rejects `umask -rwx` with usage status 2, not as a clause).
      shell.io.err(`umask: ${a}: invalid option\numask: usage: umask [-p] [-S] [mode]\n`);
      return 2;
    }
    else rest.push(a);
  }
  const cur = process.umask();
  if (rest.length === 0) {
    const body = symbolic ? umaskSymbolic(cur) : umaskOctal(cur);
    shell.io.out((printForm ? `umask ${symbolic ? "-S " : ""}` : "") + body + "\n");
    return 0;
  }
  const spec = rest[0]!;
  let mask: number;
  if (/^[0-7]+$/.test(spec)) {
    const v = parseInt(spec, 8);
    if (v > 0o777) { shell.io.err(`umask: ${spec}: octal number out of range\n`); return 1; }
    mask = v;
  } else if (/^[0-9]+$/.test(spec)) {
    shell.io.err(`umask: ${spec}: invalid octal number\n`);
    return 1;
  } else {
    const applied = applyUmaskSymbolic(cur, spec);
    if (applied === null) { shell.io.err(`umask: ${spec}: invalid symbolic mode operator\n`); return 1; }
    mask = applied;
  }
  process.umask(mask);
  return 0;
};

/** Home-relative tilde form for `dirs` (unless -l / long format). */
const tildePath = (p: string, home: string | undefined): string => {
  if (home === undefined || home === "") return p;
  if (p === home) return "~";
  if (p.startsWith(home + "/")) return "~" + p.slice(home.length);
  return p;
};
/** Print the directory stack in the default (space-joined, tilde) format. */
const printDirs = (shell: Shell): void => {
  const home = shell.getVar("HOME");
  shell.io.out([shell.cwd, ...shell.dirStack].map((p) => tildePath(p, home)).join(" ") + "\n");
};

const dirs: Builtin = (shell, ...args) => {
  let long = false, perLine = false, verbose = false;
  for (const a of args) {
    if (a === "-c") { shell.dirStack = []; return 0; }
    else if (a === "-l") long = true;
    else if (a === "-p") perLine = true;
    else if (a === "-v") verbose = true;
    else if (a.startsWith("-")) { shell.io.err(`dirs: ${a}: invalid option\n`); return 2; }
    else { shell.io.err(`dirs: ${a}: invalid argument\n`); return 2; }
  }
  const home = shell.getVar("HOME");
  const full = [shell.cwd, ...shell.dirStack];
  const fmt = (p: string): string => (long ? p : tildePath(p, home));
  if (verbose) full.forEach((p, i) => shell.io.out(` ${i}  ${fmt(p)}\n`));
  else if (perLine) for (const p of full) shell.io.out(fmt(p) + "\n");
  else shell.io.out(full.map(fmt).join(" ") + "\n");
  return 0;
};

const pushd: Builtin = (shell, ...args) => {
  const dirArgs: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--") { for (let j = i + 1; j < args.length; j++) dirArgs.push(args[j]!); break; }
    if (a.startsWith("-") && a !== "-") {
      shell.io.err(`pushd: ${a}: invalid option\npushd: usage: pushd [-n] [+N | -N | dir]\n`);
      return 2;
    }
    dirArgs.push(a);
  }
  if (dirArgs.length > 1) { shell.io.err("pushd: too many arguments\n"); return 1; }
  const dir = dirArgs[0];
  if (dir === undefined) {
    // No directory: swap the top two entries.
    if (shell.dirStack.length === 0) { shell.io.err("pushd: no other directory\n"); return 1; }
    const other = shell.dirStack[0]!;
    shell.dirStack[0] = shell.cwd;
    const rc = cd(shell, other) as number;
    if (rc === 0) printDirs(shell);
    return rc;
  }
  const prev = shell.cwd;
  const rc = cd(shell, dir) as number;
  if (rc !== 0) return rc;
  shell.dirStack.unshift(prev);
  printDirs(shell);
  return 0;
};

const popd: Builtin = (shell, ...args) => {
  for (const a of args) {
    if (a === "--") continue;
    shell.io.err(`popd: ${a}: invalid argument\npopd: usage: popd [-n] [+N | -N]\n`);
    return 2;
  }
  if (shell.dirStack.length === 0) { shell.io.err("popd: directory stack empty\n"); return 1; }
  const target = shell.dirStack.shift()!;
  const rc = cd(shell, target) as number;
  if (rc === 0) printDirs(shell);
  return rc;
};

const exportBuiltin: Builtin = (shell, ...args) => {
  const nonFlag = args.filter((a) => !a.startsWith("-"));
  // `export` / `export -p` (no names) lists all exported variables.
  if (nonFlag.length === 0) {
    for (const line of shell.declareLinesWhere((v) => v.exported)) shell.io.out(line + "\n");
    return 0;
  }
  for (const a of nonFlag) {
    const { name, value, append } = splitNameVal(a);
    if (value !== undefined) {
      if (append) shell.appendVar(name, value);
      else shell.setVar(name, value);
    }
    shell.exportVar(name);
  }
  return 0;
};

const local: Builtin = (shell, ...args) => {
  const { flags, names } = parseDeclFlags(args);
  let status = 0;
  for (const n of names) {
    const { name, value, append } = splitNameVal(n);
    // A readonly variable can't be shadowed by a fresh local (bash errors).
    if (shell.isReadonly(name)) {
      shell.io.err(`${shell.name}: local: ${name}: readonly variable\n`);
      status = 1;
      continue;
    }
    // `local s+=x` appends to an existing local in this scope, but a first-time
    // `local` starts empty (it does not inherit an enclosing value).
    const isOwn = shell.isLocalOwn(name);
    const inherited = append && isOwn ? shell.getVar(name) ?? "" : "";
    // A fresh local resets to unset; re-declaring an existing own-local WITHOUT
    // a value keeps its current value (bash).
    if (value !== undefined || !isOwn) shell.local(name);
    if (flags.nameref) {
      if (!shell.setRef(name, value ?? "")) status = 1;
      continue;
    }
    shell.setAttrs(name, flags);
    if (value !== undefined) shell.setVar(name, append ? inherited + value : value);
  }
  return status;
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
      // `unset name` (no -v): a variable if one exists, otherwise a function.
      else if (mode === "" && !shell.varExists(a) && shell.hasFunction(a)) shell.unsetFunc(a);
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

const evalBuiltin: Builtin = (shell, ...args) => {
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--") { i++; break; }
    if (a === "-" || a[0] !== "-") break; // `-` and operands aren't options
    shell.io.err(`eval: ${a}: invalid option\neval: usage: eval [arg ...]\n`);
    return 2;
  }
  return shell.evalString(args.slice(i).join(" "));
};

/** Resolve a `source`/`.` filename: a name without `/` is searched along PATH
 *  (regular files only, PATH before the current dir); otherwise cwd-relative. */
const findSourceFile = (shell: Shell, file: string): string | null => {
  const isFile = (p: string): boolean => {
    try { return statSync(p).isFile(); } catch { return false; }
  };
  if (!file.includes("/")) {
    for (const dir of (shell.getVar("PATH") ?? "").split(":")) {
      if (dir === "") continue;
      const p = resolve(shell.cwd, dir, file);
      if (isFile(p)) return p;
    }
  }
  const direct = resolve(shell.cwd, file);
  return isFile(direct) ? direct : null;
};

const sourceBuiltin: Builtin = async (shell, ...args) => {
  if (args[0] === "--") args = args.slice(1);
  const file = args[0];
  if (file === undefined) {
    shell.io.err("source: filename argument required\n");
    return 2;
  }
  const path = findSourceFile(shell, file);
  if (path === null) {
    shell.io.err(`${shell.name}: ${file}: No such file or directory\n`);
    return 1;
  }
  const saved = shell.positional;
  if (args.length > 1) shell.positional = args.slice(1);
  try {
    return await shell.sourceFile(path);
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

// break/continue share an argument protocol: outside any loop they warn and
// return 0; a non-numeric count is a fatal error that exits the shell with 128
// (bash aborts, it does not merely break); a numeric count acts on that many.
const loopControl = (kind: "break" | "continue"): Builtin => (shell, ...args) => {
  if (shell.loopDepth <= 0) {
    shell.io.err(`${shell.name}: ${kind}: only meaningful in a \`for', \`while', or \`until' loop\n`);
    return 0;
  }
  if (args.length > 0 && !/^\s*[+-]?[0-9]+\s*$/.test(args[0]!)) {
    shell.io.err(`${shell.name}: ${kind}: ${args[0]}: numeric argument required\n`);
    throw new ExitSignal(128);
  }
  throw new LoopSignal(kind, args.length > 0 ? Math.max(1, toInt(args[0]!)) : 1);
};
const breakBuiltin: Builtin = loopControl("break");
const continueBuiltin: Builtin = loopControl("continue");

const getopts: Builtin = (shell, ...args) => {
  if (args.length < 2) {
    shell.io.err("getopts: usage: getopts optstring name [arg ...]\n");
    return 2;
  }
  const optstring = args[0]!;
  const name = args[1]!;
  // bash parses the option normally (advancing OPTIND/OPTARG) but fails the
  // assignment — status 1 — if the destination isn't a valid identifier.
  const validName = /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
  const store = (result: string): boolean => {
    if (validName) { shell.setVar(name, result); return true; }
    shell.io.err(`${shell.name}: getopts: \`${name}': not a valid identifier\n`);
    return false;
  };
  const words = args.length > 2 ? args.slice(2) : shell.positional;
  const silent = optstring.startsWith(":");
  const errPrint = !silent && shell.getVar("OPTERR") !== "0";

  let optind = toInt(shell.getVar("OPTIND") ?? "1");
  if (optind < 1) optind = 1;
  // An external `OPTIND=1` (reparse) restarts the per-word char scan.
  if (optind !== shell.optsInd) shell.optsPos = 1;

  const finish = (result: string, optarg: string | null): number => {
    const ok = store(result);
    if (optarg === null) shell.unsetVar("OPTARG");
    else shell.setVar("OPTARG", optarg);
    shell.setVar("OPTIND", String(optind));
    shell.optsInd = optind;
    return ok ? 0 : 1;
  };
  const noMore = (reset = false): number => {
    shell.optsPos = 1;
    // Calling getopts with no arguments at all rewinds OPTIND to 1 (bash);
    // scanning a non-empty list to its end, or stopping at a non-option / `--`,
    // leaves OPTIND pointing where it stopped.
    if (reset) optind = 1;
    shell.setVar("OPTIND", String(optind));
    shell.optsInd = optind;
    store("?");
    shell.unsetVar("OPTARG");
    return 1;
  };

  for (;;) {
    if (optind > words.length) return noMore(words.length === 0);
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
/** Split an assignment-builtin operand `name[+]=value` into its parts. */
const splitNameVal = (n: string): { name: string; value: string | undefined; append: boolean } => {
  const eq = n.indexOf("=");
  if (eq < 0) return { name: n, value: undefined, append: false };
  let name = n.slice(0, eq);
  const append = name.endsWith("+");
  if (append) name = name.slice(0, -1);
  return { name, value: n.slice(eq + 1), append };
};

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
  // declare -p [name...]: print definitions (`p` may be bundled, e.g. -pa).
  if (dashFlags.some((f) => f[0] === "-" && f.includes("p"))) {
    const targets = args.filter((a) => a[0] !== "-" && a[0] !== "+").map((a) => {
      const eq = a.indexOf("=");
      return eq >= 0 ? a.slice(0, eq) : a;
    });
    // `declare -p` with no names prints every variable in declare form; any
    // attribute flags (declare -pa, -pA, -pi, -pr, …) restrict it to variables
    // that carry all of those attributes.
    if (targets.length === 0) {
      const letters = dashFlags
        .filter((f) => f[0] === "-")
        .flatMap((f) => [...f.slice(1)])
        .filter((c) => "aAilurxn".includes(c));
      const pred = (v: { arr: unknown; assoc: unknown; integer: boolean; lower: boolean; upper: boolean; readonly: boolean; exported: boolean; ref: boolean }): boolean =>
        letters.every((c) =>
          c === "a" ? v.arr !== null
          : c === "A" ? v.assoc !== null
          : c === "i" ? v.integer
          : c === "l" ? v.lower
          : c === "u" ? v.upper
          : c === "r" ? v.readonly
          : c === "x" ? v.exported
          : v.ref);
      for (const line of shell.declareLinesWhere(pred)) shell.io.out(line + "\n");
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
  let status = 0;
  for (const n of names) {
    const { name, value, append } = splitNameVal(n);
    // A target must be a valid identifier or an array-element reference.
    if (!/^[A-Za-z_][A-Za-z0-9_]*(\[.*\])?$/.test(name)) {
      shell.io.err(`${shell.name}: declare: \`${name}': not a valid identifier\n`);
      status = 1;
      continue;
    }
    const existed = shell.varExists(name);
    if (clearRef) { shell.clearRef(name); continue; }
    if (flags.nameref) {
      if (!shell.setRef(name, value ?? "")) status = 1;
      continue;
    }
    // Establish array/assoc shape before setAttrs, so an empty `declare -a x`
    // stays a 0-element array rather than a "" scalar.
    if (flags.assoc) shell.declareAssoc(name);
    else if (value === undefined && flags.array && shell.arrayLen(name) === 0) shell.setArray(name, []);
    // Apply -i/-l/-u before the value (so it's coerced), but readonly after
    // (so this very assignment isn't rejected).
    shell.setAttrs(name, { ...flags, readonly: false });
    if (value !== undefined) { if (append) shell.appendVar(name, value); else shell.setVar(name, value); }
    // `declare x` on a not-yet-existing scalar declares it but leaves it unset
    // (bash), so `${x+set}` is empty and `declare -p x` prints no `=value`.
    else if (!existed && !flags.array && !flags.assoc) shell.markUnset(name);
    if (flags.readonly) shell.setAttrs(name, { readonly: true });
    if (flags.exported) shell.exportVar(name);
  }
  return status;
};

const readonlyBuiltin: Builtin = (shell, ...args) => {
  const nonFlag = args.filter((a) => !a.startsWith("-"));
  // `readonly` / `readonly -p` (no names) lists all readonly variables.
  if (nonFlag.length === 0) {
    for (const line of shell.declareLinesWhere((v) => v.readonly)) shell.io.out(line + "\n");
    return 0;
  }
  for (const a of nonFlag) {
    const { name, value, append } = splitNameVal(a);
    if (value !== undefined) {
      if (append) shell.appendVar(name, value);
      else shell.setVar(name, value);
    }
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
  let poll = false; // -t 0: test availability without consuming
  const names: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--") continue;
    if (!(a.length > 1 && a[0] === "-")) { names.push(a); continue; }
    // A cluster of short flags; a value-taking flag consumes the rest of the
    // cluster (smooshed, `-n3`) or, if none, the next word (`-n 3`, `-rd ''`).
    for (let k = 1; k < a.length; k++) {
      const c = a[k]!;
      const takeVal = (): string => {
        const rest = a.slice(k + 1);
        return rest !== "" ? rest : (args[++i] ?? "");
      };
      if (c === "r") raw = true;
      else if (c === "s") { /* silent: no tty here */ }
      else if (c === "a") { arrayName = takeVal(); break; }
      else if (c === "d") { const d = takeVal(); delim = d === "" ? "\0" : d[0]!; break; }
      else if (c === "n") { nchars = toInt(takeVal()); break; }
      else if (c === "N") { exactN = toInt(takeVal()); break; }
      else if (c === "p") { shell.io.err(takeVal()); break; }
      else if (c === "t") {
        // `-t 0` is a non-blocking availability poll; any other timeout just
        // reads (we can't truly wait, so an exhausted stream reports EOF).
        if (parseFloat(takeVal()) === 0) poll = true;
        break;
      }
      else if (c === "u") { takeVal(); break; }
      // other flags: ignored
    }
  }

  // `-t 0`: succeed iff input is available (readable, EOF included), consuming
  // nothing and leaving REPLY/vars untouched — matching bash's select(2) poll.
  if (poll) return shell.stdinData !== null ? 0 : 1;

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
  let showType = false, pathOnly = false, forcePath = false, all = false, noFunc = false;
  const names: string[] = [];
  for (const a of args) {
    if (a === "--") continue;
    if (a.length > 1 && a[0] === "-") {
      for (const ch of a.slice(1)) {
        if (ch === "t") showType = true;
        else if (ch === "p") pathOnly = true;
        else if (ch === "P") { forcePath = true; pathOnly = true; }
        else if (ch === "a") all = true;
        else if (ch === "f") noFunc = true;
      }
      continue;
    }
    names.push(a);
  }
  let status = 0;
  for (const name of names) {
    const isFunc = !noFunc && shell.hasFunction(name);
    const isKeyword = KEYWORDS.has(name);
    const isBuiltin = !isFunc && shell.hasBuiltin(name);
    const paths = forcePath || pathOnly || all ? shell.lookupAllPaths(name) : [];
    const firstPath = paths[0] ?? (classify(shell, name) === "file" ? shell.lookupPath(name) : null);
    const found = isFunc || isKeyword || isBuiltin || firstPath !== null || paths.length > 0;
    if (!found) {
      // bash prints the diagnostic only in long form (not with -t or -p/-P).
      if (!showType && !pathOnly) shell.io.err(`${shell.name}: type: ${name}: not found\n`);
      status = 1;
      continue;
    }
    if (showType) {
      // -t reports one word (function first, else keyword/builtin/file).
      const t = isFunc ? "function" : isKeyword ? "keyword" : isBuiltin ? "builtin" : "file";
      shell.io.out(t + "\n");
      continue;
    }
    if (pathOnly) {
      // -p/-P print only file paths (nothing for function/keyword/builtin).
      for (const p of all ? paths : firstPath !== null ? [firstPath] : []) shell.io.out(p + "\n");
      continue;
    }
    // Long form: list the first match, or (with -a) every match in order.
    if (isFunc) shell.io.out(`${name} is a function\n`);
    if (isKeyword && (all || !isFunc)) shell.io.out(`${name} is a shell keyword\n`);
    if (isBuiltin && (all || (!isFunc && !isKeyword))) shell.io.out(`${name} is a shell builtin\n`);
    if (all) for (const p of paths) shell.io.out(`${name} is ${p}\n`);
    else if (!isFunc && !isKeyword && !isBuiltin && firstPath !== null) shell.io.out(`${name} is ${firstPath}\n`);
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
      if (kind === null) {
        // command -V reports the failure; command -v is silent.
        if (verbose === "V") shell.io.err(`${shell.name}: command: ${name}: not found\n`);
        status = 1;
        continue;
      }
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
  if (args[0] === "--") args = args.slice(1);
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

  const badOpt = (n: string): void =>
    shell.io.err(`${shell.name}: shopt: ${n}: invalid ${oflag ? "option name" : "shell option name"}\n`);

  if (mode === "") {
    // Query / print. `shopt`/`shopt -q` returns 0 iff every named option is set;
    // an unknown option name is an error (status 1) with nothing printed.
    const list = names.length > 0 ? names : Object.keys(oflag ? setOpts : shell.shopts).sort();
    let status = 0;
    for (const n of list) {
      const st = state(n);
      if (st === undefined) { badOpt(n); status = 1; continue; }
      if (!quiet) shell.io.out(line(n, st));
      // A specific query fails if the option is off; listing them all is status 0.
      if (!st && names.length > 0) status = 1;
    }
    return status;
  }
  let status = 0;
  for (const n of names) {
    if (state(n) === undefined) { badOpt(n); status = 1; continue; }
    if (oflag) setSetOpt(n, mode === "s");
    else shell.shopts[n] = mode === "s";
  }
  return status;
};

// Signal numbers → canonical names (Linux/glibc, matching the dev image); `0` is
// the EXIT pseudo-signal. `trap` normalizes a numeric spec to its name so
// `trap 2` and `trap INT`/`trap SIGINT` are the same key and `trap -p` prints
// the full name (SIGINT), like bash.
const SIGNUMS: Record<string, string> = {
  "0": "EXIT", "1": "HUP", "2": "INT", "3": "QUIT", "4": "ILL", "5": "TRAP",
  "6": "ABRT", "7": "BUS", "8": "FPE", "9": "KILL", "10": "USR1", "11": "SEGV",
  "12": "USR2", "13": "PIPE", "14": "ALRM", "15": "TERM", "16": "STKFLT",
  "17": "CHLD", "18": "CONT", "19": "STOP", "20": "TSTP", "21": "TTIN",
  "22": "TTOU", "23": "URG", "24": "XCPU", "25": "XFSZ", "26": "VTALRM",
  "27": "PROF", "28": "WINCH", "29": "IO", "30": "PWR", "31": "SYS",
};
const signalName = (s: string): string => {
  if (/^[0-9]+$/.test(s)) return SIGNUMS[s] ?? s;
  const up = s.toUpperCase();
  return up.startsWith("SIG") ? up.slice(3) : up;
};
// Name → number, so `trap`/`trap -p` can list handlers in bash's signal-number
// order (EXIT=0, INT=2, …); the pseudo-signals sort after the real ones.
const SIGNUM_OF: Record<string, number> = Object.fromEntries(
  Object.entries(SIGNUMS).map(([n, name]) => [name, Number(n)]),
);
const signalOrder = (name: string): number =>
  SIGNUM_OF[name] ?? ({ ERR: 100, DEBUG: 101, RETURN: 102 } as Record<string, number>)[name] ?? 200;
const SIGNALS = new Set([
  "EXIT", "ERR", "DEBUG", "RETURN", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT",
  "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "CHLD",
  "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM",
  "PROF", "WINCH", "IO", "PWR", "SYS", "STKFLT",
]);
const isSignalSpec = (s: string): boolean => SIGNALS.has(signalName(s));

const trap: Builtin = (shell, ...args) => {
  const quote = (h: string): string => "'" + h.replace(/'/g, "'\\''") + "'";
  const pseudo = new Set(["EXIT", "ERR", "DEBUG", "RETURN"]);
  const printTraps = (names: string[]): void => {
    for (const n of names) {
      const h = shell.traps[n];
      if (h !== undefined) shell.io.out(`trap -- ${quote(h)} ${pseudo.has(n) ? n : "SIG" + n}\n`);
    }
  };
  // `trap` / `trap -p [sig...]`: print current handlers. A bare listing is
  // ordered by signal number (bash); explicit specs print in the given order.
  if (args.length === 0 || args[0] === "-p") {
    const specs = args.slice(args[0] === "-p" ? 1 : 0);
    const all = Object.keys(shell.traps).sort((a, b) => signalOrder(a) - signalOrder(b));
    printTraps(specs.length > 0 ? specs.map(signalName) : all);
    return 0;
  }
  if (args[0] === "-l") return 0; // signal listing: not supported
  let rest = args;
  if (rest[0] === "--") rest = rest.slice(1);
  if (rest.length === 0) return 0;
  // When the first operand is itself a signal (or `-`), every operand is a
  // signal to reset (`trap EXIT`, `trap 0 INT`, `trap - INT TERM`).
  const reset = rest[0] === "-" || isSignalSpec(rest[0]!);
  const sigs = reset ? (rest[0] === "-" ? rest.slice(1) : rest) : rest.slice(1);
  if (!reset && sigs.length === 0) {
    shell.io.err("trap: usage: trap [-lp] [[arg] signal_spec ...]\n");
    return 2;
  }
  const action = reset ? "" : rest[0]!;
  let status = 0;
  for (const s of sigs) {
    if (!isSignalSpec(s)) {
      shell.io.err(`${shell.name}: trap: ${s}: invalid signal specification\n`);
      status = 1;
      continue;
    }
    if (reset) delete shell.traps[signalName(s)];
    else shell.traps[signalName(s)] = action;
  }
  return status;
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
  if (op === "-o") return shell.setOption(arg) === true; // `set -o` option is on
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
    case "-eq": return testInt(a) === testInt(b);
    case "-ne": return testInt(a) !== testInt(b);
    case "-lt": return testInt(a) < testInt(b);
    case "-le": return testInt(a) <= testInt(b);
    case "-gt": return testInt(a) > testInt(b);
    case "-ge": return testInt(a) >= testInt(b);
    default: throw new Error(`${op}: binary operator expected`);
  }
};

const isBinop = (op: string | undefined): boolean => op !== undefined && BINARY.has(op);

// bash's `test`/`[` grammar (test.c). Historical rules special-case 0–3 args,
// where an operator name may itself be an operand (`test -o != --`); 4+ args go
// through a recursive-descent parser in which `-a`/`-o` bind as AND/OR.
const evalTest = (args: string[], shell: Shell): boolean => {
  const one = (s: string): boolean => s.length > 0;
  const two = (a: string[]): boolean => {
    if (a[0] === "!") return !one(a[1]!);
    if (UNARY.has(a[0]!)) return unaryTest(a[0]!, a[1]!, shell);
    throw new Error(`${a[0]}: unary operator expected`);
  };
  const three = (a: string[]): boolean => {
    if (isBinop(a[1])) return binaryTest(a[0]!, a[1]!, a[2]!);
    if (a[1] === "-a") return one(a[0]!) && one(a[2]!);
    if (a[1] === "-o") return one(a[0]!) || one(a[2]!);
    if (a[0] === "!") return !two(a.slice(1));
    if (a[0] === "(" && a[2] === ")") return one(a[1]!);
    throw new Error(`${a[1]}: binary operator expected`);
  };

  // Recursive-descent parser for the general (4+ argument) form.
  let pos = 0;
  const orExpr = (): boolean => {
    let v = andExpr();
    while (pos < args.length && args[pos] === "-o") { pos++; const r = andExpr(); v = v || r; }
    return v;
  };
  const andExpr = (): boolean => {
    let v = term();
    while (pos < args.length && args[pos] === "-a") { pos++; const r = term(); v = v && r; }
    return v;
  };
  const term = (): boolean => {
    if (pos >= args.length) throw new Error("argument expected");
    if (args[pos] === "!") { pos++; return !term(); }
    if (args[pos] === "(") {
      pos++;
      const v = orExpr();
      if (args[pos] !== ")") throw new Error("`)' expected");
      pos++;
      return v;
    }
    const rem = args.length - pos;
    if (rem >= 3 && isBinop(args[pos + 1])) {
      const v = binaryTest(args[pos]!, args[pos + 1]!, args[pos + 2]!);
      pos += 3;
      return v;
    }
    if (rem >= 2 && UNARY.has(args[pos]!)) {
      const v = unaryTest(args[pos]!, args[pos + 1]!, shell);
      pos += 2;
      return v;
    }
    return one(args[pos++]!);
  };

  switch (args.length) {
    case 0: return false;
    case 1: return one(args[0]!);
    case 2: return two(args);
    case 3: return three(args);
    default: {
      const v = orExpr();
      if (pos !== args.length) throw new Error("too many arguments");
      return v;
    }
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
  dirs,
  pushd,
  popd,
  umask: umaskBuiltin,
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
