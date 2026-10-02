// Unit tests for e2e/lib/registry.ts's reEndpointOr / peEndpointOr.
//
// The literal fallback (the Docker stack's https://localhost:5001 / :3004) is
// the answer only when no instance registry can be read. With several
// instances registered and none named, the resolver used to return the
// literal, so the single-RE specs probed a port nothing listens on in a native
// universe and failed with ECONNREFUSED. It now refuses and names the fix.
//
// Usage: node scripts/tests/test-e2e-registry.mjs   (Node 26: imports .ts directly)
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const { reEndpointOr, peEndpointOr, AmbiguousInstanceError } = await import('../../e2e/lib/registry.ts');

const dir = mkdtempSync(join(tmpdir(), 'reg-'));
const reg = (instances) => {
  const p = join(dir, `r${Math.random()}.json`);
  writeFileSync(p, JSON.stringify({ instances }));
  return p;
};
const inst = (id, port) => ({ id, runtime: id.split('-')[0], re_url: `http://h:${port + 1}`, pe_url: `http://h:${port}` });
let failed = 0;
const check = (name, fn) => { try { fn(); console.log(`ok   ${name}`); } catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`); } };

delete process.env.RE_E2E_INSTANCE;
const LIT = 'https://localhost:5001';
check('no registry file: the literal stands', () => assert.equal(reEndpointOr(LIT, join(dir, 'absent.json')), LIT));
check('empty registry: the literal stands', () => assert.equal(reEndpointOr(LIT, reg([])), LIT));
const one = reg([inst('scala-1', 5100)]);
check('one instance: resolved, no name needed', () => assert.equal(reEndpointOr(LIT, one), 'http://h:5101'));
check('one instance: PE resolved too', () => assert.equal(peEndpointOr('https://localhost:3004', one), 'http://h:5100'));
const many = reg([inst('cpp-1', 5300), inst('lsp-1', 5600), inst('scala-1', 5100)]);
check('several, none named: refuses instead of the Docker literal', () =>
  assert.throws(() => reEndpointOr(LIT, many), (e) => e instanceof AmbiguousInstanceError && /RE_E2E_INSTANCE/.test(e.message)));
check('several, none named: PE refuses too', () => assert.throws(() => peEndpointOr('https://localhost:3004', many), AmbiguousInstanceError));
process.env.RE_E2E_INSTANCE = 'lsp-1';
check('several, named: the named instance', () => assert.equal(reEndpointOr(LIT, many), 'http://h:5601'));
process.env.RE_E2E_INSTANCE = 'nope-9';
check('named instance missing: an error naming it', () => assert.throws(() => reEndpointOr(LIT, many), /no instance 'nope-9'/));
delete process.env.RE_E2E_INSTANCE;

rmSync(dir, { recursive: true, force: true });
console.log(failed === 0 ? 'all passed' : `${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
