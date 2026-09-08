/* AOT emitter: compile a command tree into a standalone `.mts` module.
 *
 * The output is real TypeScript that leans on JavaScript's dynamism:
 *  - a command is a live lookup on the `sh.commands` Proxy, so a bash function
 *    definition (`sh.commands.name = sh.func(...)`) monkeypatches the binding;
 *  - assignment is property mutation on `sh.env`;
 *  - word expansion compiles inline (template literals; `sh.fields`/`sh.S` for
 *    field splitting; inline `sh.sub(...)` for command substitution);
 *  - control flow becomes native TS. `sh.status` carries `$?`.
 *
 * Word structure comes from the shared parser (parser/word.mts), so the
 * compiled output and the interpreter agree. */

import type { Command, CondExpr, FunctionDef, SimpleCommand, Word } from "../ast/nodes.mts";
import { CMD_INVERT_RETURN } from "../ast/nodes.mts";
import { parse } from "../parser/parser.mts";
import { parseHeredoc, parseWord } from "../parser/word.mts";
import type { Param, WordPart } from "../parser/word.mts";
import { braceExpand } from "../parser/brace.mts";
import { globToRegExpSource } from "../runtime/glob.mts";

export interface EmitOptions {
  /** Import specifier (path or file: URL) for the runtime's `Shell`. */
  runtimeSpecifier: string;
}

