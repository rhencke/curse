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
  | { k: "cmdsub"; src: string; quoted: boolean }; // $( cmds )

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

  constructor(text: string) {
    this.t = text;
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
    // Leading unquoted tilde: `~` or `~/...` -> $HOME (result is not split).
    if (this.t[0] === "~" && (this.t.length === 1 || this.t[1] === "/")) {
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
      this.parts.push({ k: "cmdsub", src: this.balanced(1, "(", ")"), quoted });
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

    if (n === "?" || n === "$" || n === "#" || n === "@" || n === "*" || n === "!" || (n >= "0" && n <= "9")) {
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
  private balanced(depth: number, open: string, close: string): string {
    let buf = "";
    let d = depth;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new Error(`unterminated \`${open.repeat(depth)} ${close.repeat(depth)}\``);
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
function parseParam(inner: string): Param {
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
  if (c0 === "@" || c0 === "*" || c0 === "#" || c0 === "?" || c0 === "$") {
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
  if (length || indices || indirect || names !== "") {
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

export const parseWord = (text: string): ParsedWord => new WordParser(text).parse();

/** Parse a here-document body: `$`-expanded (unquoted delimiter) or literal. */
export const parseHeredoc = (text: string, expand: boolean): ParsedWord =>
  expand
    ? new WordParser(text).parseDquoteAll()
    : { parts: text === "" ? [] : [{ k: "lit", s: text }], anchored: true, hasQuote: true };
