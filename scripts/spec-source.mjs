import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// Resolve the fixture source and verify the documented pin before reading upstream files.
// Synthetic harness fixtures omit checkout and remain ordinary local files.
export async function specSource(provenance, root) {
  if (!provenance.checkout) return root;
  const checkout = new URL(provenance.checkout, root);
  let revision;
  try {
    await stat(new URL('.git', checkout));
    revision = execFileSync('git', ['-C', fileURLToPath(checkout), 'rev-parse', 'HEAD'], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
  } catch (error) {
    throw new Error('spec submodule is not initialized; run git submodule update --init test/spec/upstream', {cause: error});
  }
  assert.equal(revision, provenance.revision, 'spec submodule revision mismatch; restore the recorded submodule or update its documented pin');
  return checkout;
}
