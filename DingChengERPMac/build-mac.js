#!/usr/bin/env node
/**
 * 鼎城 ERP 桌面版 · macOS Intel (x86_64) 安装包组装脚本
 *
 * 只在 macOS 上运行（GitHub Actions macos-15-intel runner），因为：
 *  1) Electron.app 内含 Unix 符号链接与可执行权限位，Windows 解压会退化成普通文件；
 *  2) codesign / iconutil / hdiutil / ditto 都是 macOS 自带工具。
 *
 * 输入（相对本脚本所在目录，即仓库里的 DingChengERPMac/）：
 *   build-src/electron.zip      官方 electron-v22.3.27-darwin-x64.zip（单独目录，
 *                              组装时会清空 build/，所以 zip 不能放 build/ 里）
 *   app/                       与 Windows 桌面版完全相同的 resources/app 内容
 *   icon-master.png             1024x1024 主图标
 * 输出（dist/）：
 *   DingChengERP-Mac-Intel.zip  可直接解压拖入 Applications 的 .app（保留符号链接/权限）
 *   DingChengERP-Mac-Intel.dmg  标准安装包形态，带 Applications 快捷方式
 *
 * 不改动任何业务逻辑：app/ 目录直接来自 Windows 桌面版构建产物，两端同源。
 */
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const HERE = __dirname;
const BUILD = path.join(HERE, 'build');
const DIST = path.join(HERE, 'dist');
const STAGE = path.join(BUILD, 'stage');
const ZIP = path.join(HERE, 'build-src', 'electron.zip');
const APP = path.join(BUILD, 'DingChengERP.app');
const APP_SRC = path.join(HERE, 'app');
const ICON_PNG = path.join(HERE, 'icon-master.png');
const BUNDLE_ID = 'com.dingcheng.erp.desktop';
const DISPLAY = '鼎城 ERP';
const VERSION = '2.2.0';

function need(c, m) { if (!c) throw new Error('[mac] ' + m); }
function run(cmd, args, opts = {}) {
  try {
    return execFileSync(cmd, args, {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 32 * 1024 * 1024, ...opts
    });
  } catch (e) {
    const tail = String(e.stderr || e.stdout || e.message).slice(-1200);
    throw new Error(`[mac] ${cmd} ${args.join(' ')} 失败: ${tail}`);
  }
}
function sh(script) { return run('/bin/bash', ['-lc', script]); }
function log(...a) { console.log('[mac]', ...a); }

// PlistBuddy 的 Set 要求键已存在、Add 要求键不存在，这里统一成 upsert
function plistSet(p, key, value, type = 'string') {
  // 值里可能含空格（如「鼎城 ERP」），PlistBuddy 的 -c 表达式必须加引号
  const v = `"${String(value).replace(/"/g, '\\"')}"`;
  try {
    run('/usr/libexec/PlistBuddy', ['-c', `Set :${key} ${v}`, p]);
  } catch {
    run('/usr/libexec/PlistBuddy', ['-c', `Add :${key} ${type} ${v}`, p]);
  }
}

