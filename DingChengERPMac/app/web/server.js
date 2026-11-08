// 神机 ERP 库存/出入库查询 —— 本地轻量服务（零依赖，Node 16+/22+ 均可）
// 只做查询，不写入、不修改 ERP 任何数据。
const http = require('node:http');
const https = require('node:https');
const zlib = require('node:zlib');
const fs = require('node:fs');
const path = require('node:path');
const { URL } = require('node:url');
const crypto = require('node:crypto');

// 单文件 EXE（Node SEA）模式：构建脚本会把 index.html / config.json / pwa 资源注入 __ERP_ASSETS__；
// 普通 `node server.js` 模式：照旧从同目录读文件。两种模式共用同一份代码。
const EMBEDDED = globalThis.__ERP_ASSETS__ || null;
function readAppFile(name) {
  if (EMBEDDED && EMBEDDED[name]) return Buffer.from(EMBEDDED[name], 'base64');
  return fs.readFileSync(path.join(__dirname, name));
}
function loadConfig() {
  if (EMBEDDED) {
    // EXE 同目录可放 erp-config.json 覆盖端口等设置，方便换机器部署
    const ext = path.join(path.dirname(process.execPath), 'erp-config.json');
    if (fs.existsSync(ext)) return JSON.parse(fs.readFileSync(ext, 'utf8'));
  }
  return JSON.parse(readAppFile('config.json').toString('utf8'));
}
const cfg = loadConfig();
const BASE = cfg.baseUrl.replace(/\/$/, '');
const GRID = BASE + '/Admin/ashx/GridHandler.ashx';
const LOGIN = BASE + '/admin/ashx/ControlHandle.ashx';

const TABLES = {
  ruku: {
    title: '入库记录', xmlName: 'input_record', dateField: 'rukushijian',
    keywordFields: ['mingcheng', 'daima', 'erp_pinhao', 'beizhu', 'cangku', 'leixing', 'laiyuan_telephone', 'crkxmmc'],
    specFields: ['kuan', 'chang'],
    projectField: 'crkxmmc',
    columns: [
      ['rukushijian', '入库时间', 150], ['leixing', '类型', 140], ['mingcheng', '名称', 130],
      ['daima', '编码', 130], ['spec', '规格', 110], ['cangku', '仓库', 100],
      ['shuliang', '数量', 90], ['shiji_zhongliang', '实际重量', 90],
      ['crkxmmc', '项目', 130],
      ['laiyuan_telephone', '来源', 140], ['beizhu', '备注', 180]
    ]
  },
  chuku: {
    title: '出库记录', xmlName: 'output_record', dateField: 'chukushijian',
    keywordFields: ['mingcheng', 'daima', 'erp_pinhao', 'beizhu', 'cangku', 'leixing', 'laiyuan_telephone', 'crkxmmc'],
    specFields: ['kuan', 'chang'],
    projectField: 'crkxmmc',
    columns: [
      ['chukushijian', '出库时间', 150], ['leixing', '类型', 140], ['mingcheng', '名称', 130],
      ['daima', '编码', 130], ['spec', '规格', 110], ['cangku', '仓库', 100],
      ['shuliang', '数量', 90], ['shiji_zhongliang', '实际重量', 90],
      ['crkxmmc', '项目', 130],
      ['laiyuan_telephone', '来源', 140], ['beizhu', '备注', 180]
    ]
  },
  // 页面已按用户要求移除「冻结记录」入口；此处保留定义，仅在需要恢复时启用
  dongjie: {
    title: '冻结记录', xmlName: 'dongjie', dateField: 'dongjie_shijian',
    keywordFields: ['mingcheng', 'daima', 'xmmc', 'beizhu', 'cangku', 'leixing'],
    specFields: ['kuan', 'chang'],
    projectField: 'xmmc',
    columns: [
      ['dongjie_shijian', '冻结时间', 150], ['xmmc', '项目', 130], ['cangku', '仓库', 100],
      ['leixing', '类型', 140], ['mingcheng', '名称', 130], ['daima', '编码', 130],
      ['spec', '规格(宽×长)', 110], ['shuliang', '数量', 90], ['mianji', '面积', 90],
      ['zhongliang', '重量', 90], ['yonghu', '用户', 110], ['yuanyin', '原因', 140],
      ['beizhu', '备注', 180]
    ]
  }
};

// 第三项为列宽百分比（库存汇总用 table-layout:fixed，保证不出现横向滚动条）
const STOCK_COLUMNS = [
  ['daima', '编码', 8], ['mingcheng', '名称', 19], ['spec', '规格(宽×长)', 17],
  ['leixing', '类型', 28], ['cangku', '仓库', 13], ['stockQty', '库存数量', 15]
];

// 每台设备一个会话：sid -> { cookie, user, login, createdAt }
// 只存内存、进程重启即全部失效；账号密码不写入磁盘，也不出现在日志里。
const sessions = new Map();
const cache = new Map();

function sidFrom(req) {
  const raw = req.headers.cookie || '';
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === 'erp_sid') return part.slice(i + 1).trim();
  }
  return '';
}
function sessionOf(req) {
  const sid = sidFrom(req);
  return sid ? (sessions.get(sid) || null) : null;
}
function dropSession(sid) {
  if (!sid) return;
  sessions.delete(sid);
  // 只清掉本会话的缓存，不影响其它设备
  for (const [k, v] of cache) if (v.sid === sid) cache.delete(k);
  for (const k of jinxiaoCache.keys()) if (k.startsWith(sid + '|')) jinxiaoCache.delete(k);
}
function needLogin(res) { return send(res, 401, { error: '未登录', code: 'NEED_LOGIN' }); }
async function readJson(req, limit = 4096) {
  const chunks = []; let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw Object.assign(new Error('请求体过大'), { code: 413 });
    chunks.push(c);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw Object.assign(new Error('请求体不是合法 JSON'), { code: 400 }); }
}

