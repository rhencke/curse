/* M0 conformance: run each case in test/cases/ through both curse paths — the
 * interpreter (`curse run`) and the AOT output (`curse transpile` → node) — and
 * compare stdout + exit status against real bash (the same 5.2.37 that ships in
 * the dev image, so it is a faithful oracle).
 *
 * stderr is intentionally not compared yet: error-message wording (e.g. the
 * "command not found" prefix) is a later-milestone concern. */

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

const cases = readdirSync(casesDir).filter((f) => f.endsWith(".sh")).sort();
const outDir = mkdtempSync(join(tmpdir(), "curse-aot-"));

const bash = (file: string) => spawnSync("bash", [file], { encoding: "utf8" });

for (const name of cases) {
  const file = join(casesDir, name);

  test(`interp: ${name}`, () => {
    const want = bash(file);
    const got = spawnSync(node, [cli, "run", file], { encoding: "utf8" });
    assert.equal(got.stdout, want.stdout, "stdout mismatch");
    assert.equal(got.status, want.status, "exit status mismatch");
  });

  test(`aot:    ${name}`, () => {
    const want = bash(file);
    const t = spawnSync(node, [cli, "transpile", file], { encoding: "utf8" });
    assert.equal(t.status, 0, `transpile failed:\n${t.stderr}`);
    const outFile = join(outDir, name + ".mts");
    writeFileSync(outFile, t.stdout);
    const got = spawnSync(node, [outFile], { encoding: "utf8" });
    assert.equal(got.stdout, want.stdout, "stdout mismatch");
    assert.equal(got.status, want.status, "exit status mismatch");
  });
}
