/* Word expansion — the M0 slice of bash's `subst.c` (GPLv3+; see NOTICE.md).
 *
 * Implemented: single/double quotes, backslash escapes, `$name`, `${name}`,
 * a few special parameters (`$?`, `$#`, `$0`, `$$`), command substitution
 * `$(...)`, then field splitting on the default IFS and quote removal.
 *
 * Not yet: parameter expansion operators (`${x:-y}` …), arithmetic `$(())`,
 * pathname globbing, `$@`/`$*`, positional parameters, tilde, brace expansion.
 */

import type { Word } from "../ast/nodes.mts";
import type { Shell } from "./shell.mts";

const isNameStart = (c: string): boolean =>
  (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "_";
const isNameChar = (c: string): boolean => isNameStart(c) || (c >= "0" && c <= "9");
const isIFSWhitespace = (c: string): boolean => c === " " || c === "\t" || c === "\n";

/** A scan produces the assembled expansion plus, per character, whether it is
 *  subject to field splitting (i.e. came from an unquoted expansion). */
interface Scan {
  chars: string[];
  splittable: boolean[];
  /** Word had quotes or literal characters → an empty result still yields a field. */
  anchored: boolean;
}

class Expander {
  private readonly shell: Shell;
  private readonly t: string;
  private i = 0;
  private readonly out: Scan = { chars: [], splittable: [], anchored: false };

  constructor(shell: Shell, text: string) {
    this.shell = shell;
    this.t = text;
  }

  private at(k = 0): string | undefined {
    return this.t[this.i + k];
  }

  private emit(s: string, splittable: boolean): void {
    for (const ch of s) {
      this.out.chars.push(ch);
      this.out.splittable.push(splittable);
    }
  }

  async scan(): Promise<Scan> {
    for (;;) {
      const c = this.at();
      if (c === undefined) break;

      if (c === "\\") {
        const nc = this.at(1);
        if (nc === undefined) {
          this.emit("\\", false);
          this.out.anchored = true;
          this.i++;
        } else if (nc === "\n") {
          this.i += 2; // line continuation
        } else {
          this.emit(nc, false);
          this.out.anchored = true;
          this.i += 2;
        }
        continue;
      }

      if (c === "'") {
        this.out.anchored = true;
        this.i++; // opening quote
        for (;;) {
          const d = this.at();
          if (d === undefined) throw new Error("unterminated single quote");
          this.i++;
          if (d === "'") break;
          this.emit(d, false);
        }
        continue;
      }

      if (c === '"') {
        this.out.anchored = true;
        this.i++; // opening quote
        for (;;) {
          const d = this.at();
          if (d === undefined) throw new Error("unterminated double quote");
          if (d === '"') {
            this.i++;
            break;
          }
          if (d === "\\") {
            const nd = this.at(1);
            if (nd !== undefined && (nd === '"' || nd === "\\" || nd === "$" || nd === "`")) {
              this.emit(nd, false);
              this.i += 2;
            } else if (nd === "\n") {
              this.i += 2;
            } else {
              this.emit("\\", false);
              this.i++;
            }
            continue;
          }
          if (d === "$") {
            await this.dollar(false);
            continue;
          }
          // (backtick command substitution inside "" is a later milestone)
          this.emit(d, false);
          this.i++;
        }
        continue;
      }

      if (c === "$") {
        await this.dollar(true);
        continue;
      }

      // Bare character (subject to splitting only if it is not literal — but a
      // literal char is never split; mark it non-splittable, and anchor).
      this.emit(c, false);
      this.out.anchored = true;
      this.i++;
    }
    return this.out;
  }

  /** Handle a `$...` construct. `this.at() === "$"`. */
  private async dollar(splittable: boolean): Promise<void> {
    const n = this.at(1);

    if (n === undefined) {
      this.emit("$", false);
      this.out.anchored = true;
      this.i++;
      return;
    }

    if (n === "(") {
      if (this.at(2) === "(") {
        throw new Error("arithmetic expansion `$(( ))` not implemented yet (planned for M1)");
      }
      // command substitution: copy inner (balanced parens) then run it
      this.i += 2; // past "$("
      let depth = 1;
      let inner = "";
      for (;;) {
        const d = this.at();
        if (d === undefined) throw new Error("unterminated `$( )`");
        this.i++;
        if (d === "(") depth++;
        else if (d === ")") {
          depth--;
          if (depth === 0) break;
        }
        inner += d;
      }
      const value = await this.shell.runCommandSub(inner);
      this.emit(value, splittable);
      return;
    }

    if (n === "{") {
      this.i += 2; // past "${"
      let name = "";
      for (;;) {
        const d = this.at();
        if (d === undefined) throw new Error("unterminated `${ }`");
        this.i++;
        if (d === "}") break;
        name += d;
      }
      this.emit(this.resolveParam(name), splittable);
      return;
    }

    // Special single-character parameters.
    if (n === "?" || n === "$" || n === "#" || (n >= "0" && n <= "9")) {
      this.emit(this.resolveSpecial(n), splittable);
      this.i += 2;
      return;
    }

    if (isNameStart(n)) {
      this.i++; // past "$"
      let name = "";
      for (;;) {
        const d = this.at();
        if (d === undefined || !isNameChar(d)) break;
        name += d;
        this.i++;
      }
      this.emit(this.shell.getVar(name) ?? "", splittable);
      return;
    }

    // A `$` that starts nothing recognizable: literal `$`.
    this.emit("$", false);
    this.out.anchored = true;
    this.i++;
  }

  private resolveSpecial(name: string): string {
    switch (name) {
      case "?":
        return String(this.shell.status);
      case "$":
        return String(process.pid);
      case "#":
        return "0"; // no positional parameters in M0
      case "0":
        return this.shell.name;
      default:
        return ""; // $1..$9 → empty in M0
    }
  }

  private resolveParam(name: string): string {
    if (name === "") throw new Error("bad substitution: ${}");
    if (name.length === 1 && (name === "?" || name === "$" || name === "#" ||
        (name >= "0" && name <= "9"))) {
      return this.resolveSpecial(name);
    }
    for (const ch of name) {
      if (!isNameChar(ch)) {
        throw new Error(`\${${name}}: operator not implemented yet`);
      }
    }
    return this.shell.getVar(name) ?? "";
  }
}

const splitFields = (scan: Scan): string[] => {
  const { chars, splittable } = scan;
  const s = chars.join("");
  if (s.length === 0) return scan.anchored ? [""] : [];

  const fields: string[] = [];
  let cur = "";
  let curStarted = false;
  let i = 0;
  while (i < chars.length) {
    const ch = chars[i]!;
    if (splittable[i] && isIFSWhitespace(ch)) {
      if (curStarted) {
        fields.push(cur);
        cur = "";
        curStarted = false;
      }
      while (i < chars.length && splittable[i] && isIFSWhitespace(chars[i]!)) i++;
      continue;
    }
    cur += ch;
    curStarted = true;
    i++;
  }
  if (curStarted) fields.push(cur);
  if (fields.length === 0) return scan.anchored ? [""] : [];
  return fields;
};

/** Expand one word into zero or more fields (with splitting + quote removal). */
export const expandWord = async (shell: Shell, word: Word): Promise<string[]> => {
  const scan = await new Expander(shell, word.text).scan();
  return splitFields(scan);
};

/** Expand several words, flattening the fields into a single argv-style list. */
export const expandWords = async (shell: Shell, words: Word[]): Promise<string[]> => {
  const argv: string[] = [];
  for (const w of words) argv.push(...(await expandWord(shell, w)));
  return argv;
};

/** Expand an assignment RHS or other context where no field splitting happens. */
export const expandNoSplit = async (shell: Shell, text: string): Promise<string> => {
  const scan = await new Expander(shell, text).scan();
  return scan.chars.join("");
};
