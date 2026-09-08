/* Pattern matching (fnmatch-style), for `case` and later `[[ == ]]` and
 * pathname expansion. Follows bash pattern rules (GPLv3+; see NOTICE.md),
 * minus extglob for now: `*`, `?`, `[...]` character classes with ranges and
 * `!`/`^` negation, and backslash escaping. */

const escapeRe = (c: string): string => (/[.*+?^${}()|[\]\\]/.test(c) ? "\\" + c : c);

/** Translate a glob pattern to an anchored regular-expression source string.
 *  The AOT emitter inlines this at transpile time as a `/.../s` literal for
 *  static patterns; the runtime uses it for dynamic ones. */
export const globToRegExpSource = (pat: string): string => {
  let re = "^";
  let i = 0;
  while (i < pat.length) {
    const c = pat[i]!;
    if (c === "\\") {
      const n = pat[i + 1];
      if (n !== undefined) {
        re += escapeRe(n);
        i += 2;
      } else {
        re += "\\\\";
        i++;
      }
      continue;
    }
    if (c === "*") {
      re += ".*";
      i++;
      continue;
    }
    if (c === "?") {
      re += ".";
      i++;
      continue;
    }
    if (c === "[") {
      let j = i + 1;
      let neg = false;
      if (pat[j] === "!" || pat[j] === "^") {
        neg = true;
        j++;
      }
      let cls = "";
      if (pat[j] === "]") {
        cls += "\\]";
        j++;
      }
      while (j < pat.length && pat[j] !== "]") {
        const ch = pat[j]!;
        if (ch === "\\") {
          cls += "\\" + (pat[j + 1] ?? "");
          j += 2;
          continue;
        }
        cls += ch === "^" || ch === "]" ? "\\" + ch : ch;
        j++;
      }
      if (j >= pat.length) {
        // Unterminated '[' is a literal '['.
        re += "\\[";
        i++;
        continue;
      }
      re += "[" + (neg ? "^" : "") + cls + "]";
      i = j + 1;
      continue;
    }
    re += escapeRe(c);
    i++;
  }
  return re + "$";
};

export const globMatch = (str: string, pattern: string): boolean =>
  new RegExp(globToRegExpSource(pattern), "s").test(str);
