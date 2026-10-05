import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { CredentialVault } from '../src/credentials.mjs';
import { encryptedTestStorage, config, session } from './fixtures.mjs';
async function fixture(t, extra = {}) { const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'k-comms-desktop-vault-')); t.after(() => fs.rm(directory, { recursive: true, force: true })); const vault = new CredentialVault({ directory, platform: process.platform, storage: encryptedTestStorage(), origin: config.serviceOrigin, ...extra }); await vault.load(); return vault; }

test('OS encrypted persistence restores only the same origin and no token plaintext', async t => {
  const vault = await fixture(t); await vault.replace({ generation: 1, kind: 'member', value: session });
  const bytes = await fs.readFile(vault.filename); assert(!bytes.toString().includes(session.access_token)); assert(!bytes.toString().includes(session.refresh_token));
  const restored = new CredentialVault({ storage: vault.storage, platform: process.platform, directory: vault.directory, origin: config.serviceOrigin });
  assert.equal((await restored.load()).value.user.id, session.user.id);
  const foreign = new CredentialVault({ storage: vault.storage, platform: process.platform, directory: vault.directory, origin: 'https://foreign.example.org' });
  assert.equal((await foreign.load()).kind, null); await assert.rejects(fs.readFile(vault.filename), { code: 'ENOENT' });
});
test('logout invalidates a blocked older filesystem write and rejects stale revival', async t => {
  let started; let release; const waiting = new Promise(resolve => { release = resolve; }); const began = new Promise(resolve => { started = resolve; });
  let block = true;
  const vault = await fixture(t, { filesystem: { ...fs, writeFile: async (...args) => { if (block) { block = false; started(); await waiting; } return fs.writeFile(...args); } } });
  const earlier = vault.replace({ generation: 1, kind: 'member', value: session }); await began;
  const logout = vault.replace({ generation: 2, kind: null, value: null });
  assert.equal(vault.snapshot().kind, null);
  assert.throws(() => vault.replace({ generation: 1, kind: 'member', value: session }), /Stale/);
  release(); await Promise.all([earlier, logout]); await assert.rejects(fs.readFile(vault.filename), { code: 'ENOENT' });
  assert.deepEqual(await fs.readdir(vault.directory), []);
});
test('identity switching remains exclusive and revokes prior media consent', async t => {
  let revoked = 0; const vault = await fixture(t, { onIdentityChanged: () => { revoked += 1; } });
  await vault.replace({ generation: 1, kind: 'member', value: session });
  await vault.replace({ generation: 2, kind: 'member', value: { ...session, access_token: 'refreshed' } });
  assert.equal(revoked, 1);
  const next = { ...session, user: { ...session.user, id: '20000000-0000-4000-8000-000000000002' }, device: { ...session.device, user_id: '20000000-0000-4000-8000-000000000002' } };
  await vault.replace({ generation: 3, kind: 'member', value: next }); assert.equal(revoked, 2); assert.equal(vault.snapshot().value.user.id, next.user.id);
});
test('a different guest room revokes native media consent even for the same user and device', async t => {
  let revoked = 0; const vault = await fixture(t, { onIdentityChanged: () => { revoked += 1; } });
  const guest = { ...session, user: { ...session.user, account_type: 'guest' }, conversation: { id: '40000000-0000-4000-8000-000000000001' }, capabilities: {} };
  await vault.replace({ generation: 1, kind: 'guest', value: guest });
  await vault.replace({ generation: 2, kind: 'guest', value: { ...guest, conversation: { id: '40000000-0000-4000-8000-000000000002' } } });
  assert.equal(revoked, 2); assert.equal(vault.snapshot().value.conversation.id, '40000000-0000-4000-8000-000000000002');
});
test('storage loss forbids writes but logout still deletes previously encrypted credentials', async t => {
  const vault = await fixture(t); await vault.replace({ generation: 1, kind: 'member', value: session });
  vault.storage.isEncryptionAvailable = () => false;
  assert.throws(() => vault.replace({ generation: 2, kind: 'member', value: session }), /OS credential/);
  await vault.replace({ generation: 2, kind: null, value: null }); await assert.rejects(fs.readFile(vault.filename), { code: 'ENOENT' });
});
test('malformed encrypted state and unsafe file permissions are cleared rather than restored', async t => {
  const vault = await fixture(t); await fs.writeFile(vault.filename, vault.storage.encryptString('{"version":1,"origin":"https://comms.example.org","kind":"member","value":{}}'), { mode: 0o600 });
  assert.equal((await vault.load()).kind, null); await assert.rejects(fs.readFile(vault.filename), { code: 'ENOENT' });
  if (process.platform !== 'win32') { await fs.writeFile(vault.filename, vault.storage.encryptString(JSON.stringify({ version: 1, origin: config.serviceOrigin, kind: 'member', value: session })), { mode: 0o644 }); await fs.chmod(vault.filename, 0o644); assert.equal((await vault.load()).kind, null); }
});
