# 鼎城 ERP 桌面版 · macOS Intel 构建源

此目录由 GitHub Actions `macos-15-intel` runner 消费，产出 macOS / Intel (x86_64) 安装包。
与仓库内 `DingChengERPIOS/`（iOS）、`TVBox/` 完全隔离。

## 目录

| 路径 | 说明 |
| --- | --- |
| `build-mac.js` | 组装脚本：解压 Electron → 换应用代码 → 生成 icns → 改 Info.plist → ad-hoc 签名 → 出 zip / dmg |
| `icon-master.png` | 1024×1024 主图标，`iconutil` 生成 `app.icns` |
| `app/` | 与 Windows 桌面版 `resources/app/` 完全一致的应用代码（main.js / preload.js / web/…） |
| `build-src/electron.zip` | 运行时包，由 workflow 下载，不入库 |
| `build/`、`dist/` | 组装工作区与产物，由 workflow 生成，不入库 |

## 关键约定

- 运行时固定 `electron-v22.3.27-darwin-x64.zip`：内置 Node 16.17.1，与 `erp-web/server.js` 的 Node 16 兼容分支一致；最低支持 macOS 10.15，覆盖 macOS 13 Ventura / Intel。
- **必须用 `ditto -xk` 解压、`cp -R` 复制、`ditto -c -k` 打包**：Electron Framework 内含 Unix 符号链接与可执行权限位，普通 zip 工具在 Windows 上会把它们退化成普通文件，导致 .app 打不开。
- Info.plist 用 PlistBuddy 逐字段修改 Electron 原版，**不整体替换**，避免丢失 Electron 必需的键。
- 无 Apple Developer ID，只做 ad-hoc 签名。用户下载后需执行一次 `xattr -cr` 去掉 quarantine，详见交付说明。
- 不放随包数据快照：首次使用由用户登录后全量下载一次，与桌面版「首次登录全量、二次启动增量」逻辑一致。

## 触发

push 到 `main` 且改动 `DingChengERPMac/**` 或本 workflow 时自动构建；也可在 Actions 里手动 `Run workflow`。

产物（artifact 保留 30 天，同时挂 GitHub Release 长期可下载）：

- `DingChengERP-Mac-Intel.dmg` — 标准安装包，拖入 Applications 即用
- `DingChengERP-Mac-Intel.zip` — 解压得到 `DingChengERP.app`
- `build-info.json` — 架构 / 版本 / 签名 / 符号链接数自检结果
