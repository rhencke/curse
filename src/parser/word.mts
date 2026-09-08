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

export type WordPart =
  | { k: "lit"; s: string } // literal text (quote-removed); never splits
  | { k: "var"; name: string; quoted: boolean } // $name / ${name}
  | { k: "special"; name: string; quoted: boolean } // $? $$ $# $@ $* $0..$9
  | { k: "arith"; expr: string; quoted: boolean } // $(( expr ))
  | { k: "cmdsub"; src: string; quoted: boolean }; // $( cmds )

export interface ParsedWord {
  parts: WordPart[];
  /** True if the word had any literal text or quotes — an empty expansion then
   *  still yields one (empty) field rather than zero. */
  anchored: boolean;
}

const isNameStart = (c: string): boolean =>
  (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "_";
const isNameChar = (c: string): boolean => isNameStart(c) || (c >= "0" && c <= "9");

class WordParser {
  private i = 0;
  private readonly parts: WordPart[] = [];
  private lit = "";
  private anchored = false;
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
    for (;;) {
      const c = this.at();
      if (c === undefined) break;

      if (c === "\\") {
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
        this.scanDouble();
        continue;
      }
      if (c === "$") {
        this.flushLit();
        this.dollar(false);
        continue;
      }
      this.pushLit(c);
      this.i++;
    }
    this.flushLit();
    return { parts: this.parts, anchored: this.anchored };
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
      let name = "";
      for (;;) {
        const d = this.at();
        if (d === undefined) throw new Error("unterminated `${ }`");
        this.i++;
        if (d === "}") break;
        name += d;
      }
      this.emitParam(name, quoted);
      return;
    }

    if (n === "?" || n === "$" || n === "#" || n === "@" || n === "*" || (n >= "0" && n <= "9")) {
      this.parts.push({ k: "special", name: n, quoted });
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
      this.parts.push({ k: "var", name, quoted });
      return;
    }

    this.pushLit("$");
    this.i++;
  }

  private emitParam(name: string, quoted: boolean): void {
    if (name === "") throw new Error("bad substitution: ${}");
    if (
      name.length === 1 &&
      (name === "?" || name === "$" || name === "#" || name === "@" || name === "*" ||
        (name >= "0" && name <= "9"))
    ) {
      this.parts.push({ k: "special", name, quoted });
      return;
    }
    for (const ch of name) {
      if (!isNameChar(ch)) throw new Error(`\${${name}}: operator not implemented yet`);
    }
    this.parts.push({ k: "var", name, quoted });
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

export const parseWord = (text: string): ParsedWord => new WordParser(text).parse();
