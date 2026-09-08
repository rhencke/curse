/* Recursive-descent parser, following the grammar in bash's `parse.y` (GPLv3+;
 * see NOTICE.md). M1 subset:
 *
 *   list        := and_or ( (';' | NEWLINE)+ and_or )* separator?
 *   and_or      := command ( ('&&' | '||') linebreak command )*
 *   command     := '!'? ( compound | simple )
 *   compound    := subshell | group | if | while | until | for | arith
 *   simple      := WORD+
 *
 * Reserved words (if/then/…/{/}) are recognized in command position, as bash
 * does; used elsewhere they are ordinary words. Pipelines, redirections, `&`,
 * and `case` arrive in later milestones. */

import type { Command, Word } from "../ast/nodes.mts";
import { CMD_INVERT_RETURN, connection, makeWord, simple } from "../ast/nodes.mts";
import { tokenize } from "./lexer.mts";
import type { Token } from "./lexer.mts";

export class ParseError extends Error {}

interface TermSet {
  words?: Set<string>;
  ops?: Set<string>;
}

const THEN: TermSet = { words: new Set(["then"]) };
const DO: TermSet = { words: new Set(["do"]) };
const DONE: TermSet = { words: new Set(["done"]) };
const FI: TermSet = { words: new Set(["fi"]) };
const ELIF_ELSE_FI: TermSet = { words: new Set(["elif", "else", "fi"]) };
const CLOSE_BRACE: TermSet = { words: new Set(["}"]) };
const CLOSE_PAREN: TermSet = { ops: new Set([")"]) };
const TOP: TermSet = {};

const RESERVED_MISPLACED = new Set([
  "then", "else", "elif", "fi", "do", "done", "esac", "}",
]);

const isName = (s: string): boolean => /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);

class Parser {
  private p = 0;
  private readonly toks: Token[];
  constructor(toks: Token[]) {
    this.toks = toks;
  }

  private peek(): Token {
    return this.toks[this.p] ?? { type: "EOF", value: "", pos: -1, line: -1 };
  }
  private advance(): Token {
    const t = this.peek();
    if (t.type !== "EOF") this.p++;
    return t;
  }
  private wordIs(v: string): boolean {
    const t = this.peek();
    return t.type === "WORD" && t.value === v;
  }
  private isSeparator(): boolean {
    const t = this.peek();
    return t.type === "NEWLINE" || (t.type === "OP" && t.value === ";");
  }
  private skipSeparators(): void {
    while (this.isSeparator()) this.advance();
  }
  private skipLinebreak(): void {
    while (this.peek().type === "NEWLINE") this.advance();
  }
  private atTerminator(term: TermSet): boolean {
    const t = this.peek();
    if (t.type === "EOF") return true;
    if (t.type === "WORD" && term.words?.has(t.value)) return true;
    if (t.type === "OP" && term.ops?.has(t.value)) return true;
    return false;
  }
  private eatWord(v: string): void {
    const t = this.peek();
    if (t.type === "WORD" && t.value === v) {
      this.advance();
      return;
    }
    throw new ParseError(`expected \`${v}\` but found \`${t.value || "<eof>"}\` (line ${t.line})`);
  }

  parseProgram(): Command | null {
    this.skipLinebreak();
    if (this.peek().type === "EOF") return null;
    const cmd = this.parseCompoundList(TOP);
    this.skipLinebreak();
    const t = this.peek();
    if (t.type !== "EOF") {
      throw new ParseError(`syntax error near \`${t.value}\` (line ${t.line})`);
    }
    return cmd;
  }

  /** A list of and_or commands, ended by EOF or one of `term`'s tokens. */
  private parseCompoundList(term: TermSet): Command {
    this.skipSeparators();
    if (this.atTerminator(term)) {
      const t = this.peek();
      throw new ParseError(`syntax error near \`${t.value || "<eof>"}\` (line ${t.line})`);
    }
    let cmd = this.parseAndOr();
    for (;;) {
      if (!this.isSeparator()) break;
      this.skipSeparators();
      if (this.atTerminator(term)) break;
      cmd = connection(";", cmd, this.parseAndOr());
    }
    return cmd;
  }

  private parseAndOr(): Command {
    let left = this.parseCommand();
    for (;;) {
      const t = this.peek();
      if (t.type === "OP" && (t.value === "&&" || t.value === "||")) {
        this.advance();
        this.skipLinebreak();
        left = connection(t.value, left, this.parseCommand());
      } else {
        break;
      }
    }
    return left;
  }