function main() {
  need(process.platform === 'darwin', '此脚本只能在 macOS 上运行');
  need(fs.existsSync(ZIP), '缺少 build/electron.zip（workflow 下载步骤未完成）');
  need(fs.existsSync(path.join(APP_SRC, 'main.js')), '缺少 app/main.js');
  need(fs.existsSync(path.join(APP_SRC, 'web', 'server.js')), '缺少 app/web/server.js');
  need(fs.existsSync(ICON_PNG), '缺少 icon-master.png');

  // 只清空组装工作区；Electron zip 在独立的 build-src/ 里，不会被一起删掉
  fs.rmSync(BUILD, { recursive: true, force: true });
  fs.mkdirSync(BUILD, { recursive: true });
  fs.mkdirSync(DIST, { recursive: true });

  log('环境:', run('sw_vers', ['-productVersion']).trim(), '/', run('uname', ['-m']).trim());

  // 1) 解压 Electron。ditto -xk 会正确还原符号链接、权限位与扩展属性
  fs.mkdirSync(STAGE, { recursive: true });
  sh(`/usr/bin/ditto -xk "${ZIP}" "${STAGE}"`);
  const electronApp = path.join(STAGE, 'Electron.app');
  need(fs.existsSync(path.join(electronApp, 'Contents', 'MacOS', 'Electron')),
    '解压结果不是预期的 Electron.app');
  run('/bin/cp', ['-R', electronApp, APP]);   // cp -R 保留符号链接
  log('Electron.app 已展开，符号链接数:',
    sh(`find "${APP}" -type l | wc -l`).trim());

  // 2) 换上鼎城自己的应用代码（与 Windows 桌面版同一份）
  const res = path.join(APP, 'Contents', 'Resources');
  fs.rmSync(path.join(res, 'default_app.asar'), { force: true });
  fs.rmSync(path.join(res, 'app'), { recursive: true, force: true });
  fs.rmSync(path.join(res, 'app.asar'), { force: true });
  run('/bin/cp', ['-R', APP_SRC, path.join(res, 'app')]);
  need(fs.existsSync(path.join(res, 'app', 'main.js')), '应用代码复制失败');

  // 3) 生成 .icns：iconutil 要求标准 iconset 尺寸组
  const iconset = path.join(BUILD, 'AppIcon.iconset');
  fs.mkdirSync(iconset, { recursive: true });
  const sizes = [
    ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32],
    ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
    ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256],
    ['icon_256x256.png', 256], ['icon_256x256@2x.png', 512],
    ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024]
  ];
  for (const [name, px] of sizes) {
    run('/usr/bin/sips', ['-z', String(px), String(px), ICON_PNG,
      '--out', path.join(iconset, name)]);
  }
  const icns = path.join(BUILD, 'app.icns');
  run('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', icns]);
  need(fs.statSync(icns).size > 1000, 'app.icns 生成异常');
  fs.copyFileSync(icns, path.join(res, 'electron.icns'));      // .app 的 Finder/Dock 图标
  fs.copyFileSync(icns, path.join(res, 'app', 'assets', 'app.icns')); // main.js 对话框图标
  log('app.icns 生成完毕', fs.statSync(icns).size + 'B');

  // 4) 改 Info.plist：只改必要字段，保留 Electron 原版全部必需键
  const plist = path.join(APP, 'Contents', 'Info.plist');
  plistSet(plist, 'CFBundleName', DISPLAY);
  plistSet(plist, 'CFBundleDisplayName', DISPLAY);
  plistSet(plist, 'CFBundleIdentifier', BUNDLE_ID);
  plistSet(plist, 'CFBundleShortVersionString', VERSION);
  plistSet(plist, 'CFBundleVersion', VERSION);
  plistSet(plist, 'CFBundleDevelopmentRegion', 'zh_CN');
  plistSet(plist, 'LSMinimumSystemVersion', '10.15'); // Electron 22 最低 10.15，覆盖 macOS 13
  plistSet(plist, 'CFBundleIconFile', 'electron.icns');
  run('/usr/bin/plutil', ['-lint', plist]);
  log('Info.plist 字段:', run('/usr/libexec/PlistBuddy',
    ['-c', 'Print :CFBundleName', plist]).trim(),
    '|', run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', plist]).trim(),
    '| min', run('/usr/libexec/PlistBuddy',
      ['-c', 'Print :LSMinimumSystemVersion', plist]).trim());

  // 5) 权限：主可执行与所有 Helper 必须可执行（ditto 已保留，这里兜底）
  sh(`chmod +x "${APP}/Contents/MacOS/Electron"`);
  sh(`find "${APP}/Contents/Frameworks" -name "Electron Helper*" -type f -exec chmod +x {} + 2>/dev/null || true`);

  // 6) ad-hoc 签名：没有 Apple Developer ID，签完本机可运行；
  //    下载后仍需 xattr -cr 去掉 quarantine（README 有说明）
  sh(`/usr/bin/codesign --force --deep --sign - --timestamp=none "${APP}"`);
  sh(`/usr/bin/codesign --verify --deep --strict --verbose=1 "${APP}"`);
  log('ad-hoc 签名完成');

  // 7) 结构自检（产物必须真的是 Intel x86_64，且符号链接没丢）
  const arch = run('/usr/bin/lipo', ['-archs', path.join(APP, 'Contents', 'MacOS', 'Electron')]).trim();
  need(/\bx86_64\b/.test(arch), '主可执行不是 x86_64: ' + arch);
  const links = Number(sh(`find "${APP}" -type l | wc -l`).trim());
  need(links > 0, '符号链接丢失，.app 在 macOS 上会打不开');
  need(fs.existsSync(path.join(res, 'app', 'web', 'index.html')), '缺少桌面版网页');
  need(fs.existsSync(path.join(res, 'app', 'web', 'server.js')), '缺少桌面版服务');
  log('结构自检通过 | 架构:', arch, '| 符号链接:', links);

  // 8) zip：ditto -c -k --sequesterRsrc --keepParent 是 Apple 官方推荐的 .app 打包方式
  const outZip = path.join(DIST, 'DingChengERP-Mac-Intel.zip');
  sh(`cd "${BUILD}" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent DingChengERP.app "${outZip}"`);
  log('zip:', (fs.statSync(outZip).size / 1048576).toFixed(1) + ' MB');

  // 9) dmg：带 Applications 快捷方式，用户拖一下就装好
  const dmgStage = path.join(BUILD, 'dmg-root');
  fs.mkdirSync(dmgStage, { recursive: true });
  run('/bin/cp', ['-R', APP, path.join(dmgStage, 'DingChengERP.app')]);
  fs.symlinkSync('/Applications', path.join(dmgStage, 'Applications'));
  const outDmg = path.join(DIST, 'DingChengERP-Mac-Intel.dmg');
  run('/usr/bin/hdiutil', ['create', '-volname', 'DingCheng ERP', '-srcfolder', dmgStage,
    '-ov', '-format', 'UDZO', outDmg]);
  log('dmg:', (fs.statSync(outDmg).size / 1048576).toFixed(1) + ' MB');

  // 10) 写一份校验清单，便于本地 verify-mac.js 与人工核对
  const manifest = {
    platform: 'darwin', arch: 'x86_64', electron: '22.3.27', node: '16.17.1',
    bundleId: BUNDLE_ID, displayName: DISPLAY, version: VERSION,
    minSystemVersion: '10.15', signed: 'ad-hoc', symlinks: links, lipo: arch,
    zip: fs.statSync(outZip).size, dmg: fs.statSync(outDmg).size
  };
  fs.writeFileSync(path.join(DIST, 'build-info.json'), JSON.stringify(manifest, null, 2) + '\n');
  log('DONE', JSON.stringify(manifest));
}
main();
