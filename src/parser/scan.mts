/* Raw-text scanners for balanced shell constructs, shared by the lexer and the
 * word parser so command-substitution extraction agrees between them. These
 * find the *extent* of a construct in the source; the real parsing happens
 * later on the extracted text. Follows bash's rules (GPLv3+; see NOTICE.md). */

const isWordChar = (c: string | undefined): boolean => c !== undefined && /[A-Za-z0-9_]/.test(c);

/** Index just past a single-quoted span; `s[i]` is the opening `'`. */
const endSingle = (s: string, i: number): number => {
  i++;
  while (i < s.length && s[i] !== "'") i++;
  return i + 1;
};
/** Index just past a backquoted span; `s[i]` is the opening backtick. */
const endBacktick = (s: string, i: number): number => {
  i++;
  while (i < s.length) {
    if (s[i] === "\\") { i += 2; continue; }
    if (s[i] === "`") return i + 1;
    i++;
  }
  return i;
};
/** Index just past a `${…}` span; `s[i]` is the `$`. Brace-balanced, quote-aware. */
const endBrace = (s: string, i: number): number => {
  i += 2; // past ${
  let depth = 1;
  while (i < s.length && depth > 0) {
    const c = s[i]!;
    if (c === "\\") { i += 2; continue; }
    if (c === "'") { i = endSingle(s, i); continue; }
    if (c === '"') { i = endDouble(s, i); continue; }
    if (c === "{") depth++;
    else if (c === "}") depth--;
    i++;
  }
  return i;
};
/** Index just past a `$((…))` span; `s[i]` is the `$`. */
const endArith = (s: string, i: number): number => {
  i += 3; // past $((
  let depth = 2;
  while (i < s.length && depth > 0) {
    const c = s[i]!;
    if (c === "\\") { i += 2; continue; }
    if (c === "(") depth++;
    else if (c === ")") depth--;
    i++;
  }
  return i;
};
/** Index just past a double-quoted span; `s[i]` is the opening `"`. Descends
 *  into `$(…)`, `${…}`, `$((…))`, and backticks so their quotes stay balanced. */
export const endDouble = (s: string, i: number): number => {
  i++; // past opening "
  while (i < s.length) {
    const c = s[i]!;
    if (c === "\\") { i += 2; continue; }
    if (c === '"') return i + 1;
    if (c === "`") { i = endBacktick(s, i); continue; }
    if (c === "$" && s[i + 1] === "(" && s[i + 2] === "(") { i = endArith(s, i); continue; }
    if (c === "$" && s[i + 1] === "(") { i = scanCmdSub(s, i + 2) + 1; continue; }
    if (c === "$" && s[i + 1] === "{") { i = endBrace(s, i); continue; }
    i++;
  }
  return i;
};

/** Given `s[start]` is the first char of a command-substitution body (just past
 *  `$(` / `<(` / `>(`), return the index of the terminating `)`. Aware of
 *  quotes, nested substitutions/subshells, comments, and `case` patterns —
 *  whose terminating `)` is not a grouping paren and must not close the sub. */
export const scanCmdSub = (s: string, start: number): number => {
  let i = start;
  let depth = 1;
  // A frame per open `case`: `sawIn` once its `in` is seen, `pat` while scanning
  // a pattern (its bare `)` ends the pattern), `grp` = extglob/paren nesting in
  // that pattern, `atStart` before the pattern's first non-space char.
  const cases: Array<{ sawIn: boolean; pat: boolean; grp: number; atStart: boolean }> = [];
  const top = (): { sawIn: boolean; pat: boolean; grp: number; atStart: boolean } | undefined =>
    cases[cases.length - 1];
  let word = "";
  let prev = "";
  const boundary = (): void => {
    const f = top();
    if (word === "case") cases.push({ sawIn: false, pat: false, grp: 0, atStart: false });
    else if (word === "esac") cases.pop();
    else if (word === "in" && f !== undefined && !f.sawIn) { f.sawIn = true; f.pat = true; f.atStart = true; }
    word = "";
  };

  while (i < s.length) {
    const c = s[i]!;
    if (isWordChar(c)) { word += c; prev = c; i++; continue; }
    boundary();
    if (c === "\\") { prev = c; i += 2; continue; }
    if (c === "'") { i = endSingle(s, i); prev = "'"; continue; }
    if (c === '"') { i = endDouble(s, i); prev = '"'; continue; }
    if (c === "`") { i = endBacktick(s, i); prev = "`"; continue; }
    if (c === "$" && s[i + 1] === "(" && s[i + 2] === "(") { i = endArith(s, i); prev = ")"; continue; }
    if (c === "$" && s[i + 1] === "(") { i = scanCmdSub(s, i + 2) + 1; prev = ")"; continue; }
    if (c === "$" && s[i + 1] === "{") { i = endBrace(s, i); prev = "}"; continue; }
    // A `#` after whitespace / operator / start begins a comment.
    if (c === "#" && (prev === "" || /\s/.test(prev) || prev === ";" || prev === "&" || prev === "|" || prev === "(")) {
      while (i < s.length && s[i] !== "\n") i++;
      prev = "";
      continue;
    }
    const f = top();
    if (c === "(") {
      if (f !== undefined && f.pat) {
        if (f.atStart) f.atStart = false; // optional leading `(`, not a group
        else f.grp++;
      } else depth++;
      prev = "("; i++; continue;
    }
    if (c === ")") {
      if (f !== undefined && f.pat && f.grp > 0) { f.grp--; }        // close extglob group
      else if (f !== undefined && f.pat) { f.pat = false; }          // pattern terminator
      else { depth--; if (depth === 0) return i; }
      prev = ")"; i++; continue;
    }
    if (c === ";" && f !== undefined) { // `;;` / `;&` / `;;&` reopen pattern mode
      const two = s[i + 1] === ";" || s[i + 1] === "&";
      if (two) { f.pat = true; f.grp = 0; f.atStart = true; }
    }
    if (f !== undefined && f.pat && f.atStart && !/\s/.test(c)) f.atStart = false;
    prev = c;
    i++;
  }
  return i; // unterminated
};
