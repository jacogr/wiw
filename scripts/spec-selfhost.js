import assert from 'node:assert/strict';
import {readFile, rename, writeFile} from 'node:fs/promises';
import {runSuite} from './spec-runner.js';

// Every script instance, including spectest and isolated negative assertions,
// runs in its own WAT interpreter copy. Persist progress without accepting gaps.
const coverage = JSON.parse(await readFile(new URL('../test/spec/capabilities.json', import.meta.url), 'utf8'));
// Readers always see a complete JSON snapshot, including during a running audit.
async function saveReport(output, report) {
  const temporary = new URL(output.href + '.tmp');
  await writeFile(temporary, JSON.stringify(report, null, 2) + '\n');
  await rename(temporary, output);
}

let incomplete = false;
let engineSourceSha256;
for (const binary of ['wiw.wasm', 'wiw-opt.wasm']) {
  const output = new URL(`../build/spec-selfhost-${binary}.json`, import.meta.url);
  const report = await runSuite(new URL(`../build/${binary}`, import.meta.url), undefined, {
    audit: true,
    interpreted: true,
    profile: true,
    async onFile(counts, partial) {
      const timing = partial.timings.at(-1);
      console.log(`${binary}/${counts.file}: ${counts.passed} passed, ${counts.skipped} skipped, ${counts.failed} failed (${(timing.elapsedMs / 1000).toFixed(2)}s)`);
      await saveReport(output, {...partial, complete: false});
    }
  });
  await saveReport(output, {...report, complete: true});
  console.log(`${report.tag}/${binary}/interpreted: ${report.passed} passed, ${report.skipped} skipped, ${report.failed} failed across ${report.files.length} files in ${(report.elapsedMs / 1000).toFixed(1)}s`);
  incomplete ||= report.failed !== 0 || report.skipped !== 0;
  engineSourceSha256 ??= report.engineSourceSha256;
  assert.equal(report.engineSourceSha256, engineSourceSha256, 'interpreted engine source changed between bootstrap audits');
  assert.deepEqual(report.files.map(({file, passed, skipped, failed}) => ({file, commands: passed + skipped + failed})),
    coverage.expectedCoverage.map(({file, passed}) => ({file, commands: passed})),
    'self-hosted audit did not execute the complete frozen command inventory');
  if (!report.failed && !report.skipped) {
    assert.deepEqual(report.files.map(({failed, ...file}) => file), coverage.expectedCoverage,
      'self-hosted coverage differs from the frozen full-suite counts');
  }
}
if (incomplete) process.exitCode = 1;
