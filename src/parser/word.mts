/* Word structure parser.
 *
 * Turns a raw word token (quotes preserved, faithful to bash's WORD_DESC) into
 * a list of typed parts. Both consumers work from this one structure:
 *   - the runtime interpreter evaluates parts into fields (expand.mts)
 *   - the AOT emitter compiles parts into TypeScript expressions (compiler/)
 *
 * A part carries `quoted`: an expansion inside double quotes (or from `${}` in
 * a quoted context) is not subject to field splitting. Literal text never
 * splits. This is the M0–M1 subset of bash's expansion grammar. */

import { scanCmdSub } from "./scan.mts";

/** A parameter reference `$name` / `${...}`, with optional expansion operator. */
export interface Param {
  name: string; // variable name, or a special/positional: ? $ # @ * 0-9
  special: boolean;
  length: boolean; // ${#name}
  indices: boolean; // ${!name[@]}
  indirect: boolean; // ${!name}
  names: string; // ${!prefix*}/${!prefix@} name matching: "" | "*" | "@"
  sub: string; // array subscript inside [ ] ("" if none)
  /** "" | :- - :+ + := = :? ? # ## % %% / // /# /% : (substring) */
  op: string;
  arg: string; // operand raw text (default / pattern / offset)
  arg2: string; // replacement text, or substring length
}

export type WordPart =
  | { k: "lit"; s: string } // literal text (quote-removed); never splits
  | { k: "param"; p: Param; quoted: boolean } // $name / ${...}
  | { k: "arith"; expr: string; quoted: boolean } // $(( expr ))
  | { k: "cmdsub"; src: string; quoted: boolean } // $( cmds )
  | { k: "procsub"; dir: string; src: string }; // <( cmds ) / >( cmds )

const simpleParam = (name: string, special: boolean): Param => ({
  name,
  special,
  length: false,
  indices: false,
  indirect: false,
  names: "",
  sub: "",
  op: "",
  arg: "",
  arg2: "",
});

export interface ParsedWord {
  parts: WordPart[];
  /** True if the word had any literal text or quotes — an empty expansion then
   *  still yields one (empty) field rather than zero. */
  anchored: boolean;
  /** True if any quoting/escaping occurred — such a word is not glob-expanded. */
  hasQuote: boolean;
}

