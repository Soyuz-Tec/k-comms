import { ownedUiUrl, trustedSender } from './policy.mjs';

export const TITLE_BAR_HEIGHT = 44;
export const SHELL_CHANNELS = Object.freeze({
  state: 'desktop:shell:state:v1',
  menu: 'desktop:shell:menu:v1',
  theme: 'desktop:shell:theme:v1',
  action: 'desktop:shell:action:v1'
});
export const SHELL_ACTIONS = Object.freeze(['new-instant-room', 'open-workspace', 'open-search', 'toggle-sidebar', 'open-help']);
const categories = Object.freeze(['file', 'edit', 'view', 'help']);
const platforms = Object.freeze(['win32', 'darwin', 'linux']);
const themes = Object.freeze(['light', 'dark', 'system']);
// The fixed native palette matches the web header's surface-rail/text-primary
// roles. Renderer input can select a theme, never arbitrary native styles.
const titleBarPalette = Object.freeze({
  light: Object.freeze({ color: '#f8f9fb', symbolColor: '#1d2433', height: TITLE_BAR_HEIGHT }),
  dark: Object.freeze({ color: '#181b22', symbolColor: '#edf1f8', height: TITLE_BAR_HEIGHT })
});

export function desktopWindowChrome(platform, dark) {
  if (!platforms.includes(platform)) throw new Error('Unsupported Desktop shell platform');
  return {
    frame: true,
    titleBarStyle: 'hidden',
    ...(platform === 'darwin'
      ? { trafficLightPosition: { x: 14, y: 15 } }
      : { titleBarOverlay: { ...titleBarPalette[dark ? 'dark' : 'light'] } })
  };
}

/** Native shell commands do not acquire credentials, media or navigation rights. */
export class DesktopShell {
  constructor({ Menu, app, dialog, nativeTheme, getWindow, config, platform, canUseWorkspace = () => false }) {
    if (!platforms.includes(platform)) throw new Error('Unsupported Desktop shell platform');
    Object.assign(this, { Menu, app, dialog, nativeTheme, getWindow, config, platform, canUseWorkspace });
    this.onThemeUpdated = () => this.updateTitleBar();
    this.onNavigation = () => this.refreshMenu();
  }

  authorize(event) {
    const window = this.getWindow();
    if (!trustedSender(event, window, this.config)) throw new Error('Untrusted Desktop frame');
    return window;
  }

  currentWindow() {
    const window = this.getWindow();
    try {
      return window && !window.isDestroyed() && window.isFocused()
        && ownedUiUrl(window.webContents.mainFrame.url, this.config) ? window : null;
    } catch { return null; } // A renderer/frame may already be disposed.
  }

  workspaceAvailable() {
    const window = this.currentWindow();
    return Boolean(window && this.canUseWorkspace()
      && /^\/(?:app(?:\/|$)|admin(?:\/|$)|ops(?:\/|$))/.test(new URL(window.webContents.mainFrame.url).pathname));
  }

  refreshMenu() {
    if (!this.menu) return;
    const enabled = this.workspaceAvailable();
    for (const id of ['sidebar', 'workspace-search']) this.menu.getMenuItemById(id).enabled = enabled;
  }

  dispatch(action) {
    if (!SHELL_ACTIONS.includes(action)) throw new Error('Unknown Desktop shell action');
    if (['open-search', 'toggle-sidebar'].includes(action) && !this.workspaceAvailable()) return false;
    const window = this.currentWindow();
    if (!window) return false;
    try { window.webContents.mainFrame.send(SHELL_CHANNELS.action, action); return true; }
    catch { return false; } // A frame may close between ownership check and send.
  }

  async showAbout() {
    const window = this.currentWindow();
    if (!window) return;
    await this.dialog.showMessageBox(window, {
      type: 'info', title: 'About K-Comms', message: 'K-Comms Desktop',
      detail: `Version ${this.app.getVersion()}\nUnsigned evaluation build. Automatic updates are disabled. Native storage and media remain subject to platform qualification.`,
      buttons: ['OK'], defaultId: 0, cancelId: 0, noLink: true
    });
  }