function esc(v) { return String(v == null ? '' : v).replace(/'/g, "''").replace(/[;\-]{2,}/g, ''); }
function num(v) { const n = Number(v); return Number.isFinite(n) ? n : 0; }

// ERP 把规格拆成 kuan(宽) / chang(长) 两个数值字段，mingcheng 常常为空。
// 所以关键字除了文本字段，还必须匹配规格；并支持 400X2600 / 400*2600 / 400×2600 / 400 2600 等写法。
function keywordClause(qRaw, t) {
  const raw = String(qRaw || '').trim();
  const q = esc(raw);
  const parts = t.keywordFields.map(k => `${k} like '%${q}%'`);
  const spec = t.specFields || ['kuan', 'chang'];

  const m = raw.match(/^(\d+(?:\.\d+)?)\s*[xX*×＊/\-\s]\s*(\d+(?:\.\d+)?)$/);
  if (m) {
    const a = Number(m[1]), b = Number(m[2]);
    // 宽长可能写反，两个方向都匹配
    parts.push(`((kuan = ${a} and chang = ${b}) or (kuan = ${b} and chang = ${a}))`);
    return '(' + parts.join(' or ') + ')';
  }
  if (/^\d+(?:\.\d+)?$/.test(raw)) {
    const n = Number(raw);
    parts.push(...spec.map(k => `${k} = ${n}`));
    parts.push(...spec.map(k => `${k} like '%${q}%'`));
  }
  return '(' + parts.join(' or ') + ')';
}

function buildCon(type, f) {
  const t = TABLES[type];
  const parts = [`danwei = '${esc(cfg.company)}'`];
  if (f.start) parts.push(`${t.dateField} >= '${esc(f.start)} 00:00:00'`);
  if (f.end) parts.push(`${t.dateField} <= '${esc(f.end)} 23:59:59'`);
  if (f.q) parts.push(keywordClause(f.q, t));
  if (f.cangku) parts.push(`cangku like '%${esc(f.cangku)}%'`);
  if (f.leixing) parts.push(`leixing like '%${esc(f.leixing)}%'`);
  if (f.xmmc) parts.push(`${t.projectField} like '%${esc(f.xmmc)}%'`);
  return parts.join(' and ');
}

// 用 Node 内置 http/https 发上游请求，不依赖全局 fetch / AbortSignal.timeout。
// 这样同一份代码既能跑 Node 22 的单文件 EXE，也能跑 Win7 上的 Node 16。
// keep-alive 连接复用：省掉每次请求的 TCP+TLS 握手（同步全量时收益明显）。
const agents = {};
function agentFor(proto) {
  if (!agents[proto]) {
    const lib = proto === 'https:' ? https : http;
    agents[proto] = new lib.Agent({ keepAlive: true, maxSockets: 8, keepAliveMsecs: 30000 });
  }
  return agents[proto];
}
function httpGet(urlString, timeout, cookie) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlString);
    const req = (u.protocol === 'https:' ? https : http).get({
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      agent: agentFor(u.protocol),
      headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': BASE + '/admin/index.html',
        ...(cookie ? { Cookie: cookie } : {})
      }
    }, res => {
      let text = '';
      res.setEncoding('utf8');
      // 上游中断连接是常态（网络抖动/服务器超时），必须有 error 监听，否则进程直接崩溃
      res.on('error', () => { try { req.destroy(); } catch {} reject(new Error('上游连接中断')); });
      res.on('data', chunk => { text += chunk; });
      res.on('end', () => resolve(text));
    });
    req.setTimeout(timeout, () => req.destroy(new Error('上游请求超时')));
    req.on('error', reject);
  });
}

async function fetchJson(url, timeout = 25000, cookie = '') {
  const text = await httpGet(url, timeout, cookie);
  if (!text.trim()) return {};
  try { return JSON.parse(text); } catch { return {}; }
}

// ===================== 本地数据仓库（电脑端提速） =====================
// 全量同步入库/出库历史到本机，查询/搜索/翻页/库存全部本地毫秒级计算。
// 登录后后台对比厂商云：每表 1 次请求对总数 → 无差异秒结束；有差异增量拉取；异常全量兜底。
// 数据是用户自有业务数据；删除数据文件即回到纯云端模式。
function dataDir() { return process.env.ERP_DATA_DIR || (EMBEDDED ? path.dirname(process.execPath) : __dirname); }
const companyHash = crypto.createHash('md5').update(String(cfg.company)).digest('hex').slice(0, 8);
const dataFile = path.join(dataDir(), 'erp-data-' + companyHash + '.json.gz');
const store = { ruku: [], chuku: [], ready: false, syncing: false, syncedAt: 0, lastNew: 0 };

// 启动即加载本地数据（不依赖登录）
try {
  if (fs.existsSync(dataFile)) {
    const j = JSON.parse(zlib.gunzipSync(fs.readFileSync(dataFile)).toString('utf8'));
    if (Array.isArray(j.ruku) && Array.isArray(j.chuku)) {
      store.ruku = j.ruku; store.chuku = j.chuku;
      store.syncedAt = j.syncedAt || 0;
      store.ready = (store.ruku.length + store.chuku.length) > 0;
      console.log(`[ERP] 已加载本地数据: 入库 ${store.ruku.length} 条 / 出库 ${store.chuku.length} 条`);
    }
  }
} catch (e) { console.error('[ERP] 本地数据加载失败(将重新同步):', e.message); }

let saveTimer = null;
function saveStore() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try {
      const buf = zlib.gzipSync(Buffer.from(JSON.stringify({ ruku: store.ruku, chuku: store.chuku, syncedAt: store.syncedAt })));
      const tmp = dataFile + '.tmp';
      fs.writeFileSync(tmp, buf);
      fs.renameSync(tmp, dataFile);
    } catch (e) { console.error('[ERP] 本地数据保存失败:', e.message); }
  }, 1500);
}

