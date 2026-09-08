/* Oils spec-test conformance runner (progress tracking, NOT part of `npm test`).
 *
 * Parses Oils' spec/*.test.sh cases (Apache-2.0; see NOTICE.md) and runs each
 * snippet through real bash and through curse, comparing stdout + exit status —
 * bash is the oracle, so the spec's per-shell annotations are ignored. Most
 * cases fail until the matching feature lands; the pass-rate is the scoreboard.
 *
 * Usage:  node test/spec/run.mts [--aot] [--verbose] [file-substr ...]
 * Spec files come from reference/oil/spec (run test/spec/fetch.sh first).
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve, basename } from "node:path";
import { tmpdir } from "node:os";

const repoRoot = resolve(import.meta.dirname, "../..");
const specDir = join(repoRoot, "reference/oil/spec");
const cli = join(repoRoot, "src/cli/curse.mts");
const node = process.execPath;

const args = process.argv.slice(2);
const useAot = args.includes("--aot");
const verbose = args.includes("--verbose");
const filters = args.filter((a) => !a.startsWith("--"));

interface Case {
  name: string;
  code: string;
}

const parseCases = (text: string): Case[] => {
  const cases: Case[] = [];
  let cur: { name: string; code: string[] } | null = null;
  let inMeta = false; // once a `##` metadata line is seen, the rest of the case
  for (const line of text.split("\n")) {
    const m = /^#### (.*)/.exec(line);
    if (m) {
      if (cur) cases.push({ name: cur.name, code: cur.code.join("\n") });
      cur = { name: m[1]!, code: [] };
      inMeta = false;
      continue;
    }
    if (cur === null) continue;
    // The Oil format puts all metadata (## STDOUT:, ## status:, expected output,
    // ## END, …) after the code. A `##` line begins that block; everything from
    // there to the next case is annotation, NOT code (so expected-output lines,
    // which don't start with `##`, are never mistaken for code to run).
    if (line === "##" || line.startsWith("## ")) { inMeta = true; continue; }
    if (inMeta) continue;
    cur.code.push(line);
  }
  if (cur) cases.push({ name: cur.name, code: cur.code.join("\n") });
  return cases.filter((c) => c.code.trim() !== "");
};

const TIMEOUT = 5000;

const runCase = (code: string, cwd: string): { ok: boolean } => {
  const bash = spawnSync("bash", ["-c", code], { encoding: "utf8", timeout: TIMEOUT, cwd });
  let got: { stdout: string | null; status: number | null };
  if (useAot) {
    const t = spawnSync(node, [cli, "transpile", "-"], { input: code, encoding: "utf8", timeout: TIMEOUT, cwd });
    if (t.status !== 0) return { ok: false };
    got = spawnSync(node, ["--input-type=module", "-"], { input: t.stdout, encoding: "utf8", timeout: TIMEOUT, cwd });
  } else {
    got = spawnSync(node, [cli, "-c", code], { encoding: "utf8", timeout: TIMEOUT, cwd });
  }
  return { ok: got.stdout === bash.stdout && got.status === bash.status };
};

let files = readdirSync(specDir).filter((f) => f.endsWith(".test.sh")).sort();
if (filters.length > 0) files = files.filter((f) => filters.some((s) => f.includes(s)));

let totalPass = 0;
let total = 0;
const perFile: Array<{ file: string; pass: number; n: number }> = [];

for (const file of files) {
  const cases = parseCases(readFileSync(join(specDir, file), "utf8"));
  const cwd = mkdtempSync(join(tmpdir(), "curse-spec-"));
  let pass = 0;
  for (const c of cases) {
    const { ok } = runCase(c.code, cwd);
    if (ok) pass++;
    else if (verbose) process.stdout.write(`  FAIL ${basename(file)}: ${c.name}\n`);
    total++;
  }
  totalPass += pass;
  perFile.push({ file, pass, n: cases.length });
}

perFile.sort((a, b) => b.n - a.n);
process.stdout.write("\nper-file (pass/total):\n");
for (const f of perFile) {
  const pct = f.n === 0 ? 0 : Math.round((f.pass / f.n) * 100);
  process.stdout.write(`  ${String(f.pass).padStart(3)}/${String(f.n).padStart(3)}  ${String(pct).padStart(3)}%  ${f.file}\n`);
}
const pctAll = total === 0 ? 0 : ((totalPass / total) * 100).toFixed(1);
process.stdout.write(`\nspec conformance (${useAot ? "AOT" : "interp"} vs bash): ${totalPass}/${total} cases (${pctAll}%) across ${files.length} files\n`);
