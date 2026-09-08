/* AST node definitions for curse.
 *
 * These mirror the command structures in GNU bash's `command.h` (GPLv3+;
 * see NOTICE.md). Where bash uses a C enum + tagged union, we use a
 * TypeScript discriminated union on the `type` field.
 *
 * M0 implements a subset (simple commands, `;` / `&&` / `||` connections).
 * The remaining command kinds are declared so later milestones only need to
 * fill them in rather than reshape the tree.
 */

/* A redirection. `op` is the operator, `fd` the (left-hand) descriptor it acts
 * on, and `target` the operand word (filename, dup target like "2"/"-", or the
 * here-string / here-doc body). Mirrors bash's REDIRECT (command.h). */
export interface Redirect {
  /** ">" ">>" "<" ">&" "<&" "&>" "&>>" "<<<" ">|" "<<" "<<-" */
  op: string;
  fd: number;
  /** filename / dup target / here-string / here-doc body */
  target: Word;
  /** here-docs: expand `$` in the body (unquoted delimiter) vs. literal. */
  expand?: boolean;
}

/* WORD_DESC (command.h). Faithful to bash: `text` is the raw token text with
 * quotes preserved; quote removal and expansion happen in the runtime. */
export interface Word {
  text: string;
  /** W_* flags from command.h. Unused in M0 (kept 0). */
  flags: number;
}

export const makeWord = (text: string, flags = 0): Word => ({ text, flags });

/* CMD_* flags (command.h). Only the ones we honor so far. */
export const CMD_INVERT_RETURN = 0x04;

/* enum command_type (command.h). */
export type Command =
  | ConnectionCommand
  | PipelineCommand
  | BackgroundCommand
  | SimpleCommand
  | GroupCommand
  | SubshellCommand
  | IfCommand
  | WhileCommand
  | ForCommand
  | ArithForCommand
  | ArithCommand
  | CaseCommand
  | CondCommand
  | ArrayAssignCommand
  | FunctionDef;

/** Connectors between commands. M0 implements ";", "&&", "||". */
export type Connector = ";" | "&" | "&&" | "||" | "|";

export interface CommandBase {
  line?: number;
  /** CMD_* flags from command.h (e.g. invert-return for `!`). Unused in M0. */
  flags?: number;
  redirects?: Redirect[];
}

export interface ConnectionCommand extends CommandBase {
  type: "connection";
  connector: Connector;
  first: Command;
  second: Command;
}

/** A pipeline `a | b | c`; each stage runs in its own subshell. */
export interface PipelineCommand extends CommandBase {
  type: "pipeline";
  stages: Command[];
}

/** `command &` — run in the background (a subshell), don't wait. */
export interface BackgroundCommand extends CommandBase {
  type: "background";
  command: Command;
}

export interface SimpleCommand extends CommandBase {
  type: "simple";
  /** Assignments, command name, and arguments, in source order (faithful to
   *  SIMPLE_COM.words). Leading assignment words are separated at exec time. */
  words: Word[];
  redirects: Redirect[];
}

export interface GroupCommand extends CommandBase {
  type: "group"; // { ...; }
  body: Command;
}

export interface SubshellCommand extends CommandBase {
  type: "subshell"; // ( ...; )
  body: Command;
}

export interface IfCommand extends CommandBase {
  type: "if";
  test: Command;
  consequent: Command;
  alternate: Command | null;
}

export interface WhileCommand extends CommandBase {
  type: "while";
  until: boolean; // true => `until`
  test: Command;
  body: Command;
}

export interface ForCommand extends CommandBase {
  type: "for";
  name: string;
  words: Word[]; // list to iterate; empty => "$@"
  body: Command;
}

/** ARITH_COM (command.h): `(( expression ))`. */
export interface ArithCommand extends CommandBase {
  type: "arith";
  expression: string; // raw arithmetic text (pre-expansion happens at runtime)
}

/** ARITH_FOR_COM (command.h): `for ((init; test; step)) do ... done`. */
export interface ArithForCommand extends CommandBase {
  type: "arith_for";
  init: string;
  test: string;
  step: string;
  body: Command;
}

export interface CasePattern {
  patterns: Word[];
  body: Command | null;
  /** clause terminator: ";;" break, ";&" fall through, ";;&" test next. */
  term: "break" | "fall" | "test";
}

export interface CaseCommand extends CommandBase {
  type: "case";
  word: Word;
  clauses: CasePattern[];
}

/** Array assignment: `name=(elems)` or `name+=(elems)`. */
export interface ArrayAssignCommand extends CommandBase {
  type: "array_assign";
  name: string;
  append: boolean;
  elems: Word[];
}

/** A `[[ ... ]]` conditional expression tree (cf. COND_COM in command.h). */
export type CondExpr =
  | { k: "and"; l: CondExpr; r: CondExpr }
  | { k: "or"; l: CondExpr; r: CondExpr }
  | { k: "not"; e: CondExpr }
  | { k: "unary"; op: string; arg: Word }
  | { k: "binary"; op: string; l: Word; r: Word }
  | { k: "word"; w: Word };

export interface CondCommand extends CommandBase {
  type: "cond";
  expr: CondExpr;
}

export interface FunctionDef extends CommandBase {
  type: "function";
  name: string;
  body: Command;
}

export const connection = (
  connector: Connector,
  first: Command,
  second: Command,
): ConnectionCommand => ({ type: "connection", connector, first, second });

export const simple = (words: Word[], redirects: Redirect[] = []): SimpleCommand => ({
  type: "simple",
  words,
  redirects,
});
