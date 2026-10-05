import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { config } from './fixtures.mjs';
import { DesktopShell, desktopWindowChrome, SHELL_ACTIONS, SHELL_CHANNELS, TITLE_BAR_HEIGHT } from '../src/shell.mjs';

function setup(platform = 'win32') {
  const sent = []; const overlays = []; const dialogs = []; const handlers = new Map();
  let focused = true; let destroyed = false; let kind = 'member';
  const frame = { url: config.serviceOrigin + '/sign-in', send: (...args) => sent.push(args) };
  const contents = Object.assign(new EventEmitter(), { mainFrame: frame });
  const window = Object.assign(new EventEmitter(), { webContents: contents, isDestroyed: () => destroyed, isFocused: () => focused, setTitleBarOverlay: value => overlays.push(value) });
  const event = { sender: contents, senderFrame: frame };
  const Menu = {
    buildFromTemplate: template => ({
      items: template.map(item => ({ ...item, ...(item.submenu ? { submenu: { items: item.submenu, popup: options => { Menu.lastPopup = options; } } } : {}) })),
      getMenuItemById(id) { return this.items.find(item => item.id === id) || this.items.flatMap(item => item.submenu?.items || []).find(item => item.id === id); }
    }),
    setApplicationMenu(menu) { this.applicationMenu = menu; }
  };
  class NativeTheme extends EventEmitter {
    constructor() { super(); this._themeSource = 'system'; this.shouldUseDarkColors = false; }
    get themeSource() { return this._themeSource; }
    set themeSource(value) { this._themeSource = value; this.shouldUseDarkColors = value === 'dark'; this.emit('updated'); }
  }
  const nativeTheme = new NativeTheme();
  const ipcMain = { handle: (channel, handler) => handlers.set(channel, handler), removeHandler: channel => handlers.delete(channel) };
  const shell = new DesktopShell({ Menu, nativeTheme, app: { getVersion: () => '0.3.0' }, dialog: { showMessageBox: async (_window, options) => { dialogs.push(options); } }, getWindow: () => window, config, platform, canUseWorkspace: () => kind === 'member' });
  shell.install(ipcMain);
  return { shell, Menu, nativeTheme, window, frame, contents, event, handlers, sent, overlays, dialogs, setFocused: value => { focused = value; }, setDestroyed: value => { destroyed = value; }, setKind: value => { kind = value; } };
}

test('native window chrome retains OS frames and controls with one shared 44px height', () => {
  assert.equal(TITLE_BAR_HEIGHT, 44);
  for (const platform of ['win32', 'linux']) {
    for (const dark of [true, false]) {
      const chrome = desktopWindowChrome(platform, dark);
      assert.equal(chrome.frame, true); assert.equal(chrome.titleBarStyle, 'hidden');
      assert.equal(chrome.titleBarOverlay.height, 44);
      assert.equal(Object.hasOwn(chrome, 'webPreferences'), false);
      assert.equal(Object.hasOwn(chrome, 'trafficLightPosition'), false);
    }
  }
  const mac = desktopWindowChrome('darwin', false);
  assert.equal(mac.frame, true); assert.deepEqual(mac.trafficLightPosition, { x: 14, y: 15 });
  assert.equal(Object.hasOwn(mac, 'titleBarOverlay'), false);
  assert.throws(() => desktopWindowChrome('unknown', false), /Unsupported/);
});

test('shell IPC requires the current packaged main frame and finite exact arguments', () => {
  const f = setup();
  const state = f.handlers.get(SHELL_CHANNELS.state); const menu = f.handlers.get(SHELL_CHANNELS.menu); const theme = f.handlers.get(SHELL_CHANNELS.theme);
  assert.deepEqual(state(f.event), { version: 1, platform: 'win32', nativeControls: true, nativeMenu: true, titleBarHeight: 44 });
  for (const handler of [state, menu, theme]) {
    assert.throws(() => handler({ sender: {}, senderFrame: f.frame }), /Untrusted/);
    assert.throws(() => handler({ sender: f.contents, senderFrame: { url: f.frame.url } }), /Untrusted/);
  }
  assert.throws(() => state(f.event, 'extra'), /Unexpected/);
  for (const args of [[], ['view', 'extra'], ['close'], ['Edit'], [{}], ['__proto__']]) assert.throws(() => menu(f.event, ...args), /Unknown/);
  for (const args of [[], ['light', 'extra'], ['#ffffff'], [{ theme: 'light' }], ['unknown']]) assert.throws(() => theme(f.event, ...args), /Unknown/);
  menu(f.event, 'edit'); assert.equal(f.Menu.lastPopup.window, f.window);
  f.setFocused(false); assert.throws(() => menu(f.event, 'file'), /foreground/);
  f.frame.url = 'https://foreign.example.org/app/';
  assert.throws(() => state(f.event), /Untrusted/); assert.throws(() => theme(f.event, 'light'), /Untrusted/);
  f.shell.dispose();
});

