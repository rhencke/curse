/* Parser for the inside of `[[ ... ]]` — bash's conditional expression, which
 * `parse.y` handles with a recursive-descent parser slipped into the grammar
 * (GPLv3+; see NOTICE.md). Word splitting and globbing are off here; `==`,
 * `=~`, `<`, `>`, `&&`, `||`, `!`, `( )` are operators. The raw inner text was
 * captured by the lexer; here we tokenize and parse it. */

import type { CondExpr, Word } from "../ast/nodes.mts";
import { makeWord } from "../ast/nodes.mts";

export class CondError extends Error {}

type Tok = { t: "word"; v: string } | { t: "op"; v: string } | { t: "eof" };

const isBlank = (c: string): boolean => c === " " || c === "\t" || c === "\n";
const BREAK = new Set([" ", "\t", "\n", "(", ")", "<", ">", "&", "|"]);

const UNARY = new Set([
  "-z", "-n", "-e", "-f", "-d", "-s", "-r", "-w", "-x", "-h", "-L", "-v", "-o",
  "-b", "-c", "-p", "-S", "-k", "-g", "-u", "-G", "-O", "-N", "-t", "-a",
]);
const BINARY = new Set([
  "==", "=", "!=", "=~", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge",
  "-nt", "-ot", "-ef",
]);

const tokenize = (s: string): Tok[] => {
  const toks: Tok[] = [];
  let i = 0;
  const readWord = (): string => {
    let w = "";
    while (i < s.length) {
      const d = s[i]!;
      // extglob group `X(...)` stays part of the word (balanced parens).
      if ((d === "?" || d === "*" || d === "+" || d === "@" || d === "!") && s[i + 1] === "(") {
        let depth = 0;
        w += s[i++]; // operator
        do {
          const ch = s[i]!;
          if (ch === "(") depth++;
          else if (ch === ")") depth--;
          w += ch;
          i++;
        } while (i < s.length && depth > 0);
        continue;
      }
      if (BREAK.has(d)) break;
      if (d === "'") {
        w += d;
        i++;
        while (i < s.length && s[i] !== "'") w += s[i++];
        if (i < s.length) w += s[i++];
        continue;
      }
      if (d === '"') {
        w += d;
        i++;
        while (i < s.length && s[i] !== '"') {
          if (s[i] === "\\") {
            w += s[i++];
            if (i < s.length) w += s[i++];
            continue;
          }
          w += s[i++];
        }
        if (i < s.length) w += s[i++];
        continue;
      }
      if (d === "\\") {
        w += d;
        i++;
        if (i < s.length) w += s[i++];
        continue;
      }
      if (d === "$" && (s[i + 1] === "(" || s[i + 1] === "{")) {
        const open = s[i + 1]!;
        const close = open === "(" ? ")" : "}";
        w += s[i++]; // $
        let depth = 0;
        do {
          const ch = s[i]!;
          if (ch === open) depth++;
          else if (ch === close) depth--;
          w += ch;
          i++;
        } while (i < s.length && depth > 0);
        continue;
      }
      w += d;
      i++;
    }
    return w;
  };

  // After `=~`, bash reads the RHS as one regex operand: unquoted `( )` and
  // `[ ]` group (whitespace inside them is kept), and top-level whitespace or
  // `&& || )` ends it. Metacharacters are not cond operators here.
  const readRegex = (): string => {
    let w = "";
    let paren = 0;
    let bracket = 0;
    while (i < s.length) {
      const d = s[i]!;
      if (d === "'" || d === '"') {
        w += d;
        i++;
        while (i < s.length && s[i] !== d) {
          if (d === '"' && s[i] === "\\") { w += s[i++]; if (i < s.length) w += s[i++]; continue; }
          w += s[i++];
        }
        if (i < s.length) w += s[i++];
        continue;
      }
      if (d === "\\") { w += s[i++]; if (i < s.length) w += s[i++]; continue; }
      if (paren === 0 && bracket === 0) {
        if (isBlank(d)) break;
        if (d === ")") break;
        if (d === "&" && s[i + 1] === "&") break;
        if (d === "|" && s[i + 1] === "|") break;
      }
      if (d === "(") paren++;
      else if (d === ")" && paren > 0) paren--;
      else if (d === "[") bracket++;
      else if (d === "]" && bracket > 0) bracket--;
      w += d;
      i++;
    }
    return w;
  };

  while (i < s.length) {
    const c = s[i]!;
    if (isBlank(c)) {
      i++;
      continue;
    }
    // extglob operand `X(...)` — read as a word (so `!(…)` isn't the `!` op).
    if ((c === "?" || c === "*" || c === "+" || c === "@" || c === "!") && s[i + 1] === "(") {
      toks.push({ t: "word", v: readWord() });
      continue;
    }
    if (c === "&" && s[i + 1] === "&") { toks.push({ t: "op", v: "&&" }); i += 2; continue; }
    if (c === "|" && s[i + 1] === "|") { toks.push({ t: "op", v: "||" }); i += 2; continue; }
    if (c === "=" && s[i + 1] === "=") { toks.push({ t: "op", v: "==" }); i += 2; continue; }
    if (c === "=" && s[i + 1] === "~") {
      toks.push({ t: "op", v: "=~" });
      i += 2;
      while (i < s.length && isBlank(s[i]!)) i++;
      const rx = readRegex();
      if (rx !== "") toks.push({ t: "word", v: rx });
      continue;
    }
    if (c === "=") { toks.push({ t: "op", v: "=" }); i++; continue; }
    if (c === "!" && s[i + 1] === "=") { toks.push({ t: "op", v: "!=" }); i += 2; continue; }
    if (c === "!") { toks.push({ t: "op", v: "!" }); i++; continue; }
    if (c === "<") { toks.push({ t: "op", v: "<" }); i++; continue; }
    if (c === ">") { toks.push({ t: "op", v: ">" }); i++; continue; }
    if (c === "(") { toks.push({ t: "op", v: "(" }); i++; continue; }
    if (c === ")") { toks.push({ t: "op", v: ")" }); i++; continue; }
    toks.push({ t: "word", v: readWord() });
  }
  toks.push({ t: "eof" });
  return toks;
};

