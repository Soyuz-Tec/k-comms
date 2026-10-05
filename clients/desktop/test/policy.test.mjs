import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { join } from 'node:path';
import { readFile } from 'node:fs/promises';
import { config, session } from './fixtures.mjs';
import { validateConfig, httpsOrigin, ownedUiUrl, allowedNetworkUrl, localAssetPath, validateReplacement, secureStorageAvailable, trustedSender, csp, secureWebPreferences } from '../src/policy.mjs';

test('fixed origin policy rejects credentials, wildcard, insecure, ports and unknown update authority', () => {
  for (const origin of ['http://comms.example.org', 'https://user:secret@comms.example.org', 'https://comms.example.org/', 'https://comms.example.org?x=1', 'https://comms.example.org:444', 'https://127.0.0.1', 'https://localhost', 'https://*.example.org', 'https://comms..example.org']) assert.throws(() => httpsOrigin(origin));
  assert.deepEqual(validateConfig(config), config);
  for (const change of [{ updates: 'enabled' }, { unsigned: false }, { arbitraryCommand: true }, { mediaOrigins: ['wss://media.example.org', 'wss://media.example.org'] }]) assert.throws(() => validateConfig({ ...config, ...change }));
});
test('app origin spoofing, foreign documents and traversal cannot become privileged content', () => {
  assert(ownedUiUrl(config.serviceOrigin + '/app/chat', config));
  for (const url of ['https://comms.example.org.evil.test/app/', 'https://comms.example.org/api/v1/users', 'file:///app/', 'javascript:alert(1)', 'https://evil.example.org/app/', config.serviceOrigin + '/app/assets/active.svg', config.serviceOrigin + '/app/assets/active%2esvg']) assert.equal(ownedUiUrl(url, config), false);
  assert(allowedNetworkUrl('wss://comms.example.org/socket/websocket?socket_ticket=one-use', config));
  assert(allowedNetworkUrl('wss://media.example.org/rtc', config));
  assert.equal(allowedNetworkUrl('https://media.example.org/', config), false);
  assert.equal(allowedNetworkUrl('https://evil.example.org/', config), false);
  assert.throws(() => localAssetPath(config.serviceOrigin + '/app/assets/%2e%2e%2fsecret', config, '/bundle'));
  assert.throws(() => localAssetPath(config.serviceOrigin + '/app/assets/main.map', config, '/bundle'));
  assert.equal(localAssetPath(config.serviceOrigin + '/api/v1/users', config, '/bundle'), null);
  assert.equal(localAssetPath(config.serviceOrigin + '/app/chat', config, '/bundle'), join('/bundle', 'index.html'));
});
test('only the current owning main frame can call the credential boundary', () => {
  const frame = { url: config.serviceOrigin + '/app/' }; const contents = { mainFrame: frame };
  const window = { isDestroyed: () => false, webContents: contents };
  assert(trustedSender({ sender: contents, senderFrame: frame }, window, config));
  for (const event of [{ sender: {}, senderFrame: frame }, { sender: contents, senderFrame: { url: frame.url } }]) assert.equal(trustedSender(event, window, config), false);
  frame.url = 'https://evil.example.org/app/'; assert.equal(trustedSender({ sender: contents, senderFrame: frame }, window, config), false);
});
test('credentials reject arbitrary commands, bounded data and cross-identity or guest confusion', () => {
  assert.equal(validateReplacement({ generation: 1, kind: 'member', value: session }).value.user.id, session.user.id);
  for (const command of [{ generation: 1, kind: 'member', value: { ...session, filename: '/etc/passwd' } }, { generation: 1, kind: 'member', value: { ...session, device: { ...session.device, user_id: session.tenant.id } } }, { generation: 1, kind: 'guest', value: session }, { generation: 0, kind: null, value: null }, { generation: 1, kind: null, value: session }, { generation: 1, kind: 'member', value: { ...session, access_token: 'x'.repeat(8193) } }, { generation: 1, kind: 'member', value: { ...session, user: { ...session.user, account_type: 'service' } } }]) assert.throws(() => validateReplacement(command));
});
test('Linux plaintext and unknown backends never satisfy encrypted OS storage', () => {
  for (const backend of ['basic_text', 'unknown', undefined]) assert.equal(secureStorageAvailable({ isEncryptionAvailable: () => true, getSelectedStorageBackend: () => backend }, 'linux'), false);
  assert.equal(secureStorageAvailable({ isEncryptionAvailable: () => false }, 'win32'), false);
  assert.equal(secureStorageAvailable({ isEncryptionAvailable: () => true }, 'darwin'), true);
  assert.equal(secureStorageAvailable({ isEncryptionAvailable: () => { throw new Error('OS provider failed'); } }, 'darwin'), false);
});
test('sandbox and CSP keep code and native authority restricted', () => {
  assert.equal(secureWebPreferences.sandbox, true); assert.equal(secureWebPreferences.contextIsolation, true); assert.equal(secureWebPreferences.nodeIntegration, false); assert.equal(secureWebPreferences.webviewTag, false);
  const header = csp(config); assert(header.includes('script-src ' + config.serviceOrigin + '/app/assets/;')); assert(!header.includes("script-src 'self'")); assert(!header.includes('unsafe-eval')); assert(!header.includes('https://*')); assert(header.includes("frame-src 'none'"));
});
test('actual sandbox preload exports three narrow calls and no event, shell, filesystem or network passthrough', async () => {
  const calls = []; let exposed;
  const source = await readFile(new URL('../src/preload.cjs', import.meta.url), 'utf8');
  vm.runInNewContext(source, { require: name => { assert.equal(name, 'electron'); return { contextBridge: { exposeInMainWorld: (name, value) => { assert.equal(name, 'kCommsDesktop'); exposed = value; } }, ipcRenderer: { invoke: (...args) => { calls.push(args); return Promise.resolve(); } } }; } });
  assert.deepEqual(Object.keys(exposed).sort(), ['credentials', 'getState', 'version']);
  assert.deepEqual(Object.keys(exposed.credentials).sort(), ['load', 'replace']);
  exposed.getState(); exposed.credentials.load(); exposed.credentials.replace({ generation: 1, kind: null, value: null });
  assert.deepEqual(calls.map(call => call[0]), ['desktop:state:v1', 'desktop:credentials:load:v1', 'desktop:credentials:replace:v1']);
  assert(Object.isFrozen(exposed)); assert(Object.isFrozen(exposed.credentials));
});
