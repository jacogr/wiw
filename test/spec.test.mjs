import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile } from 'node:fs/promises';
import { runSuite } from '../scripts/spec-runner.mjs';
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  test(`${binary}: entire pinned WebAssembly 1.0 core suite`, async t => {
    const report = await runSuite(new URL(`../build/${binary}`, import.meta.url));
    await writeFile(new URL(`../build/spec-${binary}.json`, import.meta.url), JSON.stringify(report, null, 2) + '\n');
    t.diagnostic(`official WAST (${report.tag}): ${report.passed} passed, ${report.skipped} skipped; detailed reasons in build/spec-${binary}.json`);
    assert.equal(report.passed, 19270);
    assert.equal(report.skipped, 0);
    assert.equal(report.failed, 0);
    assert.equal(report.files.length, 73);
    const manifest = JSON.parse(await readFile(new URL('./spec/capabilities.json', import.meta.url), 'utf8'));
    assert.deepEqual(report.files, manifest.expectedCoverage, 'official coverage and skip reasons changed; review the manifest');
  });
}