class CondParser {
  private p = 0;
  private readonly toks: Tok[];
  constructor(toks: Tok[]) {
    this.toks = toks;
  }
  private peek(): Tok {
    return this.toks[this.p] ?? { t: "eof" };
  }
  private next(): Tok {
    const t = this.peek();
    if (t.t !== "eof") this.p++;
    return t;
  }
  private isOp(v: string): boolean {
    const t = this.peek();
    return t.t === "op" && t.v === v;
  }
  private expectWord(): Word {
    const t = this.next();
    if (t.t !== "word") throw new CondError("conditional: expected an operand");
    return makeWord(t.v);
  }

  parse(): CondExpr {
    const e = this.parseOr();
    if (this.peek().t !== "eof") throw new CondError("conditional: syntax error");
    return e;
  }

  private parseOr(): CondExpr {
    let l = this.parseAnd();
    while (this.isOp("||")) {
      this.next();
      l = { k: "or", l, r: this.parseAnd() };
    }
    return l;
  }
  private parseAnd(): CondExpr {
    let l = this.parseTerm();
    while (this.isOp("&&")) {
      this.next();
      l = { k: "and", l, r: this.parseTerm() };
    }
    return l;
  }
  private parseTerm(): CondExpr {
    if (this.isOp("!")) {
      this.next();
      return { k: "not", e: this.parseTerm() };
    }
    if (this.isOp("(")) {
      this.next();
      const e = this.parseOr();
      if (!this.isOp(")")) throw new CondError("conditional: expected `)`");
      this.next();
      return e;
    }
    const t = this.peek();
    if (t.t === "word" && UNARY.has(t.v)) {
      const nxt = this.toks[this.p + 1];
      if (nxt && nxt.t === "word") {
        this.next();
        return { k: "unary", op: t.v, arg: this.expectWord() };
      }
    }
    const left = this.expectWord();
    // Binary operators may be op tokens (== != = =~ < >) or word tokens (-eq …).
    const op = this.peek();
    const opv = op.t === "op" || op.t === "word" ? op.v : "";
    if (BINARY.has(opv)) {
      this.next();
      return { k: "binary", op: opv, l: left, r: this.expectWord() };
    }
    return { k: "word", w: left };
  }
}

export const parseCond = (inner: string): CondExpr =>
  new CondParser(tokenize(inner)).parse();
