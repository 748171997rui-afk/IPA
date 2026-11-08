// 鼎城 ERP 桌面版 · 主进程
// 设计要点：
//  1) GUI 子系统进程 —— 没有 CMD 黑框，后台 HTTP 服务与窗口跑在同一个进程里；
//  2) 不调用系统浏览器 —— 界面由自带窗口承载；
//  3) 关闭窗口 = app.quit() = 进程结束 = 本地服务与端口一起释放；
//  4) 业务逻辑完全复用 erp-web/server.js，仅追加「端口就绪回调 / 退出钩子 / 数据目录」三个适配点。
const { app, BrowserWindow, Menu, ipcMain, dialog, shell, session } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

// macOS 与 Windows 共用同一份业务逻辑，只有窗口外观 / 系统信息 / 图标格式不同。
// .app 里由 build-mac.js 组装，Windows 版由 build.js 组装，两者 resources/app 内容一致。
const IS_MAC = process.platform === 'darwin';
function macVersion() {
  try {
    const r = spawnSync('sw_vers', ['-productVersion'], { encoding: 'utf8', timeout: 3000 });
    if (r.status === 0 && r.stdout && r.stdout.trim()) return 'macOS ' + r.stdout.trim();
  } catch {}
  return 'macOS';
}

// ---- Windows 7 / 8 / 8.1 兼容层 ----
// 运行时是 Electron 22（Chromium 108 + Node 16.17.1）：官方最后一个支持 Win7/8/8.1
// 的主版本，23 起只能跑 Win10+。os.release()：6.1=Win7、6.2=Win8、6.3=Win8.1、10.0=Win10/11。
// 老系统上默认关闭 GPU 硬件加速：Win7 常见的老显卡 / 没装平台更新(KB2670838)时，
// ANGLE 走 D3D11 会直接崩窗口，改用 SwiftShader 软件渲染界面功能完全一样，只是动画略慢。
const WINVER = (() => {
  const r = os.release() || '';
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(r);
  const major = m ? Number(m[1]) : 10;
  const minor = m ? Number(m[2]) : 0;
  const build = m ? Number(m[3]) : 0;
  const legacy = process.platform === 'win32' && major === 6 && minor >= 1;
  const name = IS_MAC ? macVersion()
    : process.platform !== 'win32' ? process.platform
    : major === 6 ? (minor === 1 ? 'Windows 7' : minor === 2 ? 'Windows 8'
      : minor === 3 ? 'Windows 8.1' : 'Windows Vista 或更早')
    : 'Windows 10/11';
  return {
    legacy, name, release: r, build,
    sp1: !(legacy && minor === 1 && build < 7601), // Win7 需 SP1(7601)
    mode: legacy ? '兼容模式' : '标准模式'
  };
})();
const COMPAT_GPU = WINVER.legacy || process.env.ERP_DISABLE_GPU === '1';

const APP_DIR = __dirname;
const WEB_DIR = path.join(APP_DIR, 'web');
// macOS 的窗口/Dock 图标取自 .app 的 app.icns；Windows 才用内嵌 ico
const ICON = fs.existsSync(path.join(APP_DIR, 'assets', 'app.icns'))
  ? path.join(APP_DIR, 'assets', 'app.icns')
  : path.join(APP_DIR, 'assets', 'app.ico');
const APP_NAME = '鼎城 ERP 桌面版';

// ---- 日志：GUI 程序没有控制台，日志写入用户数据目录，便于排查且绝不弹黑框 ----
// 允许自动化测试指定独立数据目录；正常双击不会带这个变量
if (process.env.ERP_DESKTOP_USER_DATA) {
  try { app.setPath('userData', process.env.ERP_DESKTOP_USER_DATA); } catch {}
}
const USER_DATA = app.getPath('userData');
fs.mkdirSync(USER_DATA, { recursive: true });
const LOG_FILE = path.join(USER_DATA, 'erp-desktop.log');
try { if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 1024 * 1024) fs.rmSync(LOG_FILE, { force: true }); } catch {}
const rawLog = console.log.bind(console), rawErr = console.error.bind(console);
const stamp = () => new Date().toLocaleString('zh-CN', { hour12: false });
function writeLog(level, args) {
  const line = `[${stamp()}] ${level} ${args.map(a => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}`;
  try { fs.appendFileSync(LOG_FILE, line + '\n', 'utf8'); } catch {}
}
console.log = (...a) => { writeLog('INFO ', a); rawLog(...a); };
console.error = (...a) => { writeLog('ERROR', a); rawErr(...a); };
// 现场排查 Win7 兼容问题时，日志第一行就能看到系统版本、架构与运行模式
console.log('[SYS] ' + WINVER.name + ' ' + WINVER.release + ' / ' + process.arch +
  ' / Electron ' + process.versions.electron + ' / Node ' + process.versions.node +
  ' / ' + WINVER.mode + (COMPAT_GPU ? '(软件渲染)' : '') +
  (WINVER.sp1 ? '' : ' [警告: Win7 未装 SP1]'));

