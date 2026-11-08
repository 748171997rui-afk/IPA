// 只暴露窗口外壳能力给页面，绝不注入 window.DingCheng / webkit 桥（否则会被网页误判为安卓/iOS App）
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('dcDesktop', {
  minimize: () => ipcRenderer.send('dc:minimize'),
  toggleMax: () => ipcRenderer.invoke('dc:toggle-max'),
  close: () => ipcRenderer.send('dc:close'),
  menu: () => ipcRenderer.send('dc:menu'),
  info: () => ipcRenderer.invoke('dc:info'),
  onMaxChanged: cb => ipcRenderer.on('dc:max-changed', (_e, v) => cb(v)),
  onRelogin: cb => ipcRenderer.on('dc:relogin', () => cb()),
  isDesktop: true,
  isMac: process.platform === 'darwin'
});
