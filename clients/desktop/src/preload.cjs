const { contextBridge, ipcRenderer } = require('electron');
const bridge = Object.freeze({
  version: 1,
  getState: () => ipcRenderer.invoke('desktop:state:v1'),
  credentials: Object.freeze({
    load: () => ipcRenderer.invoke('desktop:credentials:load:v1'),
    replace: command => ipcRenderer.invoke('desktop:credentials:replace:v1', command)
  })
});
contextBridge.exposeInMainWorld('kCommsDesktop', bridge);
