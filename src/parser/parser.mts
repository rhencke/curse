/* Recursive-descent parser for the M0 subset, following the grammar in bash's
 * `parse.y` (GPLv3+; see NOTICE.md):
 *
 *   program := linebreak (list)?
 *   list    := and_or ( (';' | NEWLINE)+ and_or )* separator?
 *   and_or  := simple ( ('&&' | '||') linebreak simple )*
 *   simple  := WORD+
 *
 * Pipelines, redirections, compound commands, and `&` arrive in later
 * milestones; the grammar hooks are left where they belong.
 */

import type { Command, Connector } from "../ast/nodes.mts";
import { connection, makeWord, simple } from "../ast/nodes.mts";
import { tokenize } from "./lexer.mts";
import type { Token } from "./lexer.mts";

export class ParseError extends Error {}

class Parser {
  private readonly toks: Token[];
  private p = 0;

  constructor(toks: Token[]) {
    this.toks = toks;
  }

  private peek(): Token {
    // The token stream always ends with EOF, so index is in range.
    return this.toks[this.p] ?? { type: "EOF", value: "", pos: -1, line: -1 };
  }

  private advance(): Token {
    const t = this.peek();
    if (t.type !== "EOF") this.p++;
    return t;
  }

  private isSeparator(): boolean {
    const t = this.peek();
    return t.type === "NEWLINE" || (t.type === "OP" && t.value === ";");
  }

  private skipLinebreak(): void {
    while (this.peek().type === "NEWLINE") this.advance();
  }

  parseProgram(): Command | null {
    this.skipLinebreak();
    if (this.peek().type === "EOF") return null;
    const cmd = this.parseList();
    this.skipLinebreak();
    const t = this.peek();
    if (t.type !== "EOF") {
      throw new ParseError(`syntax error near \`${t.value}\` (line ${t.line})`);
    }
    return cmd;
  }

  private parseList(): Command {
    let left = this.parseAndOr();
    for (;;) {
      if (!this.isSeparator()) break;
      while (this.isSeparator()) this.advance();
      const t = this.peek();
      if (t.type === "EOF") break; // trailing separator
      const right = this.parseAndOr();
      left = connection(";", left, right);
    }
    return left;
  }

  private parseAndOr(): Command {
    let left = this.parseSimple();
    for (;;) {
      const t = this.peek();
      if (t.type === "OP" && (t.value === "&&" || t.value === "||")) {
        this.advance();
        this.skipLinebreak();
        const right = this.parseSimple();
        left = connection(t.value as Connector, left, right);
      } else {
        break;
      }
    }
    return left;
  }

  private parseSimple(): Command {
    const words = [];
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
