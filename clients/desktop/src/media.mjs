import { ownedUiUrl } from './policy.mjs';

export class MediaPolicy {
  constructor({ session, getWindow, vault, config, dialog, systemPreferences, desktopCapturer, platform }) {
    Object.assign(this, { session, getWindow, vault, config, dialog, systemPreferences, desktopCapturer, platform });
    this.epoch = 0; this.grants = new Set();
  }
  revoke() { this.epoch += 1; this.grants.clear(); }
  current(contents, url, epoch = this.epoch) {
    const window = this.getWindow();
    return Boolean(window && !window.isDestroyed() && contents === window.webContents && window.isFocused() && epoch === this.epoch && this.vault.available() && this.vault.state.kind && ownedUiUrl(url, this.config));
  }
  install() {
    this.session.setPermissionCheckHandler((contents, permission, origin, details) => {
      if (!['media', 'display-capture'].includes(permission) || origin !== this.config.serviceOrigin || details.isMainFrame !== true || !this.current(contents, contents?.mainFrame?.url)) return false;
      if (permission === 'display-capture') return true; // Native picker still requires a foreground gesture and explicit source.
      const kind = details.mediaType;
      return ['audio', 'video'].includes(kind) && this.grants.has(kind);
    });
    this.session.setPermissionRequestHandler((contents, permission, callback, details) => {
      const epoch = this.epoch;
      const kinds = details.mediaTypes;
      if (permission === "display-capture") { callback(details.isMainFrame === true && this.current(contents, details.requestingUrl, epoch)); return; }
      if (permission !== 'media' || details.isMainFrame !== true || !Array.isArray(kinds) || kinds.length < 1 || kinds.length > 2 || new Set(kinds).size !== kinds.length || kinds.some(kind => !['audio', 'video'].includes(kind)) || !this.current(contents, details.requestingUrl, epoch)) { callback(false); return; }
      void this.requestMedia(contents, kinds, epoch).then(callback, () => callback(false));
    });
    this.session.setDisplayMediaRequestHandler((request, callback) => {
      const window = this.getWindow(); const epoch = this.epoch;
      if (!window || request.frame !== window.webContents.mainFrame || request.securityOrigin !== this.config.serviceOrigin || request.userGesture !== true || request.videoRequested !== true || request.audioRequested === true || !this.current(window.webContents, request.frame.url, epoch)) { callback({}); return; }
      void this.chooseDisplay(window, epoch).then(source => callback(source ? { video: source } : {}), () => callback({}));
    }, { useSystemPicker: false });
  }
  async requestMedia(contents, kinds, epoch) {
    const window = this.getWindow();
    const message = 'Allow this K-Comms session to use ' + kinds.map(kind => kind === 'audio' ? 'the microphone' : 'the camera').join(' and ') + '?';
    const choice = await this.dialog.showMessageBox(window, { type: 'question', title: 'K-Comms media permission', message, buttons: ['Deny', 'Allow'], defaultId: 0, cancelId: 0, noLink: true });
    if (choice.response !== 1 || !this.current(contents, contents.mainFrame.url, epoch)) return false;
    if (this.platform === 'darwin') for (const kind of kinds) {
      if (!await this.systemPreferences.askForMediaAccess(kind === 'audio' ? 'microphone' : 'camera')) return false;
      if (!this.current(contents, contents.mainFrame.url, epoch)) return false;
    }
    kinds.forEach(kind => this.grants.add(kind)); return true;
  }
  async chooseDisplay(window, epoch) {
    const sources = await this.desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 0, height: 0 }, fetchWindowIcons: false });
    if (!this.current(window.webContents, window.webContents.mainFrame.url, epoch) || sources.length < 1 || sources.length > 32) return null;
    const labels = sources.map(source => String(source.name).replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 80) || 'Display source');
    const choice = await this.dialog.showMessageBox(window, { type: 'question', title: 'Share a screen or window', message: 'Choose exactly what this call may capture. System audio is not shared.', buttons: ['Cancel', ...labels], defaultId: 0, cancelId: 0, noLink: true });
    if (!this.current(window.webContents, window.webContents.mainFrame.url, epoch) || choice.response < 1 || choice.response > sources.length) return null;
    return sources[choice.response - 1];
  }
}
