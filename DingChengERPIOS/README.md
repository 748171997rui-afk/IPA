# 鼎城 ERP · iOS 云编译工程

江西鼎城铝模科技有限公司 ERP 库存 / 出入库查询的 iOS App。

## 架构

App 打开时**在本机 127.0.0.1 起一个 HTTP 服务**（8788，占用则顺延），
由 App 自己直连厂商云 `sjmsai.vip` 查询数据，WKWebView 只加载本机页面。
不需要电脑开机、不需要同一 WiFi、不需要填任何服务器地址。

- `ErpServer.swift`：BSD socket 本机服务 + URLSession 上游请求 + 登录会话 / 入库 / 出库 / 库存汇总
- `ViewController.swift`：WKWebView 壳，CSV 通过 JS bridge 交给系统分享
- `index.html`：与 Windows EXE / Android APK 完全同一份网页
- 账号密码只由网页登录框输入，不落盘、不写日志、不内置

## 云端编译

`.github/workflows/build-dingcheng-ipa.yml` 在 `macos-15` runner 上执行：

1. `xcodegen generate` 由 `project.yml` 生成 Xcode 工程
2. `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）产出未签名 `.app`
3. 打包 `Payload/` 为 `DingChengERP-unsigned.ipa` 并上传 Artifact

触发方式：推送本目录文件自动触发，或在 Actions 页面手动 `Run workflow`。
产物在对应运行页的 **Artifacts → DingChengERP-unsigned-ipa**。

## 安装

产物是**未签名 IPA**（Apple 签名必须在 macOS + 有效证书下完成，CI 无证书时只能这样）。
用以下任一方式自签后安装：

| 工具 | 平台 | 说明 |
|------|------|------|
| Sideloadly（推荐） | Windows / macOS | 免费 Apple ID，7 天有效 |
| AltStore | Windows / macOS | 免费 Apple ID，7 天有效 |
| 轻松签 / eSign | 手机端 | 导入 p12 证书后直接签 |

Sideloadly：iPhone 连电脑 → 拖入 IPA → 填 Apple ID → Start →
手机「设置 → 通用 → VPN 与设备管理」信任证书。

如后续要在 CI 直接产出**已签名 IPA**，需提供 Apple Developer 证书与描述文件
（P12_BASE64、P12_PASSWORD、PROVISIONING_BASE64、TEAM_ID）作为仓库 Secrets，
再补一个 `xcodebuild -exportArchive` 步骤。
