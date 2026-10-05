import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { validateConfig } from '../src/policy.mjs';

test('committed package policy stays unsigned, disconnected and without update authority', async () => {
  const policy = validateConfig(JSON.parse(await readFile(new URL('../desktop.config.json', import.meta.url), 'utf8')));
  assert.equal(policy.serviceOrigin, null); assert.equal(policy.qualificationOnly, true); assert.equal(policy.unsigned, true); assert.equal(policy.updates, 'disabled');
  const builder = JSON.parse(await readFile(new URL('../electron-builder.json', import.meta.url), 'utf8'));
  assert.equal(builder.asar, true); assert.equal(builder.publish, null); assert.equal(builder.forceCodeSigning, false); assert.equal(builder.mac.identity, null); assert.equal(builder.win.signAndEditExecutable, false);
  assert.equal(builder.nsis.perMachine, false); assert.equal(builder.nsis.allowElevation, false);
  assert.deepEqual(builder.files, ['src/**', 'web-dist/**', 'desktop.config.json', 'package.json']);
  assert.deepEqual(builder.win.target, [{ target: 'nsis', arch: ['x64'] }]);
  assert.deepEqual(builder.mac.target, [{ target: 'dmg', arch: ['x64', 'arm64'] }]);
  assert.deepEqual(builder.linux.target, [{ target: 'AppImage', arch: ['x64'] }, { target: 'deb', arch: ['x64'] }]);
  const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const lock = JSON.parse(await readFile(new URL('../package-lock.json', import.meta.url), 'utf8'));
  for (const [name, version] of Object.entries(pkg.devDependencies)) {
    assert.match(version, /^\d+\.\d+\.\d+$/);
    assert.equal(lock.packages['node_modules/' + name].version, version);
    assert.match(lock.packages['node_modules/' + name].integrity, /^sha512-/);
  }
  assert.equal(Object.hasOwn(pkg.devDependencies, 'electron-updater'), false);
});
test('actual unsigned packaging command refuses every supplied signing credential before spawning a builder', () => {
  const names = ['CSC_LINK', 'CSC_KEY_PASSWORD', 'CSC_NAME', 'WIN_CSC_LINK', 'WIN_CSC_KEY_PASSWORD', 'APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID'];
  const clean = Object.fromEntries(Object.entries(process.env).filter(([key]) => !names.includes(key)));
  for (const name of names) {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('../scripts/package-unsigned.mjs', import.meta.url))], { env: { ...clean, [name]: 'synthetic-nonsecret-fixture' }, encoding: 'utf8', timeout: 2000 });
    assert.equal(result.status, 1); assert.match(result.stderr, /refuses signing credentials/); assert.doesNotMatch(result.stderr, /Cannot find module|electron-builder.*cli/);
  }
});