// ---- 只跑一个实例，避免端口顺延出多个后台服务 ----
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const w = mainWin || splash;
    if (w) { if (w.isMinimized()) w.restore(); w.focus(); }
  });
}

// AppUserModelId 是 Windows 任务栏分组用的，macOS 由 Info.plist 的 CFBundleIdentifier 决定
if (!IS_MAC) app.setAppUserModelId('com.dingcheng.erp.desktop');
if (COMPAT_GPU) {
  // 必须在任何窗口创建之前设置；Win7 上关掉 D3D11/ANGLE 硬加速，改走软件渲染
  app.disableHardwareAcceleration();
  // Win7 没有 Win10 的窗口遮挡计算，开着会导致部分机型界面不刷新 / 黑屏
  app.commandLine.appendSwitch('disable-features', 'CalculateNativeWinOcclusion');
  app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');
  app.commandLine.appendSwitch('disable-renderer-backgrounding');
  console.log('[SYS] Win7/8/8.1 兼容开关已生效：软件渲染 + 关闭窗口遮挡计算');
}

let mainWin = null;
let splash = null;
let servicePort = 0;
let quitting = false;
let splashReady = false;
let lastBootState = null;
let bootSkipResolve = null;
const BOOT_MIN_SHOW_MS = 2800;     // 启动窗口至少停留这么久，让自检状态看得清楚
const BOOT_MAX_WAIT_MS = 120000;   // 自检最多等 2 分钟；超时后台继续同步，先放行主窗口

