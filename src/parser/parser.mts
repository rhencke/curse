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

import type { CasePattern, Command, Redirect, Word } from "../ast/nodes.mts";
import { CMD_INVERT_RETURN, connection, makeWord, simple } from "../ast/nodes.mts";
import { tokenize } from "./lexer.mts";
import type { Token } from "./lexer.mts";
import { parseCond } from "./cond.mts";

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
const CASE_TERM: TermSet = { words: new Set(["esac"]), ops: new Set([";;"]) };
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
  private peekAt(k: number): Token {
    return this.toks[this.p + k] ?? { type: "EOF", value: "", pos: -1, line: -1 };
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
  private isAmp(): boolean {
    const t = this.peek();
    return t.type === "OP" && t.value === "&";
  }

  private parseCompoundList(term: TermSet): Command {
    this.skipSeparators();
    if (this.atTerminator(term)) {
      const t = this.peek();
      throw new ParseError(`syntax error near \`${t.value || "<eof>"}\` (line ${t.line})`);
    }
    let result: Command | null = null;
    for (;;) {
      let cmd = this.parseAndOr();
      let hadSep = false;
      if (this.isAmp()) {
        this.advance();
        cmd = { type: "background", command: cmd };
        hadSep = true;
      }
      result = result === null ? cmd : connection(";", result, cmd);
      while (this.isSeparator()) {
        this.advance();
        hadSep = true;
      }
      if (this.atTerminator(term)) break;
      if (!hadSep) break;
    }
    return result ?? { type: "simple", words: [], redirects: [] };
  }

  private parseAndOr(): Command {
    let left = this.parsePipeline();
    for (;;) {
      const t = this.peek();
      if (t.type === "OP" && (t.value === "&&" || t.value === "||")) {
        this.advance();
        this.skipLinebreak();
        left = connection(t.value, left, this.parsePipeline());
      } else {
        break;
      }
    }
    return left;
  }

  private parsePipeline(): Command {
    let invert = false;
    if (this.wordIs("!")) {
      this.advance();
      invert = true;
    }
    let cmd = this.parseCommand();
    if (this.peek().type === "OP" && this.peek().value === "|") {
      const stages = [cmd];
      while (this.peek().type === "OP" && this.peek().value === "|") {
        this.advance();
        this.skipLinebreak();
        stages.push(this.parseCommand());
      }
      cmd = { type: "pipeline", stages };
    }
    if (invert) cmd.flags = (cmd.flags ?? 0) ^ CMD_INVERT_RETURN;
    return cmd;
  }

  private parseCommand(): Command {
    const t = this.peek();

    if (t.type === "ARITH") {
      this.advance();
      return { type: "arith", expression: t.value };
    }
    if (t.type === "COND") {
      this.advance();
      return { type: "cond", expr: parseCond(t.value) };
    }
    if (t.type === "OP" && t.value === "(") return this.trailingRedirects(this.parseSubshell());

    if (t.type === "WORD") {
      switch (t.value) {
        case "{": return this.trailingRedirects(this.parseGroup());
        case "if": return this.trailingRedirects(this.parseIf());
        case "while": return this.trailingRedirects(this.parseWhile(false));
        case "until": return this.trailingRedirects(this.parseWhile(true));
        case "for": return this.trailingRedirects(this.parseFor());
        case "function": return this.parseFunctionKeyword();
        case "case": return this.trailingRedirects(this.parseCase());
      }
      // name () compound   → function definition
      if (
        isName(t.value) &&
        this.peekAt(1).type === "OP" && this.peekAt(1).value === "(" &&
        this.peekAt(2).type === "OP" && this.peekAt(2).value === ")"
      ) {
        return this.parseFunctionDef(t.value);
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

  // `name () compound-command`
  private parseFunctionDef(name: string): Command {
    this.advance(); // name
    this.advance(); // (
    this.advance(); // )
    this.skipLinebreak();
    return { type: "function", name, body: this.parseCommand() };
  }

  // `function name [()] compound-command`
  private parseFunctionKeyword(): Command {
    this.eatWord("function");
    const nameTok = this.peek();
    if (nameTok.type !== "WORD") {
      throw new ParseError(`function: expected a name (line ${nameTok.line})`);
    }
    this.advance();
    if (this.peek().type === "OP" && this.peek().value === "(") {
      this.advance();
      if (!(this.peek().type === "OP" && this.peek().value === ")")) {
        throw new ParseError(`function ${nameTok.value}: expected \`)\` (line ${this.peek().line})`);
      }
      this.advance();
    }
    this.skipLinebreak();
    return { type: "function", name: nameTok.value, body: this.parseCommand() };
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

  private parseCase(): Command {
    this.eatWord("case");
    const w = this.peek();
    if (w.type !== "WORD") {
      throw new ParseError(`case: expected a word (line ${w.line})`);
    }
    this.advance();
    const word = makeWord(w.value);
    this.skipLinebreak();
    this.eatWord("in");
    this.skipLinebreak();

    const clauses: CasePattern[] = [];
    while (!this.wordIs("esac")) {
      if (this.peek().type === "OP" && this.peek().value === "(") this.advance();

      const patterns: Word[] = [this.parseCasePattern()];
      while (this.peek().type === "OP" && this.peek().value === "|") {
        this.advance();
        patterns.push(this.parseCasePattern());
      }

      const rp = this.peek();
      if (!(rp.type === "OP" && rp.value === ")")) {
        throw new ParseError(`case: expected \`)\` (line ${rp.line})`);
      }
      this.advance();
      this.skipLinebreak();

      const body = this.atCaseClauseEnd() ? null : this.parseCompoundList(CASE_TERM);
      clauses.push({ patterns, body });

      if (this.peek().type === "OP" && this.peek().value === ";;") {
        this.advance();
        this.skipLinebreak();
      } else {
        break; // final clause may omit `;;`
      }
    }
    this.eatWord("esac");
    return { type: "case", word, clauses };
  }

  private parseCasePattern(): Word {
    const t = this.peek();
    if (t.type !== "WORD") {
      throw new ParseError(`case: expected a pattern (line ${t.line})`);
    }
    this.advance();
    return makeWord(t.value);
  }

  private atCaseClauseEnd(): boolean {
    const t = this.peek();
    return (
      t.type === "EOF" ||
      (t.type === "WORD" && t.value === "esac") ||
      (t.type === "OP" && t.value === ";;")
    );
  }

  private parseSimple(): Command {
    const words: Word[] = [];
    const redirects: Redirect[] = [];
    for (;;) {
      const t = this.peek();
      if (t.type === "WORD") words.push(makeWord(this.advance().value));
      else if (t.type === "REDIR") redirects.push(this.parseRedir());
      else break;
    }
    if (words.length === 0 && redirects.length === 0) {
      const t = this.peek();
      throw new ParseError(`syntax error near \`${t.value || "<eof>"}\` (line ${t.line})`);
    }
    return simple(words, redirects);
  }

  /** Attach any redirections that trail a compound command (e.g. `done > f`). */
  private trailingRedirects(cmd: Command): Command {
    const reds: Redirect[] = [];
    while (this.peek().type === "REDIR") reds.push(this.parseRedir());
    if (reds.length > 0) cmd.redirects = (cmd.redirects ?? []).concat(reds);
    return cmd;
  }

  private parseRedir(): Redirect {
    const tok = this.advance(); // REDIR
    const m = /^(\d*)(.*)$/.exec(tok.value)!;
    const fdStr = m[1]!;
    const op = m[2]!;

    if (tok.heredoc !== undefined) {
      const fd = fdStr !== "" ? parseInt(fdStr, 10) : 0;
      return { op, fd, target: makeWord(tok.heredoc.body), expand: !tok.heredoc.quoted };
    }

    const t = this.peek();
    if (t.type !== "WORD") {
      throw new ParseError(`expected a redirection target (line ${t.line})`);
    }
    this.advance();

    let fd: number;
    if (fdStr !== "") fd = parseInt(fdStr, 10);
    else if (op === "&>" || op === "&>>") fd = -1; // both stdout+stderr
    else if (op === "<" || op === "<<<" || op === "<&") fd = 0;
    else fd = 1;

    return { op, fd, target: makeWord(t.value) };
  }
}

export const parse = (src: string): Command | null =>
  new Parser(tokenize(src)).parseProgram();
