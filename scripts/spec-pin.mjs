import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// Refresh pin metadata from an already checked-out tag; coverage changes still require review.
const tag = process.argv[2];
if (!tag || !/^[a-zA-Z0-9][a-zA-Z0-9._/-]*$/.test(tag)) throw new Error('Usage: node scripts/spec-pin.mjs <checked-out-tag>');
const manifest = new URL('../test/spec/upstream.json', import.meta.url);
const provenance = JSON.parse(await readFile(manifest, 'utf8'));
const checkout = new URL(provenance.checkout, manifest);
const git = (...args) => execFileSync('git', ['-C', fileURLToPath(checkout), ...args], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
const revision = git('rev-parse', '--verify', `refs/tags/${tag}^{commit}`);
assert.equal(git('rev-parse', 'HEAD'), revision, 'check out the selected tag in the spec submodule first');
assert.equal(git('status', '--porcelain', '--untracked-files=no'), '', 'spec checkout must be clean before updating its pin');
const hash = async path => createHash('sha256').update(await readFile(new URL(path, checkout))).digest('hex');
const files = [];
for (const entry of provenance.files) files.push({...entry, sha256: await hash(entry.path)});
const license = {...provenance.license, sha256: await hash(provenance.license.path)};
await writeFile(manifest, JSON.stringify({...provenance, tag, revision, baseline: `WebAssembly specification (${tag})`, files, license}, null, 2) + '\n');
console.log(`Pinned ${tag} at ${revision}; run make check-spec and review coverage changes.`);
