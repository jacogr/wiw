import { writeFile } from 'node:fs/promises';
import { runSuite } from './spec-runner.js';

// Audit the entire pin, independently of the verified subset used for CI regressions.
let incomplete = false;

// Audit the selected optimized interpreter while retaining supported failures for the final report.
for (const binary of ['wiw-opt.wasm']) {
  const report = await runSuite(new URL(`../build/${binary}`, import.meta.url), undefined, {
    audit: true,
    interpreted: false,
    profile: true
  });
  const output = new URL(`../build/spec-audit-${binary}.json`, import.meta.url);

  await writeFile(output, JSON.stringify(report, null, 2) + '\n');
  console.log(
    `${report.tag}/${binary}: ${report.passed} passed, ${report.skipped} skipped, ${report.failed} failed across ${report.files.length} files`
  );
  console.log(`Full report: ${output.pathname}`);

  // Print phase timings to make audit construction, loading and execution costs visible.
  for (const [name, phase] of Object.entries(report.phases)) {
    console.log(
      `  ${name}: ${(phase.elapsedMs / 1000).toFixed(2)}s${phase.count === undefined ? '' : ` (${phase.count} calls)`}`
    );
  }

  incomplete ||= report.failed !== 0 || report.skipped !== 0;
}

// The diagnostic report is useful while incomplete; it never treats the gaps as success.
if (incomplete) process.exitCode = 1;