// 记录唯一键：优先厂商 ID 号，退化到 时间+数量+编码 组合
function rowKey(r) {
  const id = r.ID != null ? String(r.ID) : (r.id != null ? String(r.id) : '');
  if (id) return id;
  return [r.rukushijian || r.chukushijian || '', r.daima || '', r.kuan || '', r.chang || '', r.shuliang || ''].join('|');
}

// 行内容指纹：所有字段值参与对比。total 不变但记录被修改（改数量/备注/仓库等）也能发现
function rowFingerprint(r) {
  const keys = Object.keys(r).sort();
  let s = '';
  for (const k of keys) s += k + '\u0001' + (r[k] == null ? '' : String(r[k])) + '\u0002';
  return s;
}

// 全量拉取。opts.merge=true 时与本地逐条 diff 合并：新增补、修改覆盖、缺失删；
// 若分页拉取不完整（fetched 明显少于 total）则保守处理——只补/覆盖、不删，避免网络抖动导致误删。
async function fullSyncTable(type, con, cookie, total, opts = {}) {
  const size = 500;
  const pages = Math.min(Math.ceil((total || 0) / size) + 2, 600);
  const first = await gridRaw(type, 1, size, con, cookie);
  const rows = first.rows.slice();
  for (let i = 2; i <= pages; i += 4) {
    const batch = [];
    for (let p = i; p < i + 4 && p <= pages; p++) batch.push(p);
    const res = await Promise.all(batch.map(p => gridRaw(type, p, size, con, cookie).catch(() => ({ rows: [] }))));
    for (const j of res) rows.push(...j.rows);
  }
  const seen = new Set(); const out = [];
  for (const r of rows) { const k = rowKey(r); if (!seen.has(k)) { seen.add(k); out.push(r); } }
  if (opts.merge) {
    const fetchedOk = out.length >= (num(total) || out.length) * 0.98;   // 拉取完整度保护
    const next = new Map();
    for (const r of out) next.set(rowKey(r), r);
    if (fetchedOk) {
      store[type] = [...next.values()];          // 以云端为准：新增+修改覆盖+本地多余删除
    } else {
      const cur = new Map(store[type].map(r => [rowKey(r), r]));
      for (const [k, r] of next) cur.set(k, r);  // 不完整：只 upsert，不删
      store[type] = [...cur.values()];
    }
  } else {
    store[type] = out;
  }
}

async function syncTable(type, con, cookie, opts = {}) {
  const size = 500;
  const first = await gridRaw(type, 1, size, con, cookie);
  const total = num(first.total);
  const byKey = new Map(store[type].map(r => [rowKey(r), r]));
  const knownKeys = new Set(byKey.keys());

  // 第一页整行值对比（不只比 key）：最近被修改的记录在分钟级复查内就能发现并覆盖
  const firstPageNew = first.rows.filter(r => !knownKeys.has(rowKey(r)));
  const firstPageChanged = first.rows.filter(r => {
    const l = byKey.get(rowKey(r));
    return l && rowFingerprint(l) !== rowFingerprint(r);
  });

  // 快速对比：总数一致且第一页整行值全部一致 → 无差异
  if (store[type].length === total && firstPageNew.length === 0 && firstPageChanged.length === 0) return 0;

  // 全量校验模式（定时兜底）：逐条 diff，抓一切修改/删除
  if (opts.full) {
    await fullSyncTable(type, con, cookie, total, { merge: true });
    return store[type].length;
  }

  if (firstPageNew.length > 0 || firstPageChanged.length > 0) {
    // 增量：按时间倒序翻页；新记录补入、已知但值不同的记录覆盖；
    // 连续 2 页全部已知才停（防同秒批量插入跨页漏抓），上限 40 页
    const idxByKey = new Map(store[type].map((r, i) => [rowKey(r), i]));
    const seen = new Set(knownKeys);
    const maxPages = Math.min(40, Math.ceil(total / size) || 1);
    let allKnownStreak = 0;
    for (let p = 1; p <= maxPages; p++) {
      const j = p === 1 ? first : await gridRaw(type, p, size, con, cookie).catch(() => ({ rows: [] }));
      for (const r of j.rows) {
        const k = rowKey(r);
        if (seen.has(k)) {
          const idx = idxByKey.get(k);
          if (idx >= 0 && rowFingerprint(store[type][idx]) !== rowFingerprint(r)) store[type][idx] = r;
        } else {
          seen.add(k); idxByKey.set(k, store[type].length); store[type].push(r);
        }
      }
      allKnownStreak = (j.rows.length > 0 && j.rows.every(r => seen.has(rowKey(r)))) ? allKnownStreak + 1 : 0;
      if (allKnownStreak >= 2) break;
    }
  }
  // 数量仍对不齐（上游删过数据等）→ 全量兜底
  if (store[type].length !== total) await fullSyncTable(type, con, cookie, total, { merge: true });
  return store[type].length;
}

// 双频同步：每 1 分钟增量复查（1 请求/表，抓新增+最近修改）；每 6 小时自动升级为
// 全量静默校验（约 21 秒，逐条 diff：抓一切修改/删除/残留）。服务启动后首次复查即做一次全量校验。
const FULL_CHECK_MS = 6 * 60 * 60 * 1000;
let lastFullCheck = 0;