  createMenu() {
    const intent = action => () => this.dispatch(action);
    const about = () => { void this.showAbout().catch(() => undefined); };
    const label = value => this.platform === 'darwin' ? value : '&' + value;
    const template = [
      ...(this.platform === 'darwin' ? [{ label: 'K-Comms', submenu: [
        { label: 'About K-Comms', click: about }, { type: 'separator' },
        { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' },
        { type: 'separator' }, { role: 'quit' }
      ] }] : []),
      { id: 'file', label: label('File'), submenu: [
        { label: 'New instant room', click: intent('new-instant-room') },
        { label: 'Open workspace', click: intent('open-workspace') },
        { type: 'separator' }, { role: 'close' },
        ...(this.platform === 'darwin' ? [] : [{ role: 'quit' }])
      ] },
      { id: 'edit', label: label('Edit'), submenu: [
        { role: 'undo' }, { role: 'redo' }, { type: 'separator' },
        { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'delete' },
        { type: 'separator' }, { role: 'selectAll' }
      ] },
      { id: 'view', label: label('View'), submenu: [
        // Custom intents are menu clicks only. Renderer shortcuts must retain
        // editable-field, modal and consent guards without native interception.
        { id: 'sidebar', label: 'Workspace navigation', enabled: false, click: intent('toggle-sidebar') },
        { id: 'workspace-search', label: 'Search workspace', enabled: false, click: intent('open-search') },
        { type: 'separator' }, { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' },
        { type: 'separator' }, { role: 'togglefullscreen' }
      ] },
      { id: 'help', label: label('Help'), submenu: [
        { label: 'K-Comms help', click: intent('open-help') },
        { label: 'About K-Comms', click: about }
      ] }
    ];
    return this.Menu.buildFromTemplate(template);
  }

  updateTitleBar() {
    const window = this.getWindow();
    if (this.platform !== 'darwin' && window && !window.isDestroyed()) {
      window.setTitleBarOverlay({ ...titleBarPalette[this.nativeTheme.shouldUseDarkColors ? 'dark' : 'light'] });
    }
  }

  install(ipcMain) {
    this.ipcMain = ipcMain;
    this.menu = this.createMenu();
    this.Menu.setApplicationMenu(this.menu);
    this.ownerContents = this.getWindow()?.webContents;
    this.ownerWindow = this.getWindow();
    this.ownerContents?.on?.('did-navigate', this.onNavigation);
    this.ownerContents?.on?.('did-navigate-in-page', this.onNavigation);
    this.ownerWindow?.on?.('focus', this.onNavigation);
    this.ownerWindow?.on?.('blur', this.onNavigation);
    this.nativeTheme.on('updated', this.onThemeUpdated);
    this.refreshMenu();
    for (const channel of [SHELL_CHANNELS.state, SHELL_CHANNELS.menu, SHELL_CHANNELS.theme]) ipcMain.removeHandler(channel);
    ipcMain.handle(SHELL_CHANNELS.state, (event, ...args) => {
      this.authorize(event);
      if (args.length) throw new Error('Unexpected Desktop shell state arguments');
      return { version: 1, platform: this.platform, nativeControls: true, nativeMenu: true, titleBarHeight: TITLE_BAR_HEIGHT };
    });
    ipcMain.handle(SHELL_CHANNELS.menu, (event, ...args) => {
      const window = this.authorize(event);
      if (args.length !== 1 || !categories.includes(args[0])) throw new Error('Unknown Desktop menu');
      if (!window.isFocused()) throw new Error('Desktop menu requires the foreground window');
      this.refreshMenu();
      this.menu.getMenuItemById(args[0]).submenu.popup({ window });
    });
    ipcMain.handle(SHELL_CHANNELS.theme, (event, ...args) => {
      this.authorize(event);
      if (args.length !== 1 || !themes.includes(args[0])) throw new Error('Unknown Desktop theme');
      this.nativeTheme.themeSource = args[0];
      this.updateTitleBar();
    });
    this.updateTitleBar();
  }

  dispose() {
    this.nativeTheme.removeListener('updated', this.onThemeUpdated);
    this.ownerContents?.removeListener?.('did-navigate', this.onNavigation);
    this.ownerContents?.removeListener?.('did-navigate-in-page', this.onNavigation);
    this.ownerWindow?.removeListener?.('focus', this.onNavigation);
    this.ownerWindow?.removeListener?.('blur', this.onNavigation);
    for (const channel of [SHELL_CHANNELS.state, SHELL_CHANNELS.menu, SHELL_CHANNELS.theme]) this.ipcMain?.removeHandler(channel);
  }
}
