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
import { parseWord } from "../parser/word.mts";
import type { Param, WordPart } from "../parser/word.mts";
import { braceExpand } from "../parser/brace.mts";
import { globToRegExpSource } from "../runtime/glob.mts";

export interface EmitOptions {
  /** Import specifier (path or file: URL) for the runtime's `Shell`. */
  runtimeSpecifier: string;
}

const pad = (n: number): string => "  ".repeat(n);
const ident = (s: string): boolean => /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);
const escTemplate = (s: string): string =>
  s.replace(/\\/g, "\\\\").replace(/`/g, "\\`").replace(/\$/g, "\\$");

interface WordCode {
  /** true => a `...spread` producing zero+ args; false => a single arg. */
  spread: boolean;
  code: string;
}

class Emitter {
  private forId = 0;
  private caseId = 0;

  /* ---------------- words ---------------- */

  private specialExpr(name: string): string {
    switch (name) {
      case "?": return "String(sh.status)";
      case "#": return "String(sh.positional.length)";
      case "$": return "String(sh.pid)";
      case "0": return "sh.name";
      case "@": case "*": return 'sh.positional.join(" ")';
      default: return `sh.param(${Number(name)})`;
    }
  }

  private paramExpr(prm: Param): string {
    const base = prm.special ? this.specialExpr(prm.name) : `sh.env.${prm.name}`;
    const J = JSON.stringify;
    const arg = (): string => this.templateOf(parseWord(prm.arg).parts);
    const arg2 = (): string => this.templateOf(parseWord(prm.arg2).parts);
    if (prm.length) {
      if (prm.name === "@" || prm.name === "*" || prm.name === "#") return "String(sh.positional.length)";
      return `String(${base}).length`;
    }
    switch (prm.op) {
      case "": return base;
      case ":-": return `(String(${base}) || ${arg()})`;
      case "-": return `(sh.has(${J(prm.name)}) ? ${base} : ${arg()})`;
      case ":+": return `(String(${base}) ? ${arg()} : "")`;
      case "+": return `(sh.has(${J(prm.name)}) ? ${arg()} : "")`;
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

    // "$@" / $@ expands to each positional parameter as a separate field.
    // ($* is a scalar join and flows through the generic paths below.)
    const isAt = (p: WordPart): boolean =>
      p.k === "param" && p.p.special && p.p.name === "@" && p.p.op === "" && !p.p.length;
    if (pw.parts.length === 1 && isAt(pw.parts[0]!)) {
      return { spread: true, code: "...sh.positional" };
    }
    if (pw.parts.some(isAt)) {
      throw new Error('`$@` mixed with other text is not supported yet');
    }

    const needsFields = pw.parts.some((p) => p.k !== "lit" && !p.quoted);
    if (!needsFields) return { spread: false, code: this.templateOf(pw.parts) };
    return { spread: true, code: `...sh.fields(${pw.parts.map((p) => this.fieldArg(p)).join(", ")})` };
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
        .map((r) => `{ op: ${JSON.stringify(r.op)}, fd: ${r.fd}, target: ${this.templateOf(parseWord(r.target.text).parts)} }`)
        .join(", ");
      core = `${i}await sh.withRedirects([${rd}], async () => {\n${this.base(cmd, ind + 1)}\n${i}});`;
    } else {
      core = this.base(cmd, ind);
    }
    if (cmd.flags !== undefined && (cmd.flags & CMD_INVERT_RETURN) !== 0) {
      return core + "\n" + `${pad(ind)}sh.invert();`;
    }
    return core;
  }

  private assignRHS(rhsText: string): string {
    return this.templateOf(parseWord(rhsText).parts);
  }

  private simpleCore(words: Word[], ind: number): string {
    const i = pad(ind);
    const assigns: Array<[string, string]> = [];
    let k = 0;
    for (; k < words.length; k++) {
      const m = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(words[k]!.text);
      if (!m) break;
      assigns.push([m[1]!, this.assignRHS(words[k]!.text.slice(m[0].length))]);
    }
    const rest = words.slice(k);

    if (rest.length === 0) {
      return assigns.map(([n, e]) => `${i}sh.env.${n} = ${e};`).join("\n");
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

    if (assigns.length === 0) return `${i}await ${callInner};`;
    const obj = "{ " + assigns.map(([n, e]) => `${JSON.stringify(n)}: ${e}`).join(", ") + " }";
    return `${i}await sh.withEnv(${obj}, () => ${callInner});`;
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
            this.command(cmd.first, ind) + "\n" +
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
          this.command(cmd.test, ind) + "\n" +
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
          this.command(cmd.test, ind + 1) + "\n" +
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
      case "case": {
        const id = this.caseId++;
        const subj = this.templateOf(parseWord(cmd.word.text).parts);
        let chain = "";
        cmd.clauses.forEach((clause, ci) => {
          const cond = clause.patterns
            .map((p) => this.matchExpr(`__case${id}`, p.text))
            .join(" || ");
          const body = clause.body
            ? this.command(clause.body, ind + 2)
            : `${pad(ind + 2)}sh.status = 0;`;
          const block = `(${cond}) {\n${body}\n${pad(ind + 1)}}`;
          chain += ci === 0 ? `${pad(ind + 1)}if ${block}` : ` else if ${block}`;
        });
        const head = `${pad(ind + 1)}const __case${id} = ${subj};\n${pad(ind + 1)}sh.status = 0;`;
        const inner = chain === "" ? head : head + "\n" + chain;
        return `${i}{\n${inner}\n${i}}`;
      }
      default: {
        const unhandled: never = cmd;
        throw new Error(`unhandled command type: ${String(unhandled)}`);
      }
    }
  }
}

export const emit = (cmd: Command | null, opts: EmitOptions): string => {
  const body = cmd === null ? "" : new Emitter().command(cmd, 0) + "\n";
  return (
    "// Generated by curse. Do not edit.\n" +
    `import { Shell } from ${JSON.stringify(opts.runtimeSpecifier)};\n` +
    "\n" +
    "const sh = new Shell();\n" +
    body +
    "process.exitCode = sh.status;\n"
  );
};