async function syncAll(reason, opts = {}) {
  if (store.syncing) return;
  const sess = [...sessions.values()].find(s => s.cookie);
  if (!sess) return;
  store.syncing = true;
  try {
    const full = opts.full || (Date.now() - lastFullCheck > FULL_CHECK_MS);
    store.lastNew = 0;
    const before = store.ruku.length + store.chuku.length;
    const con = `danwei = '${esc(cfg.company)}'`;
    await Promise.all([syncTable('ruku', con, sess.cookie, { full }), syncTable('chuku', con, sess.cookie, { full })]);
    if (full) lastFullCheck = Date.now();
    store.syncedAt = Date.now();
    store.ready = (store.ruku.length + store.chuku.length) > 0;
    store.lastNew = Math.max(0, store.ruku.length + store.chuku.length - before);
    saveStore();
    console.log(`[ERP] 后台同步完成(${reason}${full ? '/全量校验' : ''}): 入库 ${store.ruku.length} 条 / 出库 ${store.chuku.length} 条` +
      (store.lastNew ? `，新增 ${store.lastNew} 条` : '，无差异'));
  } catch (e) {
    console.error('[ERP] 后台同步失败(不影响查询):', e.message);
  } finally {
    store.syncing = false;
  }
}

// 本地筛选：复刻远程 con 的语义（日期范围 / 关键字含来源项目 / 宽×长与纯数字规格 / 仓库类型项目 like）
function like(v, pat) { return String(v == null ? '' : v).toLowerCase().includes(String(pat).toLowerCase()); }
function localRowsFiltered(type, f) {
  const t = TABLES[type];
  const start = f.start ? f.start + ' 00:00:00' : '';
  const end = f.end ? f.end + ' 23:59:59' : '';
  const q = String(f.q || '').trim();
  const m = q.match(/^(\d+(?:\.\d+)?)\s*[xX*×＊/\-\s]\s*(\d+(?:\.\d+)?)$/);
  const isNum = /^\d+(?:\.\d+)?$/.test(q);
  const rows = store[type].filter(r => {
    const d = String(r[t.dateField] || '');
    if (start && d < start) return false;
    if (end && d > end) return false;
    if (f.cangku && !like(r.cangku, f.cangku)) return false;
    if (f.leixing && !like(r.leixing, f.leixing)) return false;
    if (f.xmmc && !like(r[t.projectField], f.xmmc)) return false;
    if (q) {
      let hit = t.keywordFields.some(k => like(r[k], q));
      if (!hit && m) {
        const a = Number(m[1]), b = Number(m[2]);
        hit = (num(r.kuan) === a && num(r.chang) === b) || (num(r.kuan) === b && num(r.chang) === a);
      } else if (!hit && isNum) {
        hit = num(r.kuan) === Number(q) || num(r.chang) === Number(q);
      }
      if (!hit) return false;
    }
    return true;
  });
  return rows.sort((a, b) => String(b[t.dateField] || '').localeCompare(String(a[t.dateField] || '')));
}

function localQuery(type, f) {
  const all = localRowsFiltered(type, f);
  const page = Math.max(1, parseInt(f.page) || 1);
  const size = Math.min(5000, Math.max(1, parseInt(f.rows) || 20));
  return {
    total: all.length,
    rows: decorate(all.slice((page - 1) * size, page * size)),
    syncedAt: store.syncedAt
  };
}

// 用登录框输入的账号密码登录；单位固定取 config.company。
// 返回登录结果，不写任何全局状态；登录失败时不产生上游 cookie。
async function doLogin(user, password) {
  const q = new URLSearchParams({
    method: 'UserLogin', xingming: user, danwei: cfg.company,
    mima: password, ip: '', mac: '', sjmsver: '20250821000009'
  });
  let j;
  try {
    j = await fetchJson(LOGIN + '?' + q, 15000, '');
  } catch (e) {
    return { ok: false, message: '连接失败: ' + e.message, permissions: '', cookie: '' };
  }
  // 注意：厂商接口无论账号密码对错都返回 state:'success'，
  // 真正的成功标志是 message 含「成功」；失败时 message2 会给出具体原因。
  const rawMsg = String(j.message || '');
  const ok = j.state === 'success' && /成功/.test(rawMsg);
  const detail = String(j.message2 || '').trim();
  const message = ok
    ? (rawMsg || '已连接')
    : (detail && detail !== rawMsg ? detail : (rawMsg || '账号或密码错误'));
  // telephone 用厂商返回的值（与个人密码不一定相同），拿不到时回退到输入的密码
  const telephone = String(j.telephone || '') || password;
  const cookie = ok ? [
    'sjmslvmo_danwei=' + encodeURIComponent(cfg.company),
    'sjmslvmo_username=' + encodeURIComponent(user),
    'sjmslvmo_telephone=' + encodeURIComponent(telephone)
  ].join('; ') : '';
  return { ok, message, permissions: ok ? (j.message1 || '') : '', cookie };
}

// C槽类型规格：类型含「C槽」时按编码拼三参数（宽度左=kuan、宽度右=chang、长度1=changdu1、长度2=changdu2）。
// IC→IC长1；ICA/SNTL→ICA长1；SNTR→IC长1A；SNTT→ICA长1A；SCU→SCU长1(+长2)。缺段连同「+」省略。
function cslotSpec(r) {
  if (!String(r.leixing || '').includes('C槽')) return '';
  const daima = String(r.daima || '').trim().toUpperCase();
  const c1 = num(r.changdu1), c2 = num(r.changdu2);
  if (!c1) return '';
  const w = `${num(r.kuan)}×${num(r.chang)}`;
  if (daima === 'IC') return `${w}IC${c1}`;
  if (daima === 'ICA' || daima === 'SNTL') return `${w}ICA${c1}`;
  if (daima === 'SNTR') return `${w}IC${c1}A`;
  if (daima === 'SNTT') return `${w}ICA${c1}A`;
  if (daima === 'SCU') return c2 ? `${w}SCU${c1}+${c2}` : `${w}SCU${c1}`;
  return '';
}
// 字母连接类：只看编码（精确匹配），规格=宽度左+编码+宽度右，无长度段。
// P平板 / FP拉片平板 / K板 / EB单斜龙骨 / BP·BPP·CPPP·CPP支撑BB条 / PT平板 / MB双斜龙骨 / PS飞机板
const LETTER_CODES = new Set(['P', 'FP', 'K', 'EB', 'BP', 'BPP', 'CPPP', 'CPP', 'PT', 'MB', 'PS']);
function letterSpec(r) {
  const daima = String(r.daima || '').trim().toUpperCase();
  if (!LETTER_CODES.has(daima)) return '';
  const w1 = num(r.kuan), w2 = num(r.chang);
  if (!w1 || !w2) return '';
  return `${w1}${daima}${w2}`;
}
// 统一规格出口：C槽规则 → 字母连接类 → 兜底宽×长。出入库与库存汇总共用。
function rowSpec(r) {
  return cslotSpec(r) || letterSpec(r) || ((num(r.kuan) || num(r.chang)) ? `${num(r.kuan)}×${num(r.chang)}` : '');
}
function decorate(rows) {
  return rows.map(r => ({ ...r, spec: rowSpec(r) }));
}