// ---- 原生菜单（frameless 窗口由标题栏的菜单按钮弹出） ----
function buildMenu() {
  const tpl = [
    {
      label: '文件',
      submenu: [
        { label: '刷新页面', accelerator: 'Ctrl+R', click: () => mainWin && mainWin.reload() },
        { label: '重新登录（清除会话）', click: () => mainWin && mainWin.webContents.send('dc:relogin') },
        { type: 'separator' },
        { label: '退出（同时关闭后台服务）', accelerator: 'Alt+F4', click: () => app.quit() }
      ]
    },
    {
      label: '视图',
      submenu: [
        { label: '放大', accelerator: 'CmdOrCtrl+=', click: () => zoom(0.2) },
        { label: '缩小', accelerator: 'CmdOrCtrl+-', click: () => zoom(-0.2) },
        { label: '恢复默认缩放', accelerator: 'CmdOrCtrl+0', click: () => zoom(0) },
        { type: 'separator' },
        { label: '全屏 / 退出全屏', accelerator: 'F11', click: () => mainWin && mainWin.setFullScreen(!mainWin.isFullScreen()) },
        { label: '开发者工具', accelerator: 'Ctrl+Shift+I', click: () => mainWin && mainWin.webContents.toggleDevTools() }
      ]
    },
    {
      label: '帮助',
      submenu: [
        {
          label: '关于鼎城 ERP',
          click: () => dialog.showMessageBox(mainWin, {
            type: 'info', title: '关于', icon: fs.existsSync(ICON) ? ICON : undefined,
            message: APP_NAME,
            detail: '江西鼎城铝模科技有限公司\n本机只读库存 / 出入库查询\n\n数据直连厂商云，程序不写入、不修改 ERP 数据。\n关闭窗口即自动停止后台服务。\n\n运行环境：' + WINVER.name + ' · ' + process.arch + ' · ' + WINVER.mode,
            buttons: ['知道了']
          })
        },
        { label: '打开日志所在文件夹', click: () => shell.showItemInFolder(LOG_FILE) }
      ]
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(tpl));
}
function zoom(delta) {
  if (!mainWin) return;
  const wc = mainWin.webContents;
  if (delta === 0) wc.setZoomFactor(1);
  else wc.getZoomFactor().then(z => wc.setZoomFactor(Math.min(2, Math.max(0.6, z + delta))));
}

// ---- 启动画面 = 开机数据自检窗口：自写 UI，不依赖浏览器 ----
function showSplash() {
  splashReady = false;
  lastBootState = null;
  splash = new BrowserWindow({
    width: 520, height: 330, frame: false, resizable: false, movable: true,
    center: true, alwaysOnTop: true, skipTaskbar: true, show: true,
    backgroundColor: '#0c4a2c',
    icon: fs.existsSync(ICON) ? ICON : undefined,
    webPreferences: {
      preload: path.join(APP_DIR, 'splash-preload.js'),
      contextIsolation: true, nodeIntegration: false
    }
  });
  splash.webContents.once('did-finish-load', () => {
    splashReady = true;
    if (lastBootState && splash && !splash.isDestroyed()) {
      try { splash.webContents.send('dc:boot-state', lastBootState); } catch {}
    }
  });
  splash.loadFile(path.join(APP_DIR, 'splash.html'));
}

function closeSplash() {
  splashReady = false;
  if (splash && !splash.isDestroyed()) splash.close();
  splash = null;
}

/** 把自检进度推给启动窗口；窗口还没渲染完时缓存，渲染完自动补发 */
function paintBoot(s) {
  lastBootState = s;
  if (splashReady && splash && !splash.isDestroyed()) {
    try { splash.webContents.send('dc:boot-state', s); } catch {}
  }
}

// ---- 主窗口 ----
function createMainWindow(port) {
  // macOS：用系统原生的红黄绿交通灯 + 隐藏式标题栏，自绘的三个窗口按钮由 CSS 隐藏；
  // Windows：保持 frameless + 自绘标题栏（含 Win7 兼容）。
  const windowChrome = IS_MAC
    ? { frame: true, titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 15, y: 14 } }
    : { frame: false };
  mainWin = new BrowserWindow({
    width: 1380, height: 900, minWidth: 1060, minHeight: 680,
    ...windowChrome, backgroundColor: '#f4f7f9', center: true, show: false,
    icon: IS_MAC ? undefined : (fs.existsSync(ICON) ? ICON : undefined),
    title: '鼎城 ERP · 库存 / 出入库查询',
    webPreferences: {
      preload: path.join(APP_DIR, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: false,
      spellcheck: false, backgroundThrottling: false
    }
  });
  mainWin.setMenuBarVisibility(false);

  mainWin.webContents.on('did-finish-load', () => {
    if (!mainWin.isVisible()) { mainWin.show(); mainWin.focus(); }
    closeSplash();
  });
  mainWin.webContents.on('did-fail-load', (_e, code, desc) => {
    console.error('页面加载失败', code, desc);
  });
  // 外部链接交给系统默认浏览器；程序自身绝不新开一个"浏览器式"窗口
  mainWin.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWin.on('maximize', () => mainWin.webContents.send('dc:max-changed', true));
  mainWin.on('unmaximize', () => mainWin.webContents.send('dc:max-changed', false));
  mainWin.on('closed', () => {
    mainWin = null;
    closeSplash();
    // 关键需求：界面关闭 → 后台服务一起关闭
    if (!quitting) app.quit();
  });

  mainWin.loadURL(`http://127.0.0.1:${port}/`);
}

// ---- CSV 导出：用原生「另存为」取代浏览器下载条，更像正常程序 ----
function hookDownload() {
  session.defaultSession.on('will-download', (event, item) => {
    const name = item.getFilename() || 'export.csv';
    // 自动化回归用：指定目录后静默保存，避免原生保存对话框阻塞无人值守测试
    if (process.env.ERP_CSV_AUTO_DIR) {
      const p = path.join(process.env.ERP_CSV_AUTO_DIR, name);
      item.setSavePath(p);
      item.once('done', (_e, state) => console.log('CSV 自动导出', state, p));
      return;
    }
    let target;
    try {
      target = dialog.showSaveDialogSync(mainWin, {
        title: '导出 CSV',
        defaultPath: path.join(app.getPath('downloads'), name),
        filters: [{ name: 'CSV 文件', extensions: ['csv'] }, { name: '所有文件', extensions: ['*'] }]
      });
    } catch { target = undefined; }
    if (!target) { item.cancel(); return; }
    item.setSavePath(target);
    item.once('done', (_e, state) => {
      if (state === 'completed') console.log('CSV 已导出 ->', target);
    });
  });
}

// ---- IPC：标题栏按钮 ----
function hookIpc() {
  // 启动窗口的「跳过等待」：立即放行主窗口，云端同步仍在后台继续
  ipcMain.on('dc:boot-skip', () => {
    console.log('[BOOT] 用户跳过等待，后台继续同步');
    if (bootSkipResolve) { const f = bootSkipResolve; bootSkipResolve = null; f(); }
  });
  ipcMain.on('dc:minimize', () => mainWin && mainWin.minimize());
  ipcMain.on('dc:close', () => app.quit());
  ipcMain.on('dc:menu', () => {
    const m = Menu.getApplicationMenu();
    if (m && mainWin) m.popup({ window: mainWin, x: 12, y: 44 });
  });
  ipcMain.handle('dc:toggle-max', () => {
    if (!mainWin) return false;
    if (mainWin.isMaximized()) mainWin.unmaximize(); else mainWin.maximize();
    return mainWin.isMaximized();
  });
  ipcMain.handle('dc:info', () => ({
    port: servicePort,
    version: app.getVersion(),
    dataDir: USER_DATA,
    company: '江西鼎城铝模科技有限公司',
    log: LOG_FILE,
    winver: WINVER,
    arch: process.arch,
    compatGpu: COMPAT_GPU,
    electron: process.versions.electron,
    node: process.versions.node
  }));
}

// ---- 开机数据自检：由启动窗口承担「比对云端，有更新才下载」 ----
// 凭据只读同源 localStorage 里用户勾选「记住密码」保存的值，绝不写进配置/代码/新文件。
const wait = ms => new Promise(r => setTimeout(r, ms));
const fmt = n => Number(n || 0).toLocaleString('zh-CN');

function bootState() {
  try { return globalThis.__ERP_BOOT_STATE__ ? globalThis.__ERP_BOOT_STATE__() : null; }
  catch { return null; }
}

/** 用同源空白页读取网页端「记住密码」保存的登录信息；读不到就返回 null */
function readBootCredentials(port) {
  return new Promise(resolve => {
    let done = false, probe = null, timer = null;
    const finish = v => {
      if (done) return; done = true;
      if (timer) clearTimeout(timer);
      try { if (probe && !probe.isDestroyed()) probe.destroy(); } catch {}
      resolve(v);
    };
    timer = setTimeout(() => finish(null), 10000);
    try {
      probe = new BrowserWindow({
        width: 240, height: 160, show: false, frame: false, skipTaskbar: true,
        webPreferences: { nodeIntegration: false, contextIsolation: true }
      });
      probe.webContents.once('did-finish-load', async () => {
        try {
          const raw = await probe.webContents.executeJavaScript(
            "(function(){try{if(localStorage.getItem('dc_remember')==='0')return '';" +
            "return localStorage.getItem('dc_saved_login')||''}catch(e){return ''}})()");
          const s = String(raw || '');
          if (!s) return finish(null);
          const o = JSON.parse(Buffer.from(s, 'base64').toString('utf8'));
          finish(o && o.u && o.p ? { user: String(o.u), password: String(o.p) } : null);
        } catch { finish(null); }
      });
      probe.webContents.once('did-fail-load', () => finish(null));
      probe.loadURL(`http://127.0.0.1:${port}/boot.html`);
    } catch { finish(null); }
  });
}

/** 把自检阶段建立的会话写进程序自身的 cookie，主窗口打开即已登录 */
async function applyBootCookie(port, sid) {
  if (!sid) return;
  try {
    await session.defaultSession.cookies.set({
      url: `http://127.0.0.1:${port}/`,
      name: 'erp_sid', value: sid,
      expirationDate: Math.floor(Date.now() / 1000) + 7 * 24 * 3600
    });
  } catch (e) { console.error('[BOOT] 会话写入失败(主窗口会自行登录):', e.message); }
}

function makeBootPainter(t0) {
  return function (extra) {
    const e = extra || {};
    const s = bootState() || {};
    const prev = lastBootState || {};
    const local = (s.ruku || 0) + (s.chuku || 0);
    // 比对阶段按真实下载进度切换文案：连接 → 比对 → 下载更新
    const inCompare = s.phase === 'compare' && !s.done;
    const downloading = inCompare && s.pages > 4;
    const autoTitle = downloading ? '发现更新，正在下载…'
      : inCompare ? '正在比对本地与云端数据…'
      : prev.title || '正在比对云端数据…';
    const autoDetail = downloading
      ? ('已请求云端 ' + fmt(s.pages) + ' 页 · 累计 ' + fmt(s.rows) + ' 条记录')
      : inCompare ? ('逐条对比中 · 已请求 ' + fmt(s.pages) + ' 页')
      : prev.detail || '逐条对比本地与云端记录，有更新才下载';
    paintBoot({
      phase: e.phase || prev.phase || 'checking',
      title: e.title || autoTitle,
      detail: e.detail || autoDetail,
      stage: e.stage || (downloading ? '下载更新' : inCompare ? '比对数据' : prev.stage || '开机数据自检'),
      percent: e.percent !== undefined ? e.percent : (prev.percent === 100 ? 100 : null),
      local, pages: s.pages || 0,
      elapsed: (Date.now() - t0) / 1000,
      foot: e.foot || (downloading ? '有更新才下载 · 数据会自动写入本机'
        : prev.foot || '本机只读查询 · 有更新才下载，无更新自动进入'),
      pctText: e.pctText || prev.pctText || '',
      skip: true
    });
  };
}

async function runBootCheck(port) {
  const t0 = Date.now();
  const paint = makeBootPainter(t0);
  let timer = null;
  console.log('[BOOT] 开机数据自检开始');

  // 每 300ms 把云端分页请求数 / 本地记录数 / 用时刷新到启动窗口，文案保持不变
  timer = setInterval(() => {
    if (lastBootState && lastBootState.phase === 'done') return;
    paint({});
  }, 300);

  const skipP = new Promise(r => { bootSkipResolve = r; });
  try {
    paint({ phase: 'prepare', title: '正在启动本机服务…', detail: '准备读取本机数据', percent: null });
    const cred = await readBootCredentials(port);

    if (!cred) {
      // 第一次使用：用户还没有登录，此刻本机没有任何凭据有权连厂商云。
      // 启动窗口只做引导、绝不发起云端请求；等用户在主窗口登录后，由服务用他自己的
      // 会话下载一次完整数据，写标记后，第二次启动才会走「比对 / 有更新才下载」。
      console.log('[BOOT] 未保存登录信息，跳过开机比对（首次使用：登录后下载完整数据）');
      paint({ phase: 'skip', title: '首次使用 · 请先登录',
        detail: '登录后用自己的账号下载一次完整数据，下次启动即可自动比对更新',
        stage: '首次使用', percent: null, pctText: '待登录',
        foot: '当前仅有随包历史数据 · 未登录不会连接厂商云' });
      await wait(1300);
    } else {
      paint({ phase: 'login', title: '正在连接厂商云…', detail: '准备比对本地与云端数据', percent: null });
      const check = globalThis.__ERP_BOOT_CHECK__;
      if (!check) throw new Error('自检钩子缺失');

      const checkP = check(cred.user, cred.password).then(v => ({ ...v, __check: true }));
      const timeoutP = wait(BOOT_MAX_WAIT_MS).then(() => ({ __timeout: true }));
      const result = await Promise.race([checkP, timeoutP, skipP.then(() => ({ __skip: true }))]);

      if (result.__timeout) {
        console.log('[BOOT] 自检超过 2 分钟，后台继续同步，先打开主窗口');
        paint({ phase: 'done', title: '云端较慢，正在后台继续同步',
          detail: '已先打开程序，数据会在后台自动补齐', stage: '后台同步中', percent: 100 });
        await wait(600);
      } else if (result.__skip) {
        console.log('[BOOT] 已跳过等待，后台继续同步');
        paint({ phase: 'done', title: '已进入程序，后台继续同步',
          detail: '数据会在后台自动补齐', stage: '后台同步中', percent: 100 });
        await wait(300);
      } else if (!result.ok || result.synced === false) {
        console.log('[BOOT] 云端比对未完成，使用本地数据:', result.message || '上游未响应');
        paint({ phase: 'done', title: '云端暂不可达，使用本地数据',
          detail: '登录后程序会自动重新同步', stage: '离线模式', percent: 100 });
        await wait(1500);
      } else {
        await applyBootCookie(port, result.sid);
        const s = bootState() || {};
        const added = Number(result.added) || 0;
        console.log('[BOOT] 比对完成: 本地 ' + (Number(result.after) || 0) + ' 条, 新增 ' + added +
          ' 条, 云端请求 ' + (result.pages || 0) + ' 页 / ' + (result.downloaded || 0) + ' 行');
        paint({
          phase: 'done',
          title: added > 0 ? ('已下载更新 ' + fmt(added) + ' 条记录') : '数据已是最新',
          detail: added > 0 ? '更新已写入本机，正在打开程序…' : '本地与云端一致，正在打开程序…',
          stage: added > 0 ? '更新完成' : '比对完成',
          percent: 100,
          foot: '入库 ' + fmt(s.ruku) + ' 条 · 出库 ' + fmt(s.chuku) + ' 条'
        });
        await wait(850);
      }
    }
  } catch (e) {
    console.error('[BOOT] 自检异常(不影响使用):', e.message);
    paint({ phase: 'done', title: '云端暂不可达，使用本地数据',
      detail: '登录后会自动重新同步', stage: '离线模式', percent: 100 });
    await wait(1200);
  } finally {
    clearInterval(timer);
    bootSkipResolve = null;
  }

  // 「启动第一个窗口时间长一点」：至少停留 BOOT_MIN_SHOW_MS，状态不会一闪而过
  const rest = BOOT_MIN_SHOW_MS - (Date.now() - t0);
  if (rest > 0) await wait(rest);
  console.log('[BOOT] 自检结束，正在打开主窗口');
  createMainWindow(port);
}

// ---- 启动本地服务：与窗口同一进程 ----
function startService() {
  process.env.ERP_NO_BROWSER = '1';      // 绝不弹系统浏览器
  process.env.ERP_DATA_DIR = USER_DATA;  // 数据快照写用户目录，安装目录保持只读干净
  seedSnapshot();

  globalThis.__ERP_ON_READY__ = (port) => {
    servicePort = port;
    console.log('本地服务就绪: 127.0.0.1:' + port);
    // 先在启动窗口比对 / 下载，完成后自动放行主窗口
    runBootCheck(port);
  };
  globalThis.__ERP_ON_ERROR__ = (msg) => {
    console.error('本地服务启动失败:', msg);
    closeSplash();
    dialog.showErrorBox('鼎城 ERP 启动失败', '本地服务无法启动：' + msg + '\n\n请查看日志：' + LOG_FILE);
    app.quit();
  };

  try {
    require(path.join(WEB_DIR, 'server.js'));
  } catch (e) {
    console.error('加载服务失败', e.stack || e.message);
    globalThis.__ERP_ON_ERROR__(e.message);
  }
}

// 首次启动把随包附带的数据快照放进用户目录，做到打开即有数据、后台再增量同步
function seedSnapshot() {
  try {
    const pre = fs.readdirSync(WEB_DIR).find(n => /^erp-data-.*\.json\.gz$/.test(n));
    if (!pre) return;
    const dest = path.join(USER_DATA, pre);
    if (!fs.existsSync(dest)) fs.copyFileSync(path.join(WEB_DIR, pre), dest);
  } catch (e) { console.error('预置快照失败(不影响使用):', e.message); }
}

// ---- 生命周期 ----
app.whenReady().then(() => {
  buildMenu();
  hookIpc();
  hookDownload();
  showSplash();
  startService();
  // 兜底：服务 20 秒还没就绪才报错；服务已起来时由自检流程自己的 2 分钟上限放行
  setTimeout(() => {
    if (!servicePort) {
      closeSplash();
      dialog.showErrorBox('鼎城 ERP 启动超时', '本地服务未在 20 秒内就绪。\n\n日志：' + LOG_FILE);
      app.quit();
    }
  }, 20000).unref();
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => { quitting = true; closeSplash(); });
app.on('will-quit', () => {
  // 显式关闭 HTTP server，确保端口立刻释放；再给 Electron 400ms 清理后强制收尾
  try { if (globalThis.__ERP_SHUTDOWN__) globalThis.__ERP_SHUTDOWN__(); } catch {}
  setTimeout(() => process.exit(0), 400);
});
