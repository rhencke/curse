/* Conformance: run each case in test/cases/ through both curse paths — the
 * interpreter (`curse run`) and the AOT output (`curse transpile` → node) — and
 * compare stdout + exit status against real bash (the same 5.2.37 in the dev
 * image, so a faithful oracle).
 *
 * stderr is intentionally not compared: error-message wording (e.g. the
 * "command not found" prefix) is a later-milestone concern.
 *
 * Set ONLY=<substr> to run a subset (quick smoke test). */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const repoRoot = resolve(import.meta.dirname, "../..");
const cli = join(repoRoot, "src/cli/curse.mts");
const casesDir = join(repoRoot, "test/cases");
const node = process.execPath;

const only = process.env.ONLY;
const cases = readdirSync(casesDir)
  .filter((f) => f.endsWith(".sh") && (only === undefined || f.includes(only)))
  .sort();
const outDir = mkdtempSync(join(tmpdir(), "curse-aot-"));

const bash = (file: string) => spawnSync("bash", [file], { encoding: "utf8", timeout: 15000 });

for (const name of cases) {
  const file = join(casesDir, name);

  test(`interp: ${name}`, () => {
    const want = bash(file);
    const got = spawnSync(node, [cli, "run", file], { encoding: "utf8", timeout: 15000 });
    assert.equal(got.stdout, want.stdout, "stdout mismatch");
    assert.equal(got.status, want.status, "exit status mismatch");
  });

  test(`aot:    ${name}`, () => {
    const want = bash(file);
    const t = spawnSync(node, [cli, "transpile", file], { encoding: "utf8", timeout: 15000 });
    assert.equal(t.status, 0, `transpile failed:\n${t.stderr}`);
    const outFile = join(outDir, name + ".mts");
    writeFileSync(outFile, t.stdout);
    const got = spawnSync(node, [outFile], { encoding: "utf8", timeout: 15000 });
    assert.equal(got.stdout, want.stdout, "stdout mismatch");
    assert.equal(got.status, want.status, "exit status mismatch");
  });
}
