/* Brace expansion — `{a,b,c}` and `{x..y[..incr]}` (bash; GPLv3+, see NOTICE.md).
 *
 * Brace expansion is purely textual and runs before any other expansion, so it
 * happens at transpile time: one word token becomes several word texts. Quotes,
 * backslashes, and `${...}` / `$(...)` / backticks are skipped, and a `{...}`
 * with no top-level comma and no sequence is left literal. */

/** If s[i] begins a construct that brace expansion skips over, return the index
 *  just past it; otherwise null. */
const skip = (s: string, i: number): number | null => {
  const c = s[i];
  if (c === "\\") return i + 2;
  if (c === "'") {
    let j = i + 1;
    while (j < s.length && s[j] !== "'") j++;
    return j + 1;
  }
  if (c === '"') {
    let j = i + 1;
    while (j < s.length && s[j] !== '"') {
      if (s[j] === "\\") j++;
      j++;
    }
    return j + 1;
  }
  if (c === "`") {
    let j = i + 1;
    while (j < s.length && s[j] !== "`") {
      if (s[j] === "\\") j++;
      j++;
    }
    return j + 1;
  }
  if (c === "$" && (s[i + 1] === "{" || s[i + 1] === "(")) {
    const open = s[i + 1]!;
    const close = open === "{" ? "}" : ")";
    let depth = 0;
    let j = i + 1;
    for (; j < s.length; j++) {
      if (s[j] === open) depth++;
      else if (s[j] === close && --depth === 0) {
        j++;
        break;
      }
    }
    return j;
  }
  return null;
};

const matchBrace = (s: string, open: number): number => {
  let depth = 0;
  let i = open;
  while (i < s.length) {
    const sk = skip(s, i);
    if (sk !== null) {
      i = sk;
      continue;
    }
    const c = s[i];
    if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return i;
    i++;
  }
  return -1;
};

const hasTopComma = (body: string): boolean => {
  let depth = 0;
  let i = 0;
  while (i < body.length) {
    const sk = skip(body, i);
    if (sk !== null) {
      i = sk;
      continue;
    }
    const c = body[i];
    if (c === "{") depth++;
    else if (c === "}") depth--;
    else if (c === "," && depth === 0) return true;
    i++;
  }
  return false;
};

const splitTopCommas = (body: string): string[] => {
  const out: string[] = [];
  let depth = 0;
  let cur = "";
  let i = 0;
  while (i < body.length) {
    const sk = skip(body, i);
    if (sk !== null) {
      cur += body.slice(i, sk);
      i = sk;
      continue;
    }
    const c = body[i]!;
    if (c === "{") depth++;
    else if (c === "}") depth--;
    if (c === "," && depth === 0) {
      out.push(cur);
      cur = "";
    } else {
      cur += c;
    }
    i++;
  }
  out.push(cur);
  return out;
};

const hasLeadingZero = (x: string): boolean => {
  const d = x.startsWith("-") ? x.slice(1) : x;
  return d.length > 1 && d[0] === "0";
};
const fmtNum = (v: number, pad: boolean, width: number): string =>
  pad ? (v < 0 ? "-" : "") + Math.abs(v).toString().padStart(width, "0") : String(v);

const expandSequence = (body: string): string[] | null => {
  let m = /^(-?\d+)\.\.(-?\d+)(?:\.\.(-?\d+))?$/.exec(body);
  if (m) {
    const a = parseInt(m[1]!, 10);
    const b = parseInt(m[2]!, 10);
    let inc = m[3] !== undefined ? Math.abs(parseInt(m[3], 10)) : 1;
    if (inc === 0) inc = 1;
    const pad = hasLeadingZero(m[1]!) || hasLeadingZero(m[2]!);
    const width = Math.max(m[1]!.replace("-", "").length, m[2]!.replace("-", "").length);
    const out: string[] = [];
    if (a <= b) for (let v = a; v <= b; v += inc) out.push(fmtNum(v, pad, width));
    else for (let v = a; v >= b; v -= inc) out.push(fmtNum(v, pad, width));
    return out;
  }
  m = /^([A-Za-z])\.\.([A-Za-z])(?:\.\.(-?\d+))?$/.exec(body);
  if (m) {
    const a = m[1]!.charCodeAt(0);
    const b = m[2]!.charCodeAt(0);
    let inc = m[3] !== undefined ? Math.abs(parseInt(m[3], 10)) : 1;
    if (inc === 0) inc = 1;
    const out: string[] = [];
    if (a <= b) for (let v = a; v <= b; v += inc) out.push(String.fromCharCode(v));
    else for (let v = a; v >= b; v -= inc) out.push(String.fromCharCode(v));
    return out;
  }
  return null;
};

const findBrace = (s: string): { pre: string; body: string; post: string } | null => {
  let i = 0;
  while (i < s.length) {
    const sk = skip(s, i);
    if (sk !== null) {
      i = sk;
      continue;
    }
    if (s[i] === "{") {
      const close = matchBrace(s, i);
      if (close > i) {
        const body = s.slice(i + 1, close);
        if (hasTopComma(body) || expandSequence(body) !== null) {
          return { pre: s.slice(0, i), body, post: s.slice(close + 1) };
        }
      }
    }
    i++;
  }
  return null;
};

/** Expand brace groups in a word's raw text into zero-or-more word texts. */
export const braceExpand = (s: string): string[] => {
  const m = findBrace(s);
  if (m === null) return [s];
  const items = expandSequence(m.body) ?? splitTopCommas(m.body);
  const out: string[] = [];
  for (const item of items) {
    for (const head of braceExpand(m.pre + item)) {
      for (const tail of braceExpand(m.post)) out.push(head + tail);
    }
  }
  return out;
};
