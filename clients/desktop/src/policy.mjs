import path from 'node:path';

export const MAX_CREDENTIAL_BYTES = 64 * 1024;
export const CHANNELS = Object.freeze({ state: 'desktop:state:v1', load: 'desktop:credentials:load:v1', replace: 'desktop:credentials:replace:v1' });
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uiRoutes = new Set(['/', '/sign-in', '/join', '/forgot-password', '/reset-password', '/admin', '/ops']);
function uiPath(value) {
  return !value.includes('\\') && !value.includes('\0') && !value.split('/').some(part => part === '.' || part === '..') && (uiRoutes.has(value) || value === '/app' || (value.startsWith('/app/') && !path.posix.extname(value)));
}

function record(value) { return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype; }
function exactKeys(value, keys) { return record(value) && Object.keys(value).every(key => keys.includes(key)) && keys.every(key => Object.hasOwn(value, key)); }
export function httpsOrigin(value, protocols = ['https:']) {
  if (typeof value !== 'string' || value.length > 253 || value !== value.trim()) throw new Error('Invalid fixed origin');
  const url = new URL(value);
  if (!protocols.includes(url.protocol) || !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/i.test(url.hostname) || !url.hostname.includes('.') || url.hostname.endsWith('.') || url.username || url.password || url.port || url.pathname !== '/' || url.search || url.hash || value !== url.origin) throw new Error('An exact HTTPS/WSS DNS origin on the standard port is required');
  if (url.hostname.split('.').some(label => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label))) throw new Error('Invalid DNS label');
  if (/^(?:localhost|.*\.localhost|.*\.local|.*\.internal)$/.test(url.hostname) || /^\d+\.\d+\.\d+\.\d+$/.test(url.hostname)) throw new Error('Local or numeric origins are not permitted');
  return url.origin;
}
export function validateConfig(value) {
  if (!exactKeys(value, ['version', 'serviceOrigin', 'mediaOrigins', 'resourceOrigins', 'qualificationOnly', 'updates', 'unsigned']) || value.version !== 1 || value.updates !== 'disabled' || value.unsigned !== true || typeof value.qualificationOnly !== 'boolean') throw new Error('Unsupported Desktop policy');
  const serviceOrigin = value.serviceOrigin === null ? null : httpsOrigin(value.serviceOrigin);
  for (const list of [value.mediaOrigins, value.resourceOrigins]) if (!Array.isArray(list) || list.length > 8 || new Set(list).size !== list.length) throw new Error('Invalid exact origin list');
  const mediaOrigins = value.mediaOrigins.map(origin => httpsOrigin(origin, ['https:', 'wss:']));
  const resourceOrigins = value.resourceOrigins.map(origin => httpsOrigin(origin));
  if (!serviceOrigin && !value.qualificationOnly) throw new Error('Desktop service origin is not configured');
  return Object.freeze({ ...value, serviceOrigin, mediaOrigins: Object.freeze(mediaOrigins), resourceOrigins: Object.freeze(resourceOrigins) });
}
export function ownedUiUrl(value, config) {
  try { const url = new URL(value); return url.origin === config.serviceOrigin && !url.username && !url.password && uiPath(decodeURIComponent(url.pathname)); } catch { return false; }
}
export function allowedNetworkUrl(value, config) {
  try {
    const url = new URL(value);
    if (url.username || url.password) return false;
    const origins = [config.serviceOrigin, config.serviceOrigin?.replace(/^https:/, 'wss:'), ...config.mediaOrigins, ...config.resourceOrigins];
    return ['https:', 'wss:'].includes(url.protocol) && origins.includes(url.origin);
  } catch { return false; }
}
export function localAssetPath(value, config, directory) {
  const url = new URL(value);
  if (url.origin !== config.serviceOrigin) return null;
  const decoded = decodeURIComponent(url.pathname);
  if (decoded.includes('\\') || decoded.includes('\0') || decoded.split('/').some(part => part === '.' || part === '..')) throw new Error('Invalid asset path');
  if (uiPath(decoded)) return path.join(directory, 'index.html');
  if (!decoded.startsWith('/app/')) return null;
  const filename = path.resolve(directory, decoded.slice('/app/'.length));
  if (!filename.startsWith(path.resolve(directory) + path.sep)) throw new Error('Asset traversal refused');
  if (!/\.(?:html|js|css|json|webmanifest|woff2?|png|jpe?g|svg|ico|webp|avif|wasm)$/.test(filename)) throw new Error('Unsupported packaged asset');
  return filename;
}
export function trustedSender(event, window, config) {
  return Boolean(window && !window.isDestroyed() && event.sender === window.webContents && event.senderFrame === window.webContents.mainFrame && ownedUiUrl(event.senderFrame.url, config));
}
export function validateCredential(value, kind) {
  const allowed = ['access_token', 'refresh_token', 'token_type', 'expires_in', 'received_at', 'tenant', 'user', 'device', ...(kind === 'guest' ? ['conversation', 'capabilities', 'admission', 'instant_room', 'share_url'] : [])];
  if (!record(value) || Object.keys(value).some(key => !allowed.includes(key)) || Buffer.byteLength(JSON.stringify(value)) > MAX_CREDENTIAL_BYTES) throw new Error('Invalid credential envelope');
  if (![value.access_token, value.refresh_token].every(token => typeof token === 'string' && token.length >= 1 && token.length <= 8192 && !/[\r\n\0]/.test(token)) || value.token_type !== 'Bearer' || !Number.isInteger(value.expires_in) || value.expires_in < 1 || value.expires_in > 86400) throw new Error('Invalid credential fields');
  if (value.received_at !== undefined && (!Number.isSafeInteger(value.received_at) || value.received_at < 0)) throw new Error('Invalid credential receipt time');
  if (![value.tenant, value.user, value.device].every(record) || ![value.tenant.id, value.user.id, value.device.id].every(id => typeof id === 'string' && uuid.test(id)) || value.user.tenant_id !== value.tenant.id || value.device.user_id !== value.user.id) throw new Error('Credential identity does not match');
  if (kind === 'guest' && (value.user.account_type !== 'guest' || !record(value.conversation) || !uuid.test(value.conversation.id) || !record(value.capabilities))) throw new Error('Invalid guest credential');
  if (kind === 'member' && !['human', undefined].includes(value.user.account_type)) throw new Error('Guest credential cannot be stored as a member');
  return JSON.parse(JSON.stringify(value));
}
export function validateReplacement(value) {
  if (!exactKeys(value, ['generation', 'kind', 'value']) || !Number.isSafeInteger(value.generation) || value.generation < 1) throw new Error('Invalid credential command');
  if (value.kind === null && value.value === null) return { ...value };
  if (!['member', 'guest'].includes(value.kind) || value.value === null) throw new Error('Invalid credential kind');
  return { ...value, value: validateCredential(value.value, value.kind) };
}
export function credentialIdentity(state) {
  return state.kind ? [state.kind, state.value.tenant.id, state.value.user.id, state.value.device.id, state.kind === 'guest' ? state.value.conversation.id : ''].join(':') : null;
}
export function secureStorageAvailable(storage, platform) {
  try { return storage.isEncryptionAvailable() === true && (platform !== 'linux' || ['gnome_libsecret', 'kwallet', 'kwallet5', 'kwallet6'].includes(storage.getSelectedStorageBackend?.())); }
  catch { return false; }
}
export function csp(config) {
  const connections = ["'self'", config.serviceOrigin.replace(/^https:/, 'wss:'), ...config.mediaOrigins, ...config.resourceOrigins].join(' ');
  return "default-src 'self'; base-uri 'none'; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src " + config.serviceOrigin + "/app/assets/; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:; font-src 'self'; img-src 'self' data: blob: " + config.resourceOrigins.join(' ') + "; media-src 'self' blob: " + config.resourceOrigins.join(' ') + '; connect-src ' + connections;
}
export const secureWebPreferences = Object.freeze({ sandbox: true, contextIsolation: true, nodeIntegration: false, nodeIntegrationInWorker: false, nodeIntegrationInSubFrames: false, webSecurity: true, allowRunningInsecureContent: false, webviewTag: false, devTools: false, spellcheck: false });
