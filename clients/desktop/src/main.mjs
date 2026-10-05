import { app, BrowserWindow, session, ipcMain, safeStorage, dialog, systemPreferences, desktopCapturer } from 'electron';
import { readFile, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateConfig, allowedNetworkUrl, ownedUiUrl, localAssetPath, trustedSender, secureWebPreferences, csp, CHANNELS } from './policy.mjs';
import { CredentialVault } from './credentials.mjs';
import { MediaPolicy } from './media.mjs';

const sourceDirectory = path.dirname(fileURLToPath(import.meta.url));
const assetDirectory = path.resolve(sourceDirectory, '../web-dist');
let window; let vault; let media; let policy; let profile;
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ico': 'image/x-icon', '.webp': 'image/webp', '.avif': 'image/avif', '.wasm': 'application/wasm' };
for (const flag of ['no-sandbox', 'disable-web-security', 'remote-debugging-port', 'remote-debugging-pipe']) if (app.commandLine.hasSwitch(flag)) throw new Error('Unsafe Electron launch flag refused');
app.enableSandbox();
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (window && !window.isDestroyed()) { if (window.isMinimized()) window.restore(); window.focus(); } });
  app.whenReady().then(start).catch(() => { dialog.showErrorBox('Desktop setup required', 'This unsigned evaluation build needs an authorized fixed HTTPS service configuration and encrypted operating-system credential storage. No insecure fallback is available.'); app.quit(); });
}
app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => { media?.revoke(); });

async function start() {
  policy = validateConfig(JSON.parse(await readFile(path.resolve(sourceDirectory, '../desktop.config.json'), 'utf8')));
  if (!policy.serviceOrigin || policy.qualificationOnly) throw new Error('Evaluation configuration cannot connect to a real service');
  // Non-persistent Chromium partition: cookies, browser credential storage and
  // service-worker caches never become a second plaintext credential vault.
  profile = session.fromPartition('k-comms-desktop-v1');
  vault = new CredentialVault({ storage: safeStorage, platform: process.platform, directory: path.join(app.getPath('userData'), 'encrypted-session'), origin: policy.serviceOrigin, onIdentityChanged: () => { media?.revoke(); void profile.clearStorageData(); } });
  await vault.load();
  profile.webRequest.onBeforeRequest((details, callback) => {
    const allowed = allowedNetworkUrl(details.url, policy);
    // Documents are always our packaged UI, never a remote privileged page.
    callback({ cancel: !allowed || (details.resourceType === 'mainFrame' && !ownedUiUrl(details.url, policy)) || details.resourceType === 'subFrame' });
  });
  profile.webRequest.onBeforeSendHeaders((details, callback) => {
    const headers = { ...details.requestHeaders };
    if (new URL(details.url).origin !== policy.serviceOrigin && !details.url.startsWith(policy.serviceOrigin.replace(/^https:/, 'wss:') + '/')) for (const key of Object.keys(headers)) if (['authorization', 'x-k-comms-socket-ticket', 'cookie'].includes(key.toLowerCase())) delete headers[key];
    callback({ requestHeaders: headers });
  });
  profile.protocol.handle('https', async request => {
    if (!allowedNetworkUrl(request.url, policy)) return new Response('', { status: 403 });
    let filename;
    try { filename = localAssetPath(request.url, policy, assetDirectory); } catch { return new Response('', { status: 404 }); }
    if (!filename) return profile.fetch(request, { bypassCustomProtocolHandlers: true });
    if (!['GET', 'HEAD'].includes(request.method)) return new Response('', { status: 405 });
    try {
      const resolved = await realpath(filename); const root = await realpath(assetDirectory);
      if (!resolved.startsWith(root + path.sep) || (await stat(resolved)).size > 32 * 1024 * 1024) return new Response('', { status: 404 });
      return new Response(request.method === 'HEAD' ? null : await readFile(resolved), { headers: {
        'Content-Type': mime[path.extname(resolved)] || 'application/octet-stream', 'Content-Security-Policy': csp(policy),
        'Permissions-Policy': 'camera=(self), microphone=(self), display-capture=(self), geolocation=()',
        'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store'
      } });
    } catch { return new Response('', { status: 404 }); }
  });
  window = new BrowserWindow({ width: 1280, height: 860, minWidth: 360, minHeight: 600, show: false, title: 'K-Comms · Unsigned evaluation', autoHideMenuBar: true, webPreferences: { ...secureWebPreferences, session: profile, preload: path.join(sourceDirectory, 'preload.cjs') } });
  window.setMenu(null);
  media = new MediaPolicy({ session: profile, getWindow: () => window, vault, config: policy, dialog, systemPreferences, desktopCapturer, platform: process.platform });
  media.install();
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => { if (!ownedUiUrl(event.url, policy)) event.preventDefault(); });
  window.webContents.on('will-redirect', event => { if (!ownedUiUrl(event.url, policy)) event.preventDefault(); });
  window.webContents.on('will-attach-webview', event => event.preventDefault());
  window.webContents.on('will-frame-navigate', event => { if (!event.isMainFrame || !ownedUiUrl(event.url, policy)) event.preventDefault(); });
  profile.on('will-download', (event, item, contents) => {
    const current = contents === window.webContents && window.isFocused() && vault.state.kind;
    const url = item.getURL();
    if (!current || (!allowedNetworkUrl(url, policy) && !url.startsWith('blob:' + policy.serviceOrigin + '/'))) { event.preventDefault(); return; }
    const generation = vault.state.generation;
    item.setSaveDialogOptions({ title: 'Save K-Comms file', defaultPath: path.basename(item.getFilename()).replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 200) || 'download' });
    item.on('updated', () => { if (vault.state.generation !== generation || item.getReceivedBytes() > 100 * 1024 * 1024) item.cancel(); });
  });
  for (const channel of Object.values(CHANNELS)) ipcMain.removeHandler(channel);
  const authorize = event => { if (!trustedSender(event, window, policy)) throw new Error('Untrusted Desktop frame'); };
  ipcMain.handle(CHANNELS.state, (event, ...args) => { authorize(event); if (args.length) throw new Error('Unexpected state arguments'); return { version: 1, serviceOrigin: policy.serviceOrigin, generation: vault.state.generation, credentialStorage: vault.available() ? 'os-encrypted' : 'unavailable', updates: 'disabled', unsigned: true, platform: process.platform }; });
  ipcMain.handle(CHANNELS.load, (event, ...args) => { authorize(event); if (args.length) throw new Error('Unexpected load arguments'); vault.requireEncryption(); return vault.snapshot(); });
  ipcMain.handle(CHANNELS.replace, (event, ...args) => { authorize(event); if (args.length !== 1) throw new Error('Unexpected credential arguments'); return vault.replace(args[0]); });
  window.once('ready-to-show', () => window.show());
  window.on('closed', () => { media.revoke(); window = null; });
  await window.loadURL(policy.serviceOrigin + '/app/');
  // No feed, checkForUpdates, unsigned update installer, shell opener, protocol
  // launcher or arbitrary renderer filesystem/network command exists.
}
