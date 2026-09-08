/* Arithmetic evaluation — bash's `expr.c` semantics (GPLv3+; see NOTICE.md).
 *
 * Integers are 64-bit signed with two's-complement wraparound (like bash's
 * intmax_t), so we evaluate in BigInt and wrap after each operation. Bare
 * names are variable references, resolved recursively (`x=y; y=5` → x is 5).
 *
 * The input text has already had `$`-expansions applied by the caller, so here
 * we only see literals, names, and operators. */

import type { Shell } from "./shell.mts";

export class ArithError extends Error {}

const MASK = (1n << 64n) - 1n;
const SIGN = 1n << 63n;
const wrap = (x: bigint): bigint => {
  const m = x & MASK;
  return m >= SIGN ? m - (1n << 64n) : m;
};

/* ---------- tokenizer ---------- */

type Tok =
  | { k: "num"; v: bigint }
  | { k: "name"; v: string }
  | { k: "op"; v: string }
  | { k: "eof" };

const OPS = [
  "<<=", ">>=", "**", "<<", ">>", "&&", "||", "==", "!=", "<=", ">=",
  "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=",
  "+", "-", "*", "/", "%", "<", ">", "&", "|", "^", "~", "!", "?", ":",
  "(", ")", ",", "=",
];

const isDigit = (c: string): boolean => c >= "0" && c <= "9";
const isNameStart = (c: string): boolean =>
  (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "_";
const isNameChar = (c: string): boolean => isNameStart(c) || isDigit(c);

const digitVal = (c: string): number => {
  if (c >= "0" && c <= "9") return c.charCodeAt(0) - 48;
  if (c >= "a" && c <= "z") return c.charCodeAt(0) - 97 + 10;
  if (c >= "A" && c <= "Z") return c.charCodeAt(0) - 65 + 10;
  return 99;
};

const parseNumber = (tok: string): bigint => {
  const hash = tok.indexOf("#");
  if (hash > 0) {
    const base = Number(tok.slice(0, hash));
    if (!Number.isInteger(base) || base < 2 || base > 64) {
      throw new ArithError(`${tok}: invalid arithmetic base`);
    }
    let v = 0n;
    for (const c of tok.slice(hash + 1)) {
      const d = digitVal(c);
      if (d >= base) throw new ArithError(`${tok}: value too great for base`);
      v = v * BigInt(base) + BigInt(d);
    }
    return v;
  }
  if (/^0[xX][0-9a-fA-F]+$/.test(tok)) return BigInt(tok);
  if (/^0[0-7]+$/.test(tok)) return BigInt(parseInt(tok, 8));
  if (/^[0-9]+$/.test(tok)) return BigInt(tok);
  throw new ArithError(`${tok}: invalid arithmetic constant`);
};

const tokenizeArith = (s: string): Tok[] => {
  const out: Tok[] = [];
  let i = 0;
  while (i < s.length) {
    const c = s[i]!;
    if (c === " " || c === "\t" || c === "\n") {
      i++;
      continue;
    }
    if (isDigit(c)) {
      let j = i;
      while (j < s.length && /[0-9a-zA-Z_@#]/.test(s[j]!)) j++;
      out.push({ k: "num", v: parseNumber(s.slice(i, j)) });
      i = j;
      continue;
    }
    if (isNameStart(c)) {
      let j = i;
      while (j < s.length && isNameChar(s[j]!)) j++;
      out.push({ k: "name", v: s.slice(i, j) });
      i = j;
      continue;
    }
    const op = OPS.find((o) => s.startsWith(o, i));
    if (op === undefined) throw new ArithError(`unexpected character \`${c}\``);
    out.push({ k: "op", v: op });
    i += op.length;
  }
  out.push({ k: "eof" });
  return out;
};

/* ---------- AST ---------- */

type Node =
  | { t: "num"; v: bigint }
  | { t: "var"; name: string }
  | { t: "unary"; op: string; e: Node }
  | { t: "incr"; op: string; name: string; post: boolean }
  | { t: "bin"; op: string; l: Node; r: Node }
  | { t: "logic"; op: string; l: Node; r: Node }
  | { t: "assign"; op: string; name: string; e: Node }
  | { t: "ternary"; c: Node; a: Node; b: Node }
  | { t: "comma"; l: Node; r: Node };

const ASSIGN_OPS = new Set([
  "=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "^=", "|=",
]);

class AParser {
  private p = 0;
  private readonly toks: Tok[];
  constructor(toks: Tok[]) {
    this.toks = toks;
  }

  private peek(): Tok {
    return this.toks[this.p] ?? { k: "eof" };
  }
  private next(): Tok {
    const t = this.peek();
    if (t.k !== "eof") this.p++;
    return t;
  }
  private isOp(v: string): boolean {
    const t = this.peek();
    return t.k === "op" && t.v === v;
  }

  parseTop(): Node {
    if (this.peek().k === "eof") return { t: "num", v: 0n };
    const e = this.parseComma();
    if (this.peek().k !== "eof") throw new ArithError("syntax error in expression");
    return e;
  }

  private parseComma(): Node {
    let l = this.parseAssign();
    while (this.isOp(",")) {
      this.next();
      l = { t: "comma", l, r: this.parseAssign() };
    }
    return l;
  }

  private parseAssign(): Node {
    const t = this.peek();
    const nxt = this.toks[this.p + 1];
    if (t.k === "name" && nxt && nxt.k === "op" && ASSIGN_OPS.has(nxt.v)) {
      this.next();
      const op = (this.next() as { v: string }).v;
      return { t: "assign", op, name: t.v, e: this.parseAssign() };
    }
    return this.parseTernary();
  }

  private parseTernary(): Node {
    const c = this.parseBinary(0);
    if (this.isOp("?")) {
      this.next();
      const a = this.parseAssign();
      if (!this.isOp(":")) throw new ArithError("expected `:` in conditional");
      this.next();
      const b = this.parseTernary();
      return { t: "ternary", c, a, b };
    }
    return c;
  }

  // Precedence climbing for binary/logical operators.
  private static readonly LEVELS: string[][] = [
    ["||"],
    ["&&"],
    ["|"],
    ["^"],
    ["&"],
    ["==", "!="],
    ["<", "<=", ">", ">="],
    ["<<", ">>"],
    ["+", "-"],
    ["*", "/", "%"],
  ];

  private parseBinary(level: number): Node {
    if (level >= AParser.LEVELS.length) return this.parseExp();
    let l = this.parseBinary(level + 1);
    const ops = AParser.LEVELS[level]!;
    for (;;) {
      const t = this.peek();
      if (t.k === "op" && ops.includes(t.v)) {
        this.next();
        const r = this.parseBinary(level + 1);
        l = t.v === "&&" || t.v === "||"
          ? { t: "logic", op: t.v, l, r }
          : { t: "bin", op: t.v, l, r };
      } else {
        return l;
      }
    }
  }

  private parseExp(): Node {
    const l = this.parseUnary();
    if (this.isOp("**")) {
      this.next();
      return { t: "bin", op: "**", l, r: this.parseExp() };
    }
    return l;
  }

  private parseUnary(): Node {
    const t = this.peek();
    if (t.k === "op" && (t.v === "+" || t.v === "-" || t.v === "!" || t.v === "~")) {
      this.next();
      return { t: "unary", op: t.v, e: this.parseUnary() };
    }
    if (t.k === "op" && (t.v === "++" || t.v === "--")) {
      this.next();
      const name = this.next();
      if (name.k !== "name") throw new ArithError("expected variable after `" + t.v + "`");
      return { t: "incr", op: t.v, name: name.v, post: false };
    }
    return this.parsePostfix();
  }

  private parsePostfix(): Node {
    const e = this.parsePrimary();
    const t = this.peek();
    if (e.t === "var" && t.k === "op" && (t.v === "++" || t.v === "--")) {
      this.next();
      return { t: "incr", op: t.v, name: e.name, post: true };
    }
    return e;
  }

  private parsePrimary(): Node {
    const t = this.next();
    if (t.k === "op" && t.v === "(") {
      const e = this.parseComma();
      if (!this.isOp(")")) throw new ArithError("expected `)`");
      this.next();
      return e;
    }
    if (t.k === "num") return { t: "num", v: t.v };
    if (t.k === "name") return { t: "var", name: t.v };
    throw new ArithError("syntax error in expression");
  }
}

/* ---------- evaluation ---------- */

const readVar = (shell: Shell, name: string, depth: number): bigint => {
  const raw = shell.getVar(name);
  if (raw === undefined || raw.trim() === "") return 0n;
  return evalArith(shell, raw, depth + 1);
};

const evalNode = (shell: Shell, n: Node, depth: number): bigint => {
  switch (n.t) {
    case "num":
      return n.v;
    case "var":
      return readVar(shell, n.name, depth);
    case "unary": {
      const e = evalNode(shell, n.e, depth);
      switch (n.op) {
        case "+": return e;
        case "-": return wrap(-e);
        case "!": return e === 0n ? 1n : 0n;
        default: return wrap(~e); // "~"
      }
    }
    case "incr": {
      const cur = readVar(shell, n.name, depth);
      const nv = wrap(n.op === "++" ? cur + 1n : cur - 1n);
      shell.setVar(n.name, nv.toString());
      return n.post ? cur : nv;
    }
    case "logic": {
      const l = evalNode(shell, n.l, depth);
      if (n.op === "&&") return l === 0n ? 0n : (evalNode(shell, n.r, depth) !== 0n ? 1n : 0n);
      return l !== 0n ? 1n : (evalNode(shell, n.r, depth) !== 0n ? 1n : 0n);
    }
    case "ternary":
      return evalNode(shell, n.c, depth) !== 0n
        ? evalNode(shell, n.a, depth)
        : evalNode(shell, n.b, depth);
    case "comma":
      evalNode(shell, n.l, depth);
      return evalNode(shell, n.r, depth);
    case "assign": {
      const cur = n.op === "=" ? 0n : readVar(shell, n.name, depth);
      const r = evalNode(shell, n.e, depth);
      const nv = wrap(n.op === "=" ? r : applyBin(n.op.slice(0, -1), cur, r));
      shell.setVar(n.name, nv.toString());
      return nv;
    }
    case "bin":
      return applyBin(n.op, evalNode(shell, n.l, depth), evalNode(shell, n.r, depth));
  }
};

const applyBin = (op: string, l: bigint, r: bigint): bigint => {
  switch (op) {
    case "+": return wrap(l + r);
    case "-": return wrap(l - r);
    case "*": return wrap(l * r);
    case "/": if (r === 0n) throw new ArithError("division by 0"); return wrap(l / r);
    case "%": if (r === 0n) throw new ArithError("division by 0"); return wrap(l % r);
    case "**": if (r < 0n) throw new ArithError("exponent less than 0"); return wrap(l ** r);
    case "<<": return wrap(l << r);
    case ">>": return wrap(l >> r);
    case "&": return wrap(l & r);
    case "^": return wrap(l ^ r);
    case "|": return wrap(l | r);
    case "<": return l < r ? 1n : 0n;
    case "<=": return l <= r ? 1n : 0n;
    case ">": return l > r ? 1n : 0n;
    case ">=": return l >= r ? 1n : 0n;
    case "==": return l === r ? 1n : 0n;
    case "!=": return l !== r ? 1n : 0n;
    default: throw new ArithError(`unknown operator \`${op}\``);
  }
};

export const evalArith = (shell: Shell, text: string, depth = 0): bigint => {
  if (depth > 64) throw new ArithError("expression recursion level exceeded (max: 64)");
  const ast = new AParser(tokenizeArith(text)).parseTop();
  return evalNode(shell, ast, depth);
};