const isNameStart = (c: string): boolean =>
  (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "_";
const isNameChar = (c: string): boolean => isNameStart(c) || (c >= "0" && c <= "9");

class WordParser {
  private i = 0;
  private readonly parts: WordPart[] = [];
  private lit = "";
  private anchored = false;
  private hasQuote = false;
  private readonly t: string;
  private readonly assignValue: boolean;
  /** In an assignment word, a tilde expands after `=` and each unquoted `:`. */
  private assign = false;

  constructor(text: string, assignValue = false) {
    this.t = text;
    this.assignValue = assignValue;
  }

  /** At an assignment tilde-prefix position: `~`, `~/`, or `~` before `:`/end
   *  -> $HOME (result not split). `~user` is left literal. Returns whether it
   *  consumed a tilde. */
  private tryTilde(): boolean {
    if (this.at() !== "~") return false;
    const n = this.at(1);
    if (n !== undefined && n !== "/" && n !== ":") return false;
    this.flushLit(); // emit any buffered literal (e.g. the `name=` prefix) first
    this.parts.push({ k: "param", p: simpleParam("HOME", false), quoted: true });
    this.anchored = true;
    this.i++;
    return true;
  }

  private at(k = 0): string | undefined {
    return this.t[this.i + k];
  }
  private pushLit(s: string): void {
    this.lit += s;
    this.anchored = true;
  }
  private flushLit(): void {
    if (this.lit !== "") {
      this.parts.push({ k: "lit", s: this.lit });
      this.lit = "";
    }
  }

  parse(): ParsedWord {
    // An assignment word (`name=…`, `name[k]=…`, `[k]=…`, `name+=…`) expands a
    // tilde after the `=` and after each `:`; a plain value passed with
    // assignValue is treated the same. Otherwise only a leading tilde expands.
    const am = /^(?:[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=|\[[^\]]*\]\+?=)/.exec(this.t);
    if (this.assignValue) {
      this.assign = true;
      this.tryTilde();
    } else if (am !== null) {
      this.assign = true;
      this.pushLit(am[0]);
      this.i = am[0].length;
      this.tryTilde();
    } else if (this.t[0] === "~" && (this.t.length === 1 || this.t[1] === "/")) {
      this.parts.push({ k: "param", p: simpleParam("HOME", false), quoted: true });
      this.anchored = true;
      this.i = 1;
    }

    for (;;) {
      const c = this.at();
      if (c === undefined) break;

      if (c === "\\") {
        this.hasQuote = true;
        const nc = this.at(1);
        if (nc === undefined) {
          this.pushLit("\\");
          this.i++;
        } else if (nc === "\n") {
          this.i += 2;
        } else {
          this.pushLit(nc);
          this.i += 2;
        }
        continue;
      }
      if (c === "'") {
        this.hasQuote = true;
        this.anchored = true;
        this.i++;
        for (;;) {
          const d = this.at();
          if (d === undefined) throw new Error("unterminated single quote");
          this.i++;
          if (d === "'") break;
          this.lit += d;
        }
        continue;
      }
      if (c === '"') {
        this.hasQuote = true;
        this.scanDouble();
        continue;
      }
      if (c === "$") {
        const n = this.at(1);
        if (n === "'") {
          this.hasQuote = true;
          this.ansiC(); // $'...' -> literal (C escapes decoded)
          continue;
        }
        if (n === '"') {
          this.hasQuote = true;
          this.i++; // $"..." -> treat like "..."
          continue;
        }
        this.flushLit();
        this.dollar(false);
        continue;
      }
      if (c === "`") {
        this.backtick(false);
        continue;
      }
      // Process substitution `<(cmds)` / `>(cmds)` -> a /dev-fd-like path.
      if ((c === "<" || c === ">") && this.at(1) === "(") {
        this.flushLit();
        this.i += 2; // past `<(` / `>(`
        this.parts.push({ k: "procsub", dir: c, src: this.cmdSubSrc() });
        this.anchored = true;
        continue;
      }
      // In an assignment word, a tilde right after an unquoted `:` expands.
      if (this.assign && c === ":") {
        this.pushLit(":");
        this.i++;
        this.tryTilde();
        continue;
      }
      this.pushLit(c);
      this.i++;
    }
    this.flushLit();
    return { parts: this.parts, anchored: this.anchored, hasQuote: this.hasQuote };
  }

  /** Scan the whole input as double-quote-like content (for here-doc bodies):
   *  `$`-expansions apply, `\` escapes only `$` `` ` `` `\` and newline, and
   *  everything else (including quotes) is literal. */
  parseDquoteAll(): ParsedWord {
    for (;;) {
      const c = this.at();
      if (c === undefined) break;
      if (c === "\\") {
        const nd = this.at(1);
        if (nd !== undefined && (nd === "$" || nd === "`" || nd === "\\")) {
          this.lit += nd;
          this.i += 2;
        } else if (nd === "\n") {
          this.i += 2;
        } else {
          this.lit += "\\";
          this.i++;
        }
        continue;
      }
      if (c === "$") {
        this.flushLit();
        this.dollar(true);
        continue;
      }
      this.lit += c;
      this.i++;
    }
    this.flushLit();
    return { parts: this.parts, anchored: true, hasQuote: true };
  }

  /** Decode a `$'...'` ANSI-C string into literal text. */
  private ansiC(): void {
    this.i += 2; // past $'
    let out = "";
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new Error("unterminated $'...'");
      this.i++;
      if (c === "'") break;
      if (c === "\\") {
        out += this.ansiEscape();
        continue;
      }
      out += c;
    }
    this.pushLit(out);
  }

  private ansiEscape(): string {
    const c = this.at();
    if (c === undefined) return "\\";
    this.i++;
    switch (c) {
      case "n": return "\n";
      case "t": return "\t";
      case "r": return "\r";
      case "\\": return "\\";
      case "'": return "'";
      case '"': return '"';
      case "a": return "\x07";
      case "b": return "\b";
      case "f": return "\f";
      case "v": return "\v";
      case "e": case "E": return "\x1b";
      case "x": {
        let h = "";
        while (h.length < 2 && this.at() !== undefined && /[0-9a-fA-F]/.test(this.at()!)) {
          h += this.at();
          this.i++;
        }
        return h === "" ? "x" : String.fromCharCode(parseInt(h, 16));
      }
      case "u": case "U": {
        const max = c === "u" ? 4 : 8;
        let h = "";
        while (h.length < max && this.at() !== undefined && /[0-9a-fA-F]/.test(this.at()!)) {
          h += this.at();
          this.i++;
        }
        return h === "" ? c : String.fromCodePoint(parseInt(h, 16));
      }
      case "c": {
        const n = this.at();
        if (n === undefined) return "c";
        this.i++;
        return String.fromCharCode(n.toUpperCase().charCodeAt(0) & 0x1f);
      }
      default:
        if (c >= "0" && c <= "7") {
          let o = c;
          while (o.length < 3 && this.at() !== undefined && this.at()! >= "0" && this.at()! <= "7") {
            o += this.at();
            this.i++;
          }
          return String.fromCharCode(parseInt(o, 8) & 0xff);
        }
        return "\\" + c;
    }
  }

  /** Legacy `` `cmds` `` command substitution. Inside, a backslash escapes
   *  only `` ` ``, `$` and `\`; the unescaped text is the command source. */
  private backtick(quoted: boolean): void {
    // `…` is exactly $(…): splits and globs like any command substitution, so
    // it must not anchor the word or suppress globbing.
    this.i++; // opening backtick
    let src = "";
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new Error("unterminated `");
      this.i++;
      if (c === "`") break;
      if (c === "\\") {
        const n = this.at();
        if (n === "`" || n === "$" || n === "\\") { src += n; this.i++; } else src += "\\";
        continue;
      }
      src += c;
    }
    this.flushLit();
    this.parts.push({ k: "cmdsub", src, quoted });
  }

  private scanDouble(): void {
    this.anchored = true;
    this.i++; // opening quote
    for (;;) {
      const d = this.at();
      if (d === undefined) throw new Error("unterminated double quote");
      if (d === '"') {
        this.i++;
        return;
      }
      if (d === "\\") {
        const nd = this.at(1);
        if (nd !== undefined && (nd === '"' || nd === "\\" || nd === "$" || nd === "`")) {
          this.lit += nd;
          this.i += 2;
        } else if (nd === "\n") {
          this.i += 2;
        } else {
          this.lit += "\\";
          this.i++;
        }
        continue;
      }
      if (d === "$") {
        this.flushLit();
        this.dollar(true);
        continue;
      }
      if (d === "`") {
        this.backtick(true);
        continue;
      }
      this.lit += d;
      this.i++;
    }
  }

  /** Parse a `$...` construct starting at `this.at() === "$"`. */
  private dollar(quoted: boolean): void {
    const n = this.at(1);
    if (n === undefined) {
      this.pushLit("$");
      this.i++;
      return;
    }

    if (n === "(") {
      if (this.at(2) === "(") {
        this.i += 3;
        this.parts.push({ k: "arith", expr: this.balanced(2, "(", ")"), quoted });
        return;
      }
      this.i += 2;
      this.parts.push({ k: "cmdsub", src: this.cmdSubSrc(), quoted });
      return;
    }

    if (n === "{") {
      this.i += 2;
      let inner = "";
      for (;;) {
        const d = this.at();
        if (d === undefined) throw new Error("unterminated `${ }`");
        this.i++;
        if (d === "}") break;
        inner += d;
      }
      this.parts.push({ k: "param", p: parseParam(inner), quoted });
      return;
    }

    if (n === "?" || n === "$" || n === "#" || n === "@" || n === "*" || n === "!" || n === "-" || (n >= "0" && n <= "9")) {
      this.parts.push({ k: "param", p: simpleParam(n, true), quoted });
      this.i += 2;
      return;
    }

    if (isNameStart(n)) {
      this.i++;
      let name = "";
      for (;;) {
        const d = this.at();
        if (d === undefined || !isNameChar(d)) break;
        name += d;
        this.i++;
      }
      this.parts.push({ k: "param", p: simpleParam(name, false), quoted });
      return;
    }

    this.pushLit("$");
    this.i++;
  }

  /** Copy a balanced construct's inner text; `depth` opens already consumed. */
  /** Extract a command-substitution body starting at the cursor (already past
   *  `$(` / `<(` / `>(`), advancing past the terminating `)`. Case-aware. */
  private cmdSubSrc(): string {
    const end = scanCmdSub(this.t, this.i);
    if (this.t[end] !== ")") throw new Error("unterminated `$( ... )`");
    const src = this.t.slice(this.i, end);
    this.i = end + 1;
    return src;
  }

  private balanced(depth: number, open: string, close: string): string {
    let buf = "";
    let d = depth;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new Error(`unterminated \`${open.repeat(depth)} ${close.repeat(depth)}\``);
      // Skip quotes/escapes/backticks so their open/close chars don't miscount.
      if (c === "\\") { buf += this.rawEscape(); continue; }
      if (c === "'") { buf += this.rawSingle(); continue; }
      if (c === '"') { buf += this.rawDouble(); continue; }
      if (c === "`") { buf += this.rawBacktick(); continue; }
      this.i++;
      if (c === open) {
        d++;
        buf += c;
        continue;
      }
      if (c === close) {
        d--;
        if (d >= depth) buf += c; // nested inner close
        if (d === 0) return buf;
        continue;
      }
      buf += c;
    }
  }

  /** Copy a `\`-escape verbatim (used while scanning a balanced span). */
  private rawEscape(): string {
    const n = this.at(1);
    this.i += n === undefined ? 1 : 2;
    return "\\" + (n ?? "");
  }
  /** Copy a single-quoted span `'…'` verbatim. */
  private rawSingle(): string {
    let s = "'";
    this.i++;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new Error("unterminated '");
      s += c;
      this.i++;
      if (c === "'") return s;
    }
  }
  /** Copy a backquoted span verbatim, honoring `\`` escapes. */
  private rawBacktick(): string {
    let s = "`";
    this.i++;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new Error("unterminated `");
      if (c === "\\") { s += this.rawEscape(); continue; }
      s += c;
      this.i++;
      if (c === "`") return s;
    }
  }
  /** Copy a double-quoted span `"…"` verbatim (to the next unescaped `"`),
   *  descending into backticks so a `"` inside them doesn't end the span. The
   *  lexer has already delimited the enclosing construct, so parens within the
   *  span need only be skipped, not re-balanced. */
  private rawDouble(): string {
    let s = '"';
    this.i++;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new Error('unterminated "');
      if (c === "\\") { s += this.rawEscape(); continue; }
      if (c === '"') { this.i++; return s + '"'; }
      if (c === "`") { s += this.rawBacktick(); continue; }
      s += c;
      this.i++;
    }
  }
}

