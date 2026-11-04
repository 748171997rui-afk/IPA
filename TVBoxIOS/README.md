# TVBox iOS（精简版）

TVBox 客户端的 iOS 重写版（SwiftUI + AVPlayer），专为 iPhone 13 Pro Max 等 iOS 16+ 设备设计。
通过 GitHub Actions 云端 macOS 编译出**未签名 IPA**，自行签名后安装。

## 功能

- **内置 4 个实测可用的直连源（暴风/索尼/量子/非凡），开机即有内容，无需配置**
- 设置页可换填任意 TVBox 接口（配置 JSON）自动解析站点
- 分类浏览 / 分页加载 / 关键词搜索
- 影片详情 + 多线路多集选择
- AVPlayer 播放（m3u8 / mp4 / ts 直链）

## ⚠️ 重要限制（务必阅读）

**iOS 无法运行 Android 爬虫。** 配置里的 `csp_*`（dex jar 爬虫）和 `.js` 爬虫源
会被自动过滤。如果你的接口像 `fty.json` 一样全是爬虫源，App 会提示无可用源，
需要更换为包含 **type 0/1 直连 JSON 源**（苹果CMS接口）的配置。

## 云端编译 IPA 步骤

1. 在 GitHub 新建一个仓库（Public 免费额度够用）
2. 把本目录全部文件推上去（含 `.github/workflows/build-ipa.yml`）
3. 打开仓库 → Actions → "Build Unsigned IPA" → Run workflow
4. 构建完成后在该次运行页面的 **Artifacts** 下载 `TVBox-unsigned-ipa`
5. 解压得到 `TVBox-unsigned.ipa`

## 自签安装（选一种）

| 工具 | 适用 | 说明 |
|------|------|------|
| **Sideloadly**（推荐） | Windows/Mac + 数据线 | 用免费 Apple ID，7 天有效，最多 3 个应用 |
| **轻松签 / eSign** | 已在设备上装了自签工具 | 导入 p12 证书直接签 ipa |
| **AltStore** | Mac/Win + 数据线 | 同样免费 Apple ID，7 天有效 |

### Sideloadly 流程（Windows）
1. 下载安装 Sideloadly 与 iTunes（官网版）
2. iPhone 连电脑，打开 Sideloadly
3. 拖入 `TVBox-unsigned.ipa`，填入你的 Apple ID
4. Start → 完成后 iPhone 上：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书
5. 首次打开如提示"不受信任"，完成上一步即可

付费开发者账号（$99/年）签出来的证书有效期为 1 年。

## 目录结构

```
TVBoxIOS/
├── project.yml                  # XcodeGen 工程定义
├── TVBox/
│   ├── HomeView.swift           # 入口 App + 首页（源/分类/海报网格）
│   ├── DetailView.swift         # 详情+选集
│   ├── PlayerView.swift         # AVPlayer 播放器
│   ├── SearchAndSettings.swift  # 搜索页 + 设置页
│   └── default_config.json      # 内置直连源（4 个实测可用）
└── .github/workflows/build-ipa.yml
```