async function grid(type, { page = 1, rows = 20, sort, order = 'desc', con }, cookie = '') {
  const t = TABLES[type];
  const q = new URLSearchParams({
    method: 'getGridData', xmlName: t.xmlName, page: String(page), rows: String(rows),
    sort: sort || t.dateField, order, con
  });
  const j = await fetchJson(GRID + '?' + q, 25000, cookie);
  return { total: num(j.total), rows: decorate(Array.isArray(j.rows) ? j.rows : []) };
}

async function gridRaw(type, page, rows, con, cookie = '') {
  const t = TABLES[type];
  const q = new URLSearchParams({
    method: 'getGridData', xmlName: t.xmlName, page: String(page), rows: String(rows),
    sort: t.dateField, order: 'desc', con
  });
  const j = await fetchJson(GRID + '?' + q, 30000, cookie);
  return { total: num(j.total), rows: Array.isArray(j.rows) ? j.rows : [] };
}

async function fetchAll(type, con, limit, cookie = '') {
  const size = cfg.stockPageSize || 500;
  const first = await gridRaw(type, 1, size, con, cookie);
  let rows = first.rows.slice(0, limit);
  const pages = Math.min(Math.ceil(first.total / size), Math.ceil(limit / size));
  const jobs = [];
  for (let p = 2; p <= pages; p++) jobs.push(p);
  const conc = cfg.stockConcurrency || 4;
  for (let i = 0; i < jobs.length; i += conc) {
    const batch = jobs.slice(i, i + conc);
    const res = await Promise.all(batch.map(p => gridRaw(type, p, size, con, cookie).catch(() => ({ rows: [] }))));
    for (const r of res) rows = rows.concat(r.rows);
    if (rows.length >= limit) break;
  }
  return { rows: rows.slice(0, limit), total: first.total };
}

// 本地库存汇总：两表筛选后直接累加，毫秒级（远程路径保留为 fallback）
function localStock(f) {
  const a = localRowsFiltered('ruku', f);
  const b = localRowsFiltered('chuku', f);
  const map = new Map();
  const add = r => {
    // C槽 的 changdu1/changdu2 必须进分组键，否则同宽长不同长度的 C槽 会被错误合并
    const k = [r.daima, r.mingcheng, num(r.kuan), num(r.chang), num(r.changdu1), num(r.changdu2), r.leixing, r.cangku].join('|');
    if (!map.has(k)) map.set(k, {
      daima: r.daima || '', mingcheng: r.mingcheng || '', leixing: r.leixing || '',
      cangku: r.cangku || '', spec: rowSpec(r),
      stockQty: 0
    });
    map.get(k).stockQty += num(r.shuliang);
  };
  a.forEach(add); b.forEach(add);
  const cmp = new Intl.Collator('zh-CN', { numeric: true }).compare;
  const rows = [...map.values()].sort((a, b) =>
    cmp(a.leixing || '\uffff', b.leixing || '\uffff') ||
    cmp(a.daima || '\uffff', b.daima || '\uffff') ||
    cmp(a.spec || '', b.spec || '') ||
    cmp(a.mingcheng || '', b.mingcheng || '') ||
    cmp(a.cangku || '', b.cangku || '')
  );
  return {
    rows, columns: STOCK_COLUMNS, total: rows.length,
    scanned: { ruku: a.length, chuku: b.length },
    available: { ruku: a.length, chuku: b.length },
    truncated: false, syncedAt: store.syncedAt
  };
}

async function stock(f, cookie = '', sid = '') {
  if (store.ready) return localStock(f);
  // 缓存按会话隔离，避免不同账号之间串数据
  const key = sid + '|' + JSON.stringify(f);
  const hit = cache.get(key);
  if (hit && Date.now() - hit.t < (cfg.cacheMinutes || 10) * 60000) return hit.v;
  // 上限由 config 控制；默认配到 50000，可覆盖全部历史流水（约 3.9 万入库 + 3.1 万出库），
  // 这样「库存数量」是全历史累计而不是某个区间的收发差。
  const hasFilter = !!(f.q || f.cangku || f.leixing || f.xmmc || f.start || f.end);
  const limit = hasFilter ? (cfg.stockMaxRowsFiltered || 50000) : (cfg.stockMaxRowsPerSide || 50000);
  const [a, b] = await Promise.all([
    fetchAll('ruku', buildCon('ruku', f), limit, cookie),
    fetchAll('chuku', buildCon('chuku', f), limit, cookie)
  ]);
  const map = new Map();
  const add = r => {
    // 与 localStock 同键：changdu1/changdu2 进分组键，spec 走统一 rowSpec
    const k = [r.daima, r.mingcheng, num(r.kuan), num(r.chang), num(r.changdu1), num(r.changdu2), r.leixing, r.cangku].join('|');
    if (!map.has(k)) map.set(k, {
      daima: r.daima || '', mingcheng: r.mingcheng || '', leixing: r.leixing || '',
      cangku: r.cangku || '', spec: rowSpec(r),
      stockQty: 0
    });
    // 入库为正、出库记录本身为负，直接累加即净库存数量；冲销记录会自动冲回
    map.get(k).stockQty += num(r.shuliang);
  };
  a.rows.forEach(add);
  b.rows.forEach(add);
  // 同类型的物料聚在一起，组内按编码 → 规格 → 名称 → 仓库；不再按库存数量排序。
  // leixing 形如 "01^01.标准库＆平板"，按它排序时同一级库（如标准库）自然连续。
  const cmp = new Intl.Collator('zh-CN', { numeric: true }).compare;
  const rows = [...map.values()].sort((a, b) =>
    cmp(a.leixing || '\uffff', b.leixing || '\uffff') ||
    cmp(a.daima || '\uffff', b.daima || '\uffff') ||
    cmp(a.spec || '', b.spec || '') ||
    cmp(a.mingcheng || '', b.mingcheng || '') ||
    cmp(a.cangku || '', b.cangku || '')
  );
  const v = {
    rows, columns: STOCK_COLUMNS, total: rows.length,
    scanned: { ruku: a.rows.length, chuku: b.rows.length },
    available: { ruku: a.total, chuku: b.total },
    truncated: a.total > a.rows.length || b.total > b.rows.length
  };
  cache.set(key, { t: Date.now(), v, sid });
  return v;
}

