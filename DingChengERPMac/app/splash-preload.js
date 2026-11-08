// 启动自检窗口专用桥：只传状态与「跳过等待」，不给页面任何 Node 能力
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('dcBootApi', {
  onState: cb => ipcRenderer.on('dc:boot-state', (_e, state) => cb(state)),
  skip: () => ipcRenderer.send('dc:boot-skip')
});