const indexOfUnescaped = (s: string, ch: string): number => {
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\") {
      i++;
      continue;
    }
    if (s[i] === ch) return i;
  }
  return -1;
};

/** Parse the inside of `${ ... }` into a Param (name + optional operator). */
export function parseParam(inner: string): Param {
  if (inner === "") throw new Error("bad substitution: ${}");
  let s = inner;
  let length = false;
  let indices = false;
  let indirect = false;
  let bang = false;

  // ${#name} is length; ${#} alone is the special parameter `#`.
  if (s[0] === "#" && s.length > 1) {
    length = true;
    s = s.slice(1);
  } else if (s[0] === "!" && s.length > 1) {
    bang = true; // ${!name[@]} indices, or ${!name} indirect — decided after subscript
    s = s.slice(1);
  }

  let name = "";
  let special = false;
  let i = 0;
  const c0 = s[0]!;
  if (c0 === "@" || c0 === "*" || c0 === "#" || c0 === "?" || c0 === "$" || c0 === "-" || c0 === "!") {
    name = c0;
    special = true;
    i = 1;
  } else if (c0 >= "0" && c0 <= "9") {
    while (i < s.length && s[i]! >= "0" && s[i]! <= "9") {
      name += s[i];
      i++;
    }
    special = true;
  } else {
    while (i < s.length && isNameChar(s[i]!)) {
      name += s[i];
      i++;
    }
  }
  if (name === "") throw new Error(`bad substitution: \${${inner}}`);

  // Array subscript: ${name[sub]...}
  let sub = "";
  if (s[i] === "[") {
    i++;
    let depth = 1;
    while (i < s.length && depth > 0) {
      const c = s[i]!;
      if (c === "[") depth++;
      else if (c === "]" && --depth === 0) {
        i++;
        break;
      }
      sub += c;
      i++;
    }
  }

  let names = "";
  if (bang) {
    if (sub === "@" || sub === "*") indices = true; // ${!arr[@]}
    else if (sub === "" && (s[i] === "*" || s[i] === "@")) {
      names = s[i]!; // ${!prefix*} / ${!prefix@} — name matching
      i++;
    } else indirect = true; // ${!name}
  }

  const rest = s.slice(i);
  const p: Param = { name, special, length, indices, indirect, names, sub, op: "", arg: "", arg2: "" };
  // ${#x}, ${!arr[@]}, ${!prefix*} take no operator; ${!ref OP} does (the
  // operator applies to the variable the ref names).
  if (length || indices || names !== "") {
    if (rest !== "") throw new Error(`bad substitution: \${${inner}}`);
    return p;
  }
  if (rest === "") return p;

  const a = rest[0]!;
  if (a === "@") {
    // ${parameter@operator} transform: Q E P A K a k L U u (single letter).
    p.op = "@" + (rest[1] ?? "");
    return p;
  }
  if (a === ":") {
    const b = rest[1];
    if (b === "-" || b === "=" || b === "+" || b === "?") {
      p.op = ":" + b;
      p.arg = rest.slice(2);
      return p;
    }
    p.op = ":"; // substring ${name:offset[:length]}
    const spec = rest.slice(1);
    const ci = spec.indexOf(":");
    if (ci >= 0) {
      p.arg = spec.slice(0, ci);
      p.arg2 = spec.slice(ci + 1);
    } else {
      p.arg = spec;
    }
    return p;
  }
  if (a === "-" || a === "=" || a === "+" || a === "?") {
    p.op = a;
    p.arg = rest.slice(1);
    return p;
  }
  if (a === "#") {
    p.op = rest[1] === "#" ? "##" : "#";
    p.arg = rest.slice(p.op.length);
    return p;
  }
  if (a === "%") {
    p.op = rest[1] === "%" ? "%%" : "%";
    p.arg = rest.slice(p.op.length);
    return p;
  }
  if (a === "^" || a === ",") {
    // ${v^}/${v^^} uppercase, ${v,}/${v,,} lowercase (optional match pattern).
    p.op = rest[1] === a ? a + a : a;
    p.arg = rest.slice(p.op.length);
    return p;
  }
  if (a === "/") {
    let body = rest.slice(1);
    p.op = "/";
    if (body[0] === "/") { p.op = "//"; body = body.slice(1); }
    else if (body[0] === "#") { p.op = "/#"; body = body.slice(1); }
    else if (body[0] === "%") { p.op = "/%"; body = body.slice(1); }
    const si = indexOfUnescaped(body, "/");
    if (si >= 0) {
      p.arg = body.slice(0, si);
      p.arg2 = body.slice(si + 1);
    } else {
      p.arg = body;
    }
    return p;
  }
  throw new Error(`bad substitution: \${${inner}}`);
}

export const parseWord = (text: string, assignValue = false): ParsedWord =>
  new WordParser(text, assignValue).parse();

/** Parse a here-document body: `$`-expanded (unquoted delimiter) or literal. */
export const parseHeredoc = (text: string, expand: boolean): ParsedWord =>
  expand
    ? new WordParser(text).parseDquoteAll()
    : { parts: text === "" ? [] : [{ k: "lit", s: text }], anchored: true, hasQuote: true };