// ===================== 进销存动态表（厂商云实时取） =====================
// 每天一行的各仓库收发存汇总，全历史仅几百行，直接实时调厂商接口 + 60 秒会话级缓存，
// 无需本地全量同步。同一份 ControlHandle.ashx，带登录 cookie 更稳妥。
const JINXIAO_CACHE_MS = 60 * 1000;
const jinxiaoCache = new Map();   // key: sid|start|end -> { t, v }
async function jinxiaoData(start, end, cookie, sid = '') {
  const key = sid + '|' + (start || '') + '|' + (end || '');
  const hit = jinxiaoCache.get(key);
  if (hit && Date.now() - hit.t < JINXIAO_CACHE_MS) return hit.v;
  const q = new URLSearchParams({
    method: 'jinxiaocun_dongtai', danwei: cfg.company,
    StartDate: start || '', EndDate: end || '', sjmsver: '20250821000009'
  });
  const j = await fetchJson(LOGIN + '?' + q, 25000, cookie);
  if (!Array.isArray(j.rows)) throw new Error('厂商云未返回进销动态数据');
  const v = { total: num(j.total), rows: j.rows };
  jinxiaoCache.set(key, { t: Date.now(), v });
  // 缓存只留最近 40 个键，防止长期运行下内存缓慢增长
  if (jinxiaoCache.size > 40) {
    const oldest = [...jinxiaoCache.entries()].sort((a, b) => a[1].t - b[1].t)[0];
    if (oldest) jinxiaoCache.delete(oldest[0]);
  }
  return v;
}

// PWA 静态资源（可安装到手机/平板桌面），无需登录即可访问
const PWA_FILES = {
  '/boot.html': ['boot.html', 'text/html; charset=utf-8'],
  '/favicon.ico': ['favicon.ico', 'image/x-icon'],
  '/manifest.webmanifest': ['manifest.webmanifest', 'application/manifest+json; charset=utf-8'],
  '/sw.js': ['sw.js', 'application/javascript; charset=utf-8'],
  '/apple-touch-icon.png': ['apple-touch-icon.png', 'image/png'],
  '/icon-32.png': ['icon-32.png', 'image/png'],
  '/icon-64.png': ['icon-64.png', 'image/png'],
  '/icon-192.png': ['icon-192.png', 'image/png'],
  '/icon-512.png': ['icon-512.png', 'image/png']
};

function send(res, code, body, type = 'application/json; charset=utf-8', extraHeaders = {}) {
  try {
    if (res.writableEnded || res.destroyed) return;
    res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', ...extraHeaders });
    res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  } catch { /* 浏览器已断开（如刷新页面），忽略 */ }
}

