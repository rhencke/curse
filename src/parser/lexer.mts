/* Tokenizer for curse. Ported in spirit from bash's `parse.y` (GPLv3+; see
 * NOTICE.md), reduced to the M0 subset.
 *
 * A "word" is read faithfully to bash: quotes are preserved in the token text
 * and quote removal happens later during expansion. Quoting constructs
 * (' ' " " ` ` $( ) ${ } $(( )) ) are scanned so that metacharacters inside
 * them do not terminate the word.
 */

export type TokenType = "WORD" | "OP" | "NEWLINE" | "ARITH" | "EOF";

export interface Token {
  type: TokenType;
  /** WORD: raw text incl. quotes. OP: the operator. NEWLINE: "\n". EOF: "". */
  value: string;
  pos: number;
  line: number;
}

/** Unquoted characters that terminate a word / act as operators. */
const isBlank = (c: string | undefined): boolean => c === " " || c === "\t";
const isMeta = (c: string | undefined): boolean =>
  c === " " || c === "\t" || c === "\n" ||
  c === ";" || c === "&" || c === "|" ||
  c === "<" || c === ">" || c === "(" || c === ")";

export class LexError extends Error {}

class Lexer {
  private readonly s: string;
  private readonly n: number;
  private i = 0;
  private line = 1;

  constructor(src: string) {
    this.s = src;
    this.n = src.length;
  }

  private at(k = 0): string | undefined {
    return this.s[this.i + k];
  }

  tokenize(): Token[] {
    const out: Token[] = [];
    for (;;) {
      const t = this.next();
      out.push(t);
      if (t.type === "EOF") return out;
    }
  }

  private next(): Token {
    // Skip blanks and line continuations.
    for (;;) {
      const c = this.at();
      if (isBlank(c)) {
        this.i++;
        continue;
      }
      if (c === "\\" && this.at(1) === "\n") {
        this.i += 2;
        this.line++;
        continue;
      }
      if (c === "#") {
        // Comment to end of line.
        while (this.at() !== undefined && this.at() !== "\n") this.i++;
        continue;
      }
      break;
    }

    const pos = this.i;
    const line = this.line;
    const c = this.at();

    if (c === undefined) return { type: "EOF", value: "", pos, line };

    if (c === "\n") {
      this.i++;
      this.line++;
      return { type: "NEWLINE", value: "\n", pos, line };
    }

    // Operators (M0 subset).
    if (c === ";") {
      if (this.at(1) === ";") throw new LexError("`;;` (case) not supported yet");
      this.i++;
      return { type: "OP", value: ";", pos, line };
    }
    if (c === "&") {
      if (this.at(1) === "&") {
        this.i += 2;
        return { type: "OP", value: "&&", pos, line };
      }
      throw new LexError("background `&` not supported yet (planned for M3)");
    }
    if (c === "|") {
      if (this.at(1) === "|") {
        this.i += 2;
        return { type: "OP", value: "||", pos, line };
      }
      throw new LexError("pipelines `|` not supported yet (planned for M3)");
    }
    if (c === "<" || c === ">") {
      throw new LexError(`redirection \`${c}\` not supported yet (planned for M3)`);
    }
    if (c === "(") {
      if (this.at(1) === "(") {
        return { type: "ARITH", value: this.scanArithCommand(), pos, line };
      }
      this.i++;
      return { type: "OP", value: "(", pos, line };
    }
    if (c === ")") {
      this.i++;
      return { type: "OP", value: ")", pos, line };
    }

    // Otherwise, a word.
    return { type: "WORD", value: this.readWord(), pos, line };
  }

