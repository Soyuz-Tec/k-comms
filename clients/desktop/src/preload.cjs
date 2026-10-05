const { contextBridge, ipcRenderer } = require('electron');
const shellActions = new Set(['new-instant-room', 'open-workspace', 'open-search', 'toggle-sidebar', 'open-help']);
const bridge = Object.freeze({
  version: 1,
  getState: () => ipcRenderer.invoke('desktop:state:v1'),
  credentials: Object.freeze({
    load: () => ipcRenderer.invoke('desktop:credentials:load:v1'),
    replace: command => ipcRenderer.invoke('desktop:credentials:replace:v1', command)
  }),
  shell: Object.freeze({
    getState: () => ipcRenderer.invoke('desktop:shell:state:v1'),
    showMenu: category => ipcRenderer.invoke('desktop:shell:menu:v1', category),
    setTheme: theme => ipcRenderer.invoke('desktop:shell:theme:v1', theme),
    subscribe: listener => {
      if (typeof listener !== 'function') throw new TypeError('Desktop shell listener must be a function');
      const handler = (_event, ...args) => {
        if (args.length === 1 && shellActions.has(args[0])) listener(args[0]);
      };
      ipcRenderer.on('desktop:shell:action:v1', handler);
      let active = true;
      return () => {
        if (!active) return;
        active = false;
        ipcRenderer.removeListener('desktop:shell:action:v1', handler);
      };
    }
  })
});
contextBridge.exposeInMainWorld('kCommsDesktop', bridge);