const server = http.createServer(async (req, res) => {
  // 浏览器刷新/离开页面会中断请求，必须吞掉这类流错误，否则服务进程会退出
  req.on('error', () => {});
  res.on('error', () => {});
  const u = new URL(req.url, 'http://127.0.0.1');
  const f = Object.fromEntries(u.searchParams);
  try {
    const sid = sidFrom(req);
    const sess = sessionOf(req);

    if (['/', '/index.html', '/m.html', '/m'].includes(u.pathname)) {
      return send(res, 200, readAppFile('index.html'), 'text/html; charset=utf-8');
    }
    const pwa = PWA_FILES[u.pathname];
    if (pwa) {
      try {
        return send(res, 200, readAppFile('pwa/' + pwa[0]), pwa[1], { 'Cache-Control': 'public, max-age=86400' });
      } catch { return send(res, 404, { error: 'not found' }); }
    }
    if (u.pathname === '/api/meta') {
      // 未登录也返回：公司名与类型下拉供登录框和页面初始化使用，不含任何凭证
      return send(res, 200, {
        company: cfg.company,
        loggedIn: !!sess,
        user: sess ? sess.user : '',
        message: sess ? sess.login.message : '未登录',
        officialStockUrl: BASE + '/admin/view/Stock_RealTime.html?dizhilan_danwei=' + encodeURIComponent(cfg.company),
        tables: Object.fromEntries(Object.entries(TABLES).map(([k, v]) => [k, { title: v.title, columns: v.columns }])),
        typeOptions: cfg.typeOptions || [],
        typeOptionsWithData: cfg.typeOptionsWithData || [],
        exportMaxRows: cfg.exportMaxRows || 5000,
        dataReady: store.ready,
        syncing: store.syncing,
        syncPages: (globalThis.__ERP_SYNC_PROGRESS__ || {}).pages || 0,
        syncRows: (globalThis.__ERP_SYNC_PROGRESS__ || {}).rows || 0,
        syncLocal: store.ruku.length + store.chuku.length,
        firstSync: !!(globalThis.__ERP_SYNC_PROGRESS__ || {}).first && !!(globalThis.__ERP_SYNC_PROGRESS__ || {}).active,
        fullDone: desktopFullDone,
        syncedAt: store.syncedAt,
        lastNew: store.lastNew
      });
    }
    if (u.pathname === '/api/login') {
      if (req.method !== 'POST') return send(res, 405, { error: '请用 POST', code: 'BAD_METHOD' });
      if (!/application\/json/i.test(req.headers['content-type'] || ''))
        return send(res, 415, { error: '需要 application/json', code: 'BAD_CONTENT_TYPE' });
      let body;
      try { body = await readJson(req); }
      catch (e) { return send(res, e.code || 400, { error: e.message, code: 'BAD_BODY' }); }
      const data = (body && typeof body === 'object') ? body : {};
      const name = String(data.user == null ? '' : data.user).trim();
      const pass = String(data.password == null ? '' : data.password);
      if (!name || !pass) return send(res, 400, { error: '请填写账号和密码', code: 'BAD_FIELDS' });
      if (name.length > 64 || pass.length > 128) return send(res, 400, { error: '账号或密码过长', code: 'BAD_FIELDS' });
      const r = await doLogin(name, pass);
      if (!r.ok) return send(res, 401, { error: r.message, code: 'LOGIN_FAILED' });
      const newSid = crypto.randomBytes(24).toString('base64url');
      sessions.set(newSid, {
        cookie: r.cookie, user: name,
        login: { ok: true, message: r.message, permissions: r.permissions },
        createdAt: Date.now()
      });
      if (sid && sid !== newSid) dropSession(sid);   // 同浏览器换账号：清旧会话与旧缓存
      syncAll('login').catch(() => {});              // 登录后后台无感同步，不阻塞响应
      return send(res, 200, { ok: true, user: name, message: r.message }, undefined,
        { 'Set-Cookie': `erp_sid=${newSid}; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800` });
    }
    if (u.pathname === '/api/logout') {
      dropSession(sid);
      return send(res, 200, { ok: true }, undefined,
        { 'Set-Cookie': 'erp_sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0' });
    }
    if (u.pathname === '/api/query') {
      if (!sess) return needLogin(res);
      const type = f.type && TABLES[f.type] ? f.type : 'ruku';
      const page = Math.max(1, parseInt(f.page) || 1);
      const rows = Math.min(5000, Math.max(1, parseInt(f.rows) || 20));
      const con = buildCon(type, f);
      // 本地仓库就绪 → 毫秒级本地查询；未就绪 → 回退远程实时查询
      const data = store.ready ? localQuery(type, f) : await grid(type, { page, rows, con }, sess.cookie);
      return send(res, 200, { ...data, columns: TABLES[type].columns, type, con });
    }
    if (u.pathname === '/api/stock') {
      if (!sess) return needLogin(res);
      return send(res, 200, await stock(f, sess.cookie, sid));
    }
    if (u.pathname === '/api/jinxiao') {
      if (!sess) return needLogin(res);
      // 只接受合法日期格式，防止把奇怪参数透传给厂商云
      const start = /^\d{4}-\d{2}-\d{2}$/.test(f.start || '') ? f.start : '';
      const end = /^\d{4}-\d{2}-\d{2}$/.test(f.end || '') ? f.end : '';
      return send(res, 200, await jinxiaoData(start, end, sess.cookie, sid));
    }
    send(res, 404, { error: 'not found' });
  } catch (e) {
    // 不打印请求 URL / 请求体，避免把凭证写进日志
    console.error('[ERP] 请求异常:', e.message);
    send(res, 500, { error: e.message || String(e) });
  }
});

server.on('clientError', (err, socket) => {
  try { socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); } catch {}
});

// 进程级兜底：任何漏网的异步错误只记日志，绝不退出服务。
// 之前没有这道防线，一次上游断线/浏览器刷新就可能让整个服务挂掉，
// 表现为页面刷新或过一会儿后所有请求报「Failed to fetch」。
process.on('uncaughtException', e => {
  console.error('[ERP] 已捕获异常(服务继续运行):', e && e.message);
});
process.on('unhandledRejection', e => {
  console.error('[ERP] 已捕获Promise异常(服务继续运行):', (e && e.message) || e);
});

// 不再在启动时自动登录：由网页登录框输入账号密码后创建会话
const HOST = cfg.host || '127.0.0.1';
let port = Number(cfg.port) || 8788;
let tries = 0;
const maxTries = 20;   // 端口占用自动顺延，避免和已有服务打架
server.on('error', e => {
  if (e.code === 'EADDRINUSE' && tries < maxTries) {
    tries++; port++;
    console.log(`[ERP] 端口 ${port - 1} 已被占用，改用 ${port}`);
    server.listen(port, HOST);
  } else {
    console.error('[ERP] 启动失败:', e.message);
    process.exitCode = 1;
    if (globalThis.__ERP_ON_ERROR__) globalThis.__ERP_ON_ERROR__(e.message);
  }
});
// 每 5 分钟后台静默复查一次厂商云差异（有会话才查；快速对比每表仅 1 个请求）
// 每 1 分钟后台静默复查：无差异 1 请求/表秒结束；有差异只增量拉新记录；仅上游删数据等异常才全量兜底
setInterval(() => { syncAll('定时').catch(() => {}); }, Number(process.env.ERP_SYNC_INTERVAL_MS) || 60 * 1000).unref();