test('menus use native editing, zoom, fullscreen and close roles without reload or DevTools', () => {
  for (const platform of ['win32', 'darwin', 'linux']) {
    const f = setup(platform); const menu = f.Menu.applicationMenu;
    assert.deepEqual(menu.items.filter(item => item.id).map(item => item.id), ['file', 'edit', 'view', 'help']);
    const roles = menu.items.flatMap(item => item.submenu.items.filter(subitem => subitem.role).map(subitem => subitem.role));
    for (const role of ['undo', 'redo', 'cut', 'copy', 'paste', 'selectAll', 'resetZoom', 'zoomIn', 'zoomOut', 'togglefullscreen', 'close', 'quit']) assert(roles.includes(role));
    assert(!roles.includes('reload')); assert(!roles.includes('forceReload')); assert(!roles.includes('toggleDevTools'));
    for (const item of menu.items.flatMap(item => item.submenu.items).filter(item => item.click)) {
      assert.equal(Object.hasOwn(item, 'accelerator'), false, 'custom native intents must not intercept editor or consent shortcuts');
    }
    f.shell.dispose();
  }
});

test('native UI intents expose only bounded strings to the foreground owner, including sign-in', async () => {
  const f = setup();
  const file = f.Menu.applicationMenu.getMenuItemById('file').submenu.items;
  file.find(item => item.label === 'New instant room').click();
  assert.deepEqual(f.sent, [[SHELL_CHANNELS.action, 'new-instant-room']]);
  for (const action of SHELL_ACTIONS) assert.equal(f.shell.dispatch(action), !['open-search', 'toggle-sidebar'].includes(action));
  f.frame.url = config.serviceOrigin + '/app/';
  for (const action of SHELL_ACTIONS) assert.equal(f.shell.dispatch(action), true);
  assert.throws(() => f.shell.dispatch('credentials:load'), /Unknown/);
  const before = f.sent.length;
  f.setFocused(false); assert.equal(f.shell.dispatch('open-search'), false);
  f.setFocused(true); f.frame.url = config.serviceOrigin + '/api/v1/users'; assert.equal(f.shell.dispatch('open-search'), false);
  f.frame.url = config.serviceOrigin + '/sign-in'; f.setDestroyed(true); assert.equal(f.shell.dispatch('open-search'), false);
  assert.equal(f.sent.length, before);
  f.setDestroyed(false); await f.shell.showAbout(); assert.equal(f.dialogs.length, 1);
  assert.match(f.dialogs[0].detail, /Unsigned evaluation build/); assert.match(f.dialogs[0].detail, /updates are disabled/);
  f.shell.dispose();
});

test('workspace menu intents stay disabled for public, guest, unfocused and foreign views', () => {
  const f = setup(); const search = f.Menu.applicationMenu.getMenuItemById('workspace-search');
  assert.equal(search.enabled, false);
  f.frame.url = config.serviceOrigin + '/app/'; f.contents.emit('did-navigate-in-page'); assert.equal(search.enabled, true);
  f.setKind('guest'); f.shell.refreshMenu(); assert.equal(search.enabled, false); assert.equal(f.shell.dispatch('open-search'), false);
  f.setKind(null); f.shell.refreshMenu(); assert.equal(search.enabled, false);
  f.setKind('member'); f.shell.refreshMenu(); assert.equal(search.enabled, true);
  f.setFocused(false); f.window.emit('blur'); assert.equal(search.enabled, false);
  f.setFocused(true); f.window.emit('focus'); assert.equal(search.enabled, true);
  f.frame.url = 'https://foreign.example.org/app/'; f.contents.emit('did-navigate'); assert.equal(search.enabled, false);
  f.shell.dispose(); assert.equal(f.contents.listenerCount('did-navigate'), 0); assert.equal(f.window.listenerCount('focus'), 0);
});

test('theme IPC follows explicit choices, OS updates and window lifetime without arbitrary styling', () => {
  const f = setup(); const theme = f.handlers.get(SHELL_CHANNELS.theme);
  theme(f.event, 'dark'); assert.equal(f.nativeTheme.themeSource, 'dark'); assert.equal(f.overlays.at(-1).color, '#181b22');
  theme(f.event, 'light'); assert.equal(f.overlays.at(-1).color, '#f8f9fb');
  theme(f.event, 'system'); assert.equal(f.nativeTheme.themeSource, 'system');
  f.nativeTheme.shouldUseDarkColors = true; f.nativeTheme.emit('updated'); assert.equal(f.overlays.at(-1).color, '#181b22');
  assert(f.overlays.every(value => value.height === 44));
  const before = f.overlays.length; f.setDestroyed(true); f.nativeTheme.emit('updated'); assert.equal(f.overlays.length, before);
  f.shell.dispose(); assert.equal(f.nativeTheme.listenerCount('updated'), 0); assert.equal(f.handlers.size, 0);
  const mac = setup('darwin'); mac.handlers.get(SHELL_CHANNELS.theme)(mac.event, 'dark'); assert.equal(mac.overlays.length, 0); mac.shell.dispose();
});