const pad = (n: number): string => "  ".repeat(n);
/** Add one indent level to every non-empty line of an already-emitted block. */
const bump = (s: string): string => s.replace(/^(?=.)/gm, "  ");
/** An assignment word: name(1), optional `[sub(3)]`(2), optional `+`(4), value(5). */
const ASSIGN = /^([A-Za-z_][A-Za-z0-9_]*)(\[([^\]]*)\])?(\+)?=([\s\S]*)$/;
const ident = (s: string): boolean => /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);
const escTemplate = (s: string): string =>
  s.replace(/\\/g, "\\\\").replace(/`/g, "\\`").replace(/\$/g, "\\$");

interface WordCode {
  /** true => a `...spread` producing zero+ args; false => a single arg. */
  spread: boolean;
  code: string;
}

/** Does the script use `set` anywhere? If not, `set -e` can never be on, so we
 *  skip the errexit `condDepth` guards and keep the output clean. */
const usesSet = (cmd: Command): boolean => {
  switch (cmd.type) {
    case "simple": return cmd.words.length > 0 && cmd.words[0]!.text === "set";
    case "connection": return usesSet(cmd.first) || usesSet(cmd.second);
    case "pipeline": return cmd.stages.some(usesSet);
    case "background": return usesSet(cmd.command);
    case "group": case "subshell": return usesSet(cmd.body);
    case "if":
      return usesSet(cmd.test) || usesSet(cmd.consequent) ||
        (cmd.alternate !== null && usesSet(cmd.alternate));
    case "while": return usesSet(cmd.test) || usesSet(cmd.body);
    case "for": case "arith_for": case "function": return usesSet(cmd.body);
    case "case": return cmd.clauses.some((c) => c.body !== null && usesSet(c.body));
    case "arith": case "cond": case "array_assign": return false;
  }
};

class Emitter {
  private forId = 0;
  private caseId = 0;
  guards = false;

  /** Emit a command in an errexit-suppressed scope (a condition, `!`, or the
   *  non-final operand of && / ||). When the script never uses `set`, errexit
   *  can't be on, so we skip the scope and keep the output clean. */
  private suppressed(child: Command, ind: number): string {
    if (!this.guards) return this.command(child, ind);
    const i = pad(ind);
    return `${i}{\n${pad(ind + 1)}using _ = sh.suppress();\n${this.command(child, ind + 1)}\n${i}}`;
  }

  /* ---------------- words ---------------- */

  private specialExpr(name: string): string {
    switch (name) {
      case "?": return "String(sh.status)";
      case "#": return "String(sh.positional.length)";
      case "$": return "String(sh.pid)";
      case "!": return "String(sh.lastBgPid)";
      case "0": return "sh.name";
      case "@": case "*": return 'sh.positional.join(" ")';
      default: return `sh.param(${Number(name)})`;
    }
  }

  /** The value of a param reference as a string expression (scalar, array
   *  element, or all elements joined). Not nounset-aware — plain `${x}` uses
   *  sh.ref() below. */
  private valStr(prm: Param): string {
    const J = JSON.stringify;
    if (prm.special) return this.specialExpr(prm.name);
    if (prm.sub === "@" || prm.sub === "*") return `sh.arrayValues(${J(prm.name)}).join(" ")`;
    if (prm.sub !== "") {
      return `((await sh.elemGet(${J(prm.name)}, ${J(prm.sub)})) ?? "")`;
    }
    return `sh.env.${prm.name}`;
  }

  private paramExpr(prm: Param): string {
    const J = JSON.stringify;
    if (prm.indices) return `sh.arrayIndices(${J(prm.name)}).join(" ")`;
    if (prm.indirect) return `sh.indirect(${J(prm.name)})`;
    const base = this.valStr(prm);
    const arg = (): string => this.templateOf(parseWord(prm.arg).parts);
    const arg2 = (): string => this.templateOf(parseWord(prm.arg2).parts);
    if (prm.length) {
      if (prm.name === "@" || prm.name === "*" || prm.name === "#") return "String(sh.positional.length)";
      if (prm.sub === "@" || prm.sub === "*") return `String(sh.arrayLen(${J(prm.name)}))`;
      return `String(${base}).length`;
    }
    switch (prm.op) {
      case "": return prm.special || prm.sub !== "" ? base : `sh.ref(${J(prm.name)})`;
      case ":-": return `(String(${base}) || ${arg()})`;
      case "-": return `(sh.has(${J(prm.name)}) ? ${base} : ${arg()})`;
      case ":+": return `(String(${base}) ? ${arg()} : "")`;
      case "+": return `(sh.has(${J(prm.name)}) ? ${arg()} : "")`;
      case ":?": return `(String(${base}) || sh.paramError(${J(prm.name)}, ${arg()}))`;
      case "?": return `(sh.has(${J(prm.name)}) ? ${base} : sh.paramError(${J(prm.name)}, ${arg()}))`;
      case ":=": return `(String(${base}) || (sh.env.${prm.name} = ${arg()}))`;
      case "=": return `(sh.has(${J(prm.name)}) ? ${base} : (sh.env.${prm.name} = ${arg()}))`;
      case "#": return `sh.trimPrefix(String(${base}), ${arg()}, false)`;
      case "##": return `sh.trimPrefix(String(${base}), ${arg()}, true)`;
      case "%": return `sh.trimSuffix(String(${base}), ${arg()}, false)`;
      case "%%": return `sh.trimSuffix(String(${base}), ${arg()}, true)`;
      case "/": return `sh.replaceGlob(String(${base}), ${arg()}, ${arg2()}, false, "")`;
      case "//": return `sh.replaceGlob(String(${base}), ${arg()}, ${arg2()}, true, "")`;
      case "/#": return `sh.replaceGlob(String(${base}), ${arg()}, ${arg2()}, false, "#")`;
      case "/%": return `sh.replaceGlob(String(${base}), ${arg()}, ${arg2()}, false, "%")`;
      case ":": return `await sh.substr(String(${base}), ${J(prm.arg)}, ${J(prm.arg2)})`;
      default: throw new Error(`parameter operator not supported: ${prm.op}`);
    }
  }

  private valueExpr(p: Exclude<WordPart, { k: "lit" }>): string {
    switch (p.k) {
      case "param":
        return this.paramExpr(p.p);
      case "arith":
        return `await sh.arithStr(${JSON.stringify(p.expr)})`;
      case "cmdsub": {
        const sub = parse(p.src);
        const body = sub === null ? "" : this.command(sub, 0);
        return `await sh.sub(async (sh) => {\n${body}\n})`;
      }
    }
  }

  private templateOf(parts: WordPart[]): string {
    if (parts.length === 0) return '""';
    if (parts.length === 1 && parts[0]!.k === "lit") return JSON.stringify(parts[0]!.s);
    let s = "`";
    for (const p of parts) {
      s += p.k === "lit" ? escTemplate(p.s) : "${" + this.valueExpr(p) + "}";
    }
    return s + "`";
  }

  private fieldArg(p: WordPart): string {
    if (p.k === "lit") return JSON.stringify(p.s);
    const v = this.valueExpr(p);
    return p.quoted ? "`${" + v + "}`" : `sh.S(${v})`;
  }

  private word(text: string): WordCode {
    const pw = parseWord(text);

    // "$@"/$@ and "${arr[@]}"/${arr[@]}/${!arr[@]} each expand to separate
    // fields. ($* / ${arr[*]} are scalar joins and flow through the paths below.)
    const spreadCode = (p: WordPart): string | null => {
      if (p.k !== "param" || p.p.op !== "" || p.p.length) return null;
      if (p.p.special && p.p.name === "@") return "sh.positional";
      if (p.p.sub === "@") {
        return p.p.indices
          ? `sh.arrayIndices(${JSON.stringify(p.p.name)}).map(String)`
          : `sh.arrayValues(${JSON.stringify(p.p.name)})`;
      }
      return null;
    };
    if (pw.parts.length === 1) {
      const c = spreadCode(pw.parts[0]!);
      if (c !== null) return { spread: true, code: `...${c}` };
    }
    // Mixed with other text: `@`/`[@]` flows through as a scalar join (valStr),
    // matching how the interpreter and `echo` render it.

    const needsSplit = pw.parts.some((p) => p.k !== "lit" && !p.quoted);
    const litMeta = pw.parts.some((p) => p.k === "lit" && /[*?[]/.test(p.s));
    // An unquoted word may glob (any resulting metachar is active).
    const globbable = !pw.hasQuote && (needsSplit || litMeta);

    if (!needsSplit && !globbable) return { spread: false, code: this.templateOf(pw.parts) };
    const fieldsExpr = `sh.fields(${pw.parts.map((p) => this.fieldArg(p)).join(", ")})`;
    return { spread: true, code: globbable ? `...sh.glob(${fieldsExpr})` : `...${fieldsExpr}` };
  }

  /* ---------------- commands ---------------- */

  /** A boolean test of `subjectExpr` against a glob pattern word. Static
   *  patterns compile to an inline regex literal; dynamic ones fall back to
   *  the runtime matcher. */
  private matchExpr(subjectExpr: string, patText: string): string {
    const pw = parseWord(patText);
    if (pw.parts.every((p) => p.k === "lit")) {
      const lit = pw.parts.map((p) => (p.k === "lit" ? p.s : "")).join("");
      const src = globToRegExpSource(lit).replace(/\//g, "\\/");
      return `/${src}/s.test(${subjectExpr})`;
    }
    return `sh.match(${subjectExpr}, ${this.templateOf(pw.parts)})`;
  }

  private cond(e: CondExpr): string {
    switch (e.k) {
      case "and": return `(${this.cond(e.l)} && ${this.cond(e.r)})`;
      case "or": return `(${this.cond(e.l)} || ${this.cond(e.r)})`;
      case "not": return `(!${this.cond(e.e)})`;
      case "word": return `(${this.templateOf(parseWord(e.w.text).parts)} !== "")`;
      case "unary":
        return `sh.condUnary(${JSON.stringify(e.op)}, ${this.templateOf(parseWord(e.arg.text).parts)})`;
      case "binary": {
        const l = this.templateOf(parseWord(e.l.text).parts);
        if (e.op === "==" || e.op === "=") return this.matchExpr(l, e.r.text);
        if (e.op === "!=") return `(!${this.matchExpr(l, e.r.text)})`;
        const r = this.templateOf(parseWord(e.r.text).parts);
        return `sh.condBinary(${l}, ${JSON.stringify(e.op)}, ${r})`;
      }
    }
  }

  command(cmd: Command, ind: number): string {
    const reds = cmd.redirects;
    let core: string;
    if (reds !== undefined && reds.length > 0) {
      const i = pad(ind);
      const rd = reds
        .map((r) => {
          const parts =
            r.op === "<<" || r.op === "<<-"
              ? parseHeredoc(r.target.text, r.expand !== false).parts
              : parseWord(r.target.text).parts;
          return `{ op: ${JSON.stringify(r.op)}, fd: ${r.fd}, target: ${this.templateOf(parts)} }`;
        })
        .join(", ");
      core = `${i}await sh.withRedirects([${rd}], async () => {\n${this.base(cmd, ind + 1)}\n${i}});`;
    } else {
      core = this.base(cmd, ind);
    }
    if (cmd.flags !== undefined && (cmd.flags & CMD_INVERT_RETURN) !== 0) {
      const i = pad(ind);
      if (this.guards) {
        return `${i}{\n${pad(ind + 1)}using _ = sh.suppress();\n${bump(core)}\n${i}}\n${i}sh.invert();`;
      }
      return core + "\n" + `${i}sh.invert();`;
    }
    return core;
  }

  /** Emit a statement for an assignment word (name=, name+=, name[i]=, …). */
  private assignStmt(text: string, ind: number): string {
    const m = ASSIGN.exec(text)!;
    const name = m[1]!;
    const hasSub = m[2] !== undefined;
    const append = m[4] === "+";
    const rhs = this.templateOf(parseWord(m[5]!).parts);
    const i = pad(ind);
    const J = JSON.stringify;
    if (hasSub) {
      const sub = J(m[3] ?? "");
      if (append) {
        return `${i}await sh.elemSet(${J(name)}, ${sub}, ((await sh.elemGet(${J(name)}, ${sub})) ?? "") + ${rhs});`;
      }
      return `${i}await sh.elemSet(${J(name)}, ${sub}, ${rhs});`;
    }
    if (append) return `${i}sh.env.${name} = String(sh.env.${name}) + ${rhs};`;
    return `${i}sh.env.${name} = ${rhs};`;
  }

  private simpleCore(words: Word[], ind: number): string {
    const i = pad(ind);
    const assignWords: string[] = [];
    let k = 0;
    for (; k < words.length; k++) {
      if (ASSIGN.test(words[k]!.text)) assignWords.push(words[k]!.text);
      else break;
    }
    const rest = words.slice(k);

    if (rest.length === 0) {
      return assignWords.map((w) => this.assignStmt(w, ind)).join("\n");
    }

    const texts: string[] = [];
    for (const w of rest) for (const t of braceExpand(w.text)) texts.push(t);
    const nameText = texts[0]!;
    const argFrags = texts.slice(1).map((t) => this.word(t).code);
    const npw = parseWord(nameText);
    const literal =
      npw.parts.length === 1 && npw.parts[0]!.k === "lit" ? npw.parts[0]!.s : null;

    let callInner: string;
    if (literal !== null) {
      const target = ident(literal) ? `sh.commands.${literal}` : `sh.commands[${JSON.stringify(literal)}]`;
      callInner = `${target}(${argFrags.join(", ")})`;
    } else {
      const nameFrag = this.word(nameText).code;
      callInner = `sh.exec(${[nameFrag, ...argFrags].join(", ")})`;
    }

    if (assignWords.length === 0) return `${i}await ${callInner};`;
    // Prefix env from plain name=value assignments.
    const env = assignWords
      .map((w) => ASSIGN.exec(w)!)
      .filter((m) => m[2] === undefined && m[4] === undefined)
      .map((m) => `${JSON.stringify(m[1])}: ${this.templateOf(parseWord(m[5]!).parts)}`)
      .join(", ");
    return `${i}await sh.withEnv({ ${env} }, () => ${callInner});`;
  }

  private functionDef(cmd: FunctionDef, ind: number): string {
    const i = pad(ind);
    const target = ident(cmd.name) ? `sh.commands.${cmd.name}` : `sh.commands[${JSON.stringify(cmd.name)}]`;
    return (
      `${i}${target} = sh.func(async (sh) => {\n` +
      this.command(cmd.body, ind + 1) + "\n" +
      `${i}});`
    );
  }

  private base(cmd: Command, ind: number): string {
    const i = pad(ind);
    switch (cmd.type) {
      case "simple":
        return this.simpleCore(cmd.words, ind);
      case "function":
        return this.functionDef(cmd, ind);
      case "connection": {
        if (cmd.connector === ";") {
          return this.command(cmd.first, ind) + "\n" + this.command(cmd.second, ind);
        }
        if (cmd.connector === "&&" || cmd.connector === "||") {
          const test = cmd.connector === "&&" ? "=== 0" : "!== 0";
          return (
            this.suppressed(cmd.first, ind) + "\n" +
            `${i}if (sh.status ${test}) {\n` +
            this.command(cmd.second, ind + 1) + "\n" +
            `${i}}`
          );
        }
        throw new Error(`connector \`${cmd.connector}\` not supported yet`);
      }
      case "pipeline": {
        const stages = cmd.stages
          .map((c) => `async (sh) => {\n${this.command(c, ind + 2)}\n${pad(ind + 1)}}`)
          .join(",\n" + pad(ind + 1));
        return `${i}await sh.pipeline([\n${pad(ind + 1)}${stages},\n${i}]);`;
      }
      case "background":
        return (
          `${i}sh.background(async (sh) => {\n` +
          this.command(cmd.command, ind + 1) + "\n" +
          `${i}});`
        );
      case "group":
        return this.command(cmd.body, ind);
      case "subshell":
        return (
          `${i}await sh.runSubshell(async (sh) => {\n` +
          this.command(cmd.body, ind + 1) + "\n" +
          `${i}});`
        );
      case "if": {
        let out =
          this.suppressed(cmd.test, ind) + "\n" +
          `${i}if (sh.status === 0) {\n` +
          this.command(cmd.consequent, ind + 1) + "\n" +
          `${i}}`;
        if (cmd.alternate !== null) {
          out += ` else {\n` + this.command(cmd.alternate, ind + 1) + "\n" + `${i}}`;
        }
        return out;
      }
      case "while": {
        const brk = cmd.until ? "=== 0" : "!== 0";
        return (
          `${i}for (;;) {\n` +
          this.suppressed(cmd.test, ind + 1) + "\n" +
          `${pad(ind + 1)}if (sh.status ${brk}) break;\n` +
          this.command(cmd.body, ind + 1) + "\n" +
          `${i}}`
        );
      }
      case "for": {
        const v = `__it${this.forId++}`;
        const listFrags: string[] = [];
        for (const w of cmd.words) for (const t of braceExpand(w.text)) listFrags.push(this.word(t).code);
        const list = `[${listFrags.join(", ")}]`;
        const setName = ident(cmd.name) ? `sh.env.${cmd.name}` : `sh.env[${JSON.stringify(cmd.name)}]`;
        return (
          `${i}for (const ${v} of ${list}) {\n` +
          `${pad(ind + 1)}${setName} = ${v};\n` +
          this.command(cmd.body, ind + 1) + "\n" +
          `${i}}`
        );
      }
      case "arith_for":
        return (
          `${i}await sh.arithRun(${JSON.stringify(cmd.init)});\n` +
          `${i}for (;;) {\n` +
          `${pad(ind + 1)}if (!(await sh.arithTest(${JSON.stringify(cmd.test)}))) break;\n` +
          this.command(cmd.body, ind + 1) + "\n" +
          `${pad(ind + 1)}await sh.arithRun(${JSON.stringify(cmd.step)});\n` +
          `${i}}`
        );
      case "arith":
        return `${i}await sh.arithCommand(${JSON.stringify(cmd.expression)});`;
      case "cond":
        return `${i}sh.status = ${this.cond(cmd.expr)} ? 0 : 1;`;
      case "array_assign": {
        const frags: string[] = [];
        for (const w of cmd.elems) for (const t of braceExpand(w.text)) frags.push(this.word(t).code);
        const fn = cmd.append ? "appendArrayFields" : "setArrayFields";
        return `${i}sh.${fn}(${JSON.stringify(cmd.name)}, [${frags.join(", ")}]);`;
      }
      case "case": {
        const id = this.caseId++;
        const subj = this.templateOf(parseWord(cmd.word.text).parts);
        const j = pad(ind + 1);
        const head = `${j}const __case${id} = ${subj};\n${j}sh.status = 0;`;
        const condOf = (clause: (typeof cmd.clauses)[number]): string =>
          clause.patterns.map((p) => this.matchExpr(`__case${id}`, p.text)).join(" || ");
        const bodyOf = (clause: (typeof cmd.clauses)[number], d: number): string =>
          clause.body ? this.command(clause.body, d) : `${pad(d)}sh.status = 0;`;

        // Common case (all `;;`): a clean if / else-if chain.
        if (cmd.clauses.every((c) => c.term === "break")) {
          let chain = "";
          cmd.clauses.forEach((clause, ci) => {
            const block = `(${condOf(clause)}) {\n${bodyOf(clause, ind + 2)}\n${j}}`;
            chain += ci === 0 ? `${j}if ${block}` : ` else if ${block}`;
          });
          return `${i}{\n${chain === "" ? head : head + "\n" + chain}\n${i}}`;
        }

        // With `;&` / `;;&`: a labeled block with a fall-through flag.
        const k = pad(ind + 2);
        let out = `${i}{\n${head}\n${j}__case${id}: {\n${k}let __fall${id} = false;\n`;
        for (const clause of cmd.clauses) {
          out += `${k}if (__fall${id} || (${condOf(clause)})) {\n${bodyOf(clause, ind + 3)}\n`;
          if (clause.term === "break") out += `${pad(ind + 3)}break __case${id};\n`;
          else out += `${pad(ind + 3)}__fall${id} = ${clause.term === "fall"};\n`;
          out += `${k}}\n`;
        }
        return out + `${j}}\n${i}}`;
      }
      default: {
        const unhandled: never = cmd;
        throw new Error(`unhandled command type: ${String(unhandled)}`);
      }
    }
  }
}

export const emit = (cmd: Command | null, opts: EmitOptions): string => {
  const em = new Emitter();
  if (cmd !== null) em.guards = usesSet(cmd);
  const body = cmd === null ? "" : em.command(cmd, 1) + "\n";
  return (
    "// Generated by curse. Do not edit.\n" +
    `import { Shell, ExitSignal } from ${JSON.stringify(opts.runtimeSpecifier)};\n` +
    "\n" +
    "const sh = new Shell();\n" +
    "try {\n" +
    body +
    "  process.exitCode = sh.status;\n" +
    "} catch (e) {\n" +
    "  if (e instanceof ExitSignal) process.exitCode = e.code;\n" +
    "  else throw e;\n" +
    "}\n"
  );
};