server.listen(port, HOST, () => {
  if (globalThis.__ERP_ON_READY__) globalThis.__ERP_ON_READY__(port);
  console.log('');
  console.log('  鼎城 ERP 库存查询  ·  江西鼎城铝模科技有限公司');
  console.log(`  本机服务: http://127.0.0.1:${port}/  （本程序自己直连厂商云）`);
  console.log('  手机 / 平板请用 APP：APP 自带同样的本机服务，无需连接这台电脑');
  console.log('  关闭此窗口即停止服务');
  console.log('');
  // EXE 版默认打开浏览器；绿色文件夹版由 start.bat 设 ERP_OPEN_BROWSER=1 打开
  if (!process.env.ERP_NO_BROWSER && (EMBEDDED || process.env.ERP_OPEN_BROWSER)) {
    require('node:child_process').exec(`start "" "http://127.0.0.1:${port}/"`, { windowsHide: true }, () => {});
  }
});

// 桌面版退出钩子：关闭窗口后释放端口并同步落盘
globalThis.__ERP_SHUTDOWN__ = function(){
  try { server.close(); } catch(e){}
  try {
    clearTimeout(saveTimer);
    const buf = zlib.gzipSync(Buffer.from(JSON.stringify({ ruku: store.ruku, chuku: store.chuku, syncedAt: store.syncedAt })));
    fs.writeFileSync(dataFile + ".tmp", buf);
    fs.renameSync(dataFile + ".tmp", dataFile);
  } catch(e) {}
};

// ===== 桌面版首次使用逻辑（只在构建产物里注入，erp-web/server.js 源文件零改动） =====
// 第一次使用软件时用户还没登录，开机自检绝不能连厂商云；等用户在主窗口登录后，
// 用他自己的会话强制下载一次完整数据，写完标记，以后每次启动才走「快速比对 / 有更新才下载」。
const DESKTOP_FULL_FLAG = path.join(dataDir(), '.erp-fullsync-done');
let desktopFullDone = false;
try { desktopFullDone = fs.existsSync(DESKTOP_FULL_FLAG); } catch (e) {}
// 跨重启沿用上次同步时间：本机已完成全量下载后，不再每次开机整库重下
lastFullCheck = desktopFullDone ? (store.syncedAt || 0) : 0;
globalThis.__ERP_SYNC_PROGRESS__ = {
  active: false, first: false, pages: 0, rows: 0, startedAt: 0, doneAt: 0
};
const desktopOrigSyncAll = syncAll;
syncAll = async function (reason, opts) {
  const p = globalThis.__ERP_SYNC_PROGRESS__;
  const first = !desktopFullDone && reason === 'login';
  if (store.syncing) return desktopOrigSyncAll(reason, opts);
  p.active = true; p.first = first; p.pages = 0; p.rows = 0;
  p.startedAt = Date.now(); p.doneAt = 0;
  const raw = gridRaw;
  gridRaw = async function () {
    p.pages++;
    const r = await raw.apply(null, arguments);
    p.rows += (r && Array.isArray(r.rows)) ? r.rows.length : 0;
    return r;
  };
  try {
    const out = await desktopOrigSyncAll(reason, first ? { ...(opts || {}), full: true } : opts);
    if (first && store.ready && store.syncedAt >= p.startedAt) {
      try { fs.writeFileSync(DESKTOP_FULL_FLAG, String(Date.now())); } catch (e) {}
      desktopFullDone = true;
      console.log('[ERP] 首次登录已下载完整数据，后续启动改为增量比对');
    }
    return out;
  } finally {
    gridRaw = raw;
    p.active = false; p.doneAt = Date.now();
  }
};

// ===== 桌面版开机自检钩子（只读状态 + 复用现有登录/同步逻辑） =====
globalThis.__ERP_BOOT_PROGRESS__ = null;
globalThis.__ERP_BOOT_STATE__ = function () {
  const b = globalThis.__ERP_BOOT_PROGRESS__;
  return {
    ready: store.ready, syncing: store.syncing, syncedAt: store.syncedAt,
    lastNew: store.lastNew, ruku: store.ruku.length, chuku: store.chuku.length,
    pages: b ? b.pages : 0, rows: b ? b.rows : 0,
    phase: b ? b.phase : '', startedAt: b ? b.startedAt : 0, done: b ? b.done : false
  };
};
globalThis.__ERP_BOOT_CHECK__ = async function (user, password) {
  const boot = globalThis.__ERP_BOOT_PROGRESS__ = {
    pages: 0, rows: 0, phase: 'login', startedAt: Date.now(), done: false
  };
  // 临时包装分页请求，只为在启动窗口显示真实的下载页数/行数，结束后立即还原
  const origRaw = gridRaw;
  gridRaw = async function () {
    boot.pages++;
    const r = await origRaw.apply(null, arguments);
    boot.rows += (r && Array.isArray(r.rows)) ? r.rows.length : 0;
    return r;
  };
  try {
    const r = await doLogin(user, password);
    if (!r.ok) return { ok: false, message: r.message };
    const sid = crypto.randomBytes(24).toString('base64url');
    sessions.set(sid, {
      cookie: r.cookie, user: user,
      login: { ok: true, message: r.message, permissions: r.permissions },
      createdAt: Date.now()
    });
    boot.phase = 'compare';
    while (store.syncing) await new Promise(x => setTimeout(x, 150));
    const before = store.ruku.length + store.chuku.length;
    // 开机走快速比对：无差异每表 1 请求即结束；有差异才增量下载。
    // 结束后把全量校验时间推进到本次同步，避免 1 分钟后的定时同步又整库重下；
    // 若云端不可达（syncedAt 没更新），则保留旧值，让定时同步做一次全量兜底。
    const savedFull = lastFullCheck;
    lastFullCheck = Date.now();
    try { await syncAll('开机比对'); }
    finally { lastFullCheck = Math.max(savedFull, store.syncedAt || 0); }
    const after = store.ruku.length + store.chuku.length;
    return {
      ok: true, synced: store.syncedAt >= boot.startedAt, sid: sid,
      before: before, after: after, added: Math.max(0, after - before),
      syncedAt: store.syncedAt, ready: store.ready,
      pages: boot.pages, downloaded: boot.rows
    };
  } finally {
    gridRaw = origRaw;
    boot.done = true;
  }
};