  private readWord(): string {
    let buf = "";
    for (;;) {
      const c = this.at();
      if (c === undefined || isMeta(c)) break;

      if (c === "\\") {
        const nc = this.at(1);
        if (nc === "\n") {
          // line continuation: remove both
          this.i += 2;
          this.line++;
          continue;
        }
        if (nc === undefined) {
          buf += "\\";
          this.i++;
          continue;
        }
        buf += "\\" + nc;
        this.i += 2;
        continue;
      }

      if (c === "'") {
        buf += this.scanSingle();
        continue;
      }
      if (c === '"') {
        buf += this.scanDouble();
        continue;
      }
      if (c === "`") {
        buf += this.scanBacktick();
        continue;
      }
      if (c === "$") {
        const nc = this.at(1);
        if (nc === "(" && this.at(2) === "(") {
          buf += this.scanBalanced("$((", "(", ")", 2);
          continue;
        }
        if (nc === "(") {
          buf += this.scanBalanced("$(", "(", ")", 1);
          continue;
        }
        if (nc === "{") {
          buf += this.scanBalanced("${", "{", "}", 1);
          continue;
        }
        buf += "$";
        this.i++;
        continue;
      }

      buf += c;
      this.i++;
    }
    return buf;
  }

  private scanSingle(): string {
    // this.at() === "'"
    let buf = "'";
    this.i++;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new LexError("unterminated single quote");
      buf += c;
      this.i++;
      if (c === "'") return buf;
      if (c === "\n") this.line++;
    }
  }

  private scanDouble(): string {
    // this.at() === '"'
    let buf = '"';
    this.i++;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new LexError("unterminated double quote");
      if (c === '"') {
        buf += '"';
        this.i++;
        return buf;
      }
      if (c === "\\") {
        const nc = this.at(1);
        if (nc === undefined) throw new LexError("unterminated double quote");
        buf += "\\" + nc;
        this.i += 2;
        if (nc === "\n") this.line++;
        continue;
      }
      if (c === "`") {
        buf += this.scanBacktick();
        continue;
      }
      if (c === "$") {
        const nc = this.at(1);
        if (nc === "(" && this.at(2) === "(") {
          buf += this.scanBalanced("$((", "(", ")", 2);
          continue;
        }
        if (nc === "(") {
          buf += this.scanBalanced("$(", "(", ")", 1);
          continue;
        }
        if (nc === "{") {
          buf += this.scanBalanced("${", "{", "}", 1);
          continue;
        }
        buf += "$";
        this.i++;
        continue;
      }
      if (c === "\n") this.line++;
      buf += c;
      this.i++;
    }
  }

  private scanBacktick(): string {
    // this.at() === "`"
    let buf = "`";
    this.i++;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new LexError("unterminated backquote");
      if (c === "\\") {
        const nc = this.at(1);
        buf += "\\" + (nc ?? "");
        this.i += nc === undefined ? 1 : 2;
        continue;
      }
      buf += c;
      this.i++;
      if (c === "`") return buf;
      if (c === "\n") this.line++;
    }
  }

  /** Scan a `(( ... ))` arithmetic command, returning the inner text (without
   *  the surrounding `((` `))`). The body is captured raw so operators such as
   *  `<`, `>`, `&` inside it are not seen by the shell tokenizer. */
  private scanArithCommand(): string {
    // this.at() === "(" && this.at(1) === "("
    this.i += 2;
    let opens = 2;
    let buf = "";
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new LexError("unterminated `(( ))`");
      this.i++;
      if (c === "(") {
        opens++;
        buf += c;
        continue;
      }
      if (c === ")") {
        opens--;
        if (opens >= 2) buf += c; // a nested inner paren
        if (opens === 0) return buf;
        continue;
      }
      if (c === "\n") this.line++;
      buf += c;
    }
  }

  /** Scan a balanced construct such as `$( ... )`, `${ ... }`, `$(( ... ))`.
   *  `prefix` is copied verbatim; then we balance `open`/`close` until depth 0. */
  private scanBalanced(prefix: string, open: string, close: string, closesNeeded: number): string {
    let buf = prefix;
    this.i += prefix.length;
    let depth = closesNeeded;
    for (;;) {
      const c = this.at();
      if (c === undefined) throw new LexError(`unterminated \`${prefix} ... ${close.repeat(closesNeeded)}\``);
      if (c === open) depth++;
      else if (c === close) {
        depth--;
        buf += c;
        this.i++;
        if (depth === 0) return buf;
        continue;
      }
      if (c === "\n") this.line++;
      buf += c;
      this.i++;
    }
  }
}

export const tokenize = (src: string): Token[] => new Lexer(src).tokenize();