  private parseCommand(): Command {
    if (this.wordIs("!")) {
      this.advance();
      const inner = this.parseCommand();
      inner.flags = (inner.flags ?? 0) ^ CMD_INVERT_RETURN;
      return inner;
    }

    const t = this.peek();

    if (t.type === "ARITH") {
      this.advance();
      return { type: "arith", expression: t.value };
    }
    if (t.type === "OP" && t.value === "(") return this.parseSubshell();

    if (t.type === "WORD") {
      switch (t.value) {
        case "{": return this.parseGroup();
        case "if": return this.parseIf();
        case "while": return this.parseWhile(false);
        case "until": return this.parseWhile(true);
        case "for": return this.parseFor();
        case "case":
          throw new ParseError("`case` not supported yet (planned for M1.5)");
      }
      if (RESERVED_MISPLACED.has(t.value)) {
        throw new ParseError(`syntax error near \`${t.value}\` (line ${t.line})`);
      }
      return this.parseSimple();
    }

    throw new ParseError(`syntax error near \`${t.value || "<eof>"}\` (line ${t.line})`);
  }

  private parseSubshell(): Command {
    this.advance(); // "("
    const body = this.parseCompoundList(CLOSE_PAREN);
    const t = this.peek();
    if (!(t.type === "OP" && t.value === ")")) {
      throw new ParseError(`expected \`)\` but found \`${t.value || "<eof>"}\` (line ${t.line})`);
    }
    this.advance();
    return { type: "subshell", body };
  }

  private parseGroup(): Command {
    this.eatWord("{");
    const body = this.parseCompoundList(CLOSE_BRACE);
    this.eatWord("}");
    return { type: "group", body };
  }

  private parseIf(): Command {
    this.eatWord("if");
    const test = this.parseCompoundList(THEN);
    this.eatWord("then");
    const consequent = this.parseCompoundList(ELIF_ELSE_FI);
    const alternate = this.parseIfTail();
    return { type: "if", test, consequent, alternate };
  }

  private parseIfTail(): Command | null {
    if (this.wordIs("elif")) {
      this.advance();
      const test = this.parseCompoundList(THEN);
      this.eatWord("then");
      const consequent = this.parseCompoundList(ELIF_ELSE_FI);
      const alternate = this.parseIfTail();
      return { type: "if", test, consequent, alternate };
    }
    if (this.wordIs("else")) {
      this.advance();
      const body = this.parseCompoundList(FI);
      this.eatWord("fi");
      return body;
    }
    this.eatWord("fi");
    return null;
  }

  private parseWhile(until: boolean): Command {
    this.advance(); // while | until
    const test = this.parseCompoundList(DO);
    this.eatWord("do");
    const body = this.parseCompoundList(DONE);
    this.eatWord("done");
    return { type: "while", until, test, body };
  }

  private parseFor(): Command {
    this.eatWord("for");

    if (this.peek().type === "ARITH") {
      const inner = this.advance().value;
      const parts = inner.split(";");
      const init = (parts[0] ?? "").trim();
      const test = (parts[1] ?? "").trim();
      const step = (parts.slice(2).join(";") ?? "").trim();
      this.skipSeparators();
      this.eatWord("do");
      const body = this.parseCompoundList(DONE);
      this.eatWord("done");
      return { type: "arith_for", init, test, step, body };
    }

    const nameTok = this.peek();
    if (nameTok.type !== "WORD" || !isName(nameTok.value)) {
      throw new ParseError(`for: \`${nameTok.value || "<eof>"}\`: not a valid identifier (line ${nameTok.line})`);
    }
    this.advance();
    const name = nameTok.value;

    let words: Word[] = [];
    if (this.wordIs("in")) {
      this.advance();
      while (this.peek().type === "WORD" && this.peek().value !== "do") {
        words.push(makeWord(this.advance().value));
      }
    }
    // (a bare `for x` iterates over "$@" — no positional params in M1, so [])

    this.skipSeparators();
    this.eatWord("do");
    const body = this.parseCompoundList(DONE);
    this.eatWord("done");
    return { type: "for", name, words, body };
  }

  private parseSimple(): Command {
    const words: Word[] = [];
    while (this.peek().type === "WORD") {
      words.push(makeWord(this.advance().value));
    }
    if (words.length === 0) {
      const t = this.peek();
      throw new ParseError(`syntax error near \`${t.value || "<eof>"}\` (line ${t.line})`);
    }
    return simple(words);
  }
}

export const parse = (src: string): Command | null =>
  new Parser(tokenize(src)).parseProgram();
