import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile } from 'node:fs/promises';
import { runSuite } from '../scripts/spec-runner.js';
for (const binary of ['wiw-opt.wasm']) {
  test(`${binary}: verified WebAssembly 2.0 core files (zero skips)`, async t => {
    const manifest = JSON.parse(await readFile(new URL('./spec/capabilities.json', import.meta.url), 'utf8'));
    const report = await runSuite(new URL(`../build/${binary}`, import.meta.url), undefined, {files: manifest.verifiedFiles});
    await writeFile(new URL(`../build/spec-${binary}.json`, import.meta.url), JSON.stringify(report, null, 2) + '\n');
    t.diagnostic(`official WAST (${report.tag}): ${report.passed} passed, ${report.skipped} skipped; detailed reasons in build/spec-${binary}.json`);
    assert.equal(report.passed, manifest.expectedCoverage.reduce((sum, file) => sum + file.passed, 0));
    assert.equal(report.skipped, 0);
    assert.equal(report.failed, 0);
    assert.equal(report.files.length, manifest.verifiedFiles.length);
    assert.deepEqual(report.files, manifest.expectedCoverage, 'official coverage and skip reasons changed; review the manifest');
  });
}
