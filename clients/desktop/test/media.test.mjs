import test from 'node:test';
import assert from 'node:assert/strict';
import { config } from './fixtures.mjs';
import { MediaPolicy } from '../src/media.mjs';
function fixture(extra = {}) {
  const handlers = {};
  const contents = { mainFrame: { url: config.serviceOrigin + '/app/' } }; const window = { webContents: contents, isDestroyed: () => false, isFocused: () => true };
  const session = { setPermissionCheckHandler: h => { handlers.check = h; }, setPermissionRequestHandler: h => { handlers.request = h; }, setDisplayMediaRequestHandler: h => { handlers.display = h; } };
  const policy = new MediaPolicy({ session, getWindow: () => window, vault: { available: () => true, state: { kind: 'member' } }, config, platform: 'linux', systemPreferences: {}, dialog: { showMessageBox: async () => ({ response: 1 }) }, desktopCapturer: { getSources: async () => [{ id: 'screen:1', name: 'Screen one' }, { id: 'window:2', name: 'Window two' }] }, ...extra });
  policy.install(); return { policy, handlers, contents, window };
}
const request = (f, type = 'media', changes = {}) => new Promise(resolve => f.handlers.request(f.contents, type, resolve, { mediaTypes: ['audio'], requestingUrl: config.serviceOrigin + '/app/', isMainFrame: true, ...changes }));
const display = (f, changes = {}) => new Promise(resolve => f.handlers.display({ frame: f.contents.mainFrame, securityOrigin: config.serviceOrigin, userGesture: true, videoRequested: true, audioRequested: false, ...changes }, resolve));

test('foreign frames, unknown permissions, invalid media types and logged-out capture fail closed', async () => {
  const f = fixture();
  assert.equal(f.handlers.check(null, 'media', config.serviceOrigin, { isMainFrame: true, mediaType: 'audio' }), false);
  assert.equal(await request(f, 'geolocation'), false); assert.equal(await request(f, 'media', { isMainFrame: false }), false); assert.equal(await request(f, 'media', { requestingUrl: 'https://evil.example.org/app/' }), false); assert.equal(await request(f, 'media', { mediaTypes: ['audio', 'unknown'] }), false);
  f.policy.vault.state.kind = null; assert.equal(await request(f), false); assert.deepEqual(await display(f), {});
});
test('microphone permission requires explicit native consent and OS denial remains final', async () => {
  const f = fixture(); assert.equal(f.handlers.check(f.contents, 'media', config.serviceOrigin, { isMainFrame: true, mediaType: 'audio' }), false);
  assert.equal(await request(f), true); assert.equal(f.handlers.check(f.contents, 'media', config.serviceOrigin, { isMainFrame: true, mediaType: 'audio' }), true); assert.equal(f.handlers.check(f.contents, 'media', config.serviceOrigin, { isMainFrame: true, mediaType: 'video' }), false);
  const denied = fixture({ platform: 'darwin', systemPreferences: { askForMediaAccess: async () => false } }); assert.equal(await request(denied), false);
});
test('logout during an OS/media dialog cannot grant the previous generation', async () => {
  let release; const f = fixture({ dialog: { showMessageBox: () => new Promise(resolve => { release = resolve; }) } });
  const pending = request(f); f.policy.revoke(); release({ response: 1 }); assert.equal(await pending, false);
});
test('display sharing requires foreground gesture and actual selected source, never implicit system audio', async () => {
  const f = fixture({ dialog: { showMessageBox: async () => ({ response: 2 }) } });
  assert.deepEqual(await display(f, { userGesture: false }), {}); assert.deepEqual(await display(f, { audioRequested: true }), {}); assert.deepEqual(await display(f, { securityOrigin: 'https://evil.example.org' }), {});
  assert.deepEqual(await display(f), { video: { id: 'window:2', name: 'Window two' } });
  f.window.isFocused = () => false; assert.deepEqual(await display(f), {});
});
test('display picker reply after session switch cannot start capture', async () => {
  let release; const f = fixture({ dialog: { showMessageBox: () => new Promise(resolve => { release = resolve; }) } });
  const pending = display(f); await Promise.resolve(); f.policy.revoke(); release({ response: 1 }); assert.deepEqual(await pending, {});
});
