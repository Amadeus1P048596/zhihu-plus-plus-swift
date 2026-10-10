# Zhihu++ Swift

面向 iPhone 和 iPad 的第三方知乎客户端。iOS 客户端使用 Swift、SwiftUI 与 UIKit 原生实现，不链接 Kotlin Multiplatform `Shared.framework`，也不依赖 Compose、CocoaPods、Swift Package 或第三方二进制框架。

> [!IMPORTANT]
> 本项目不是知乎官方产品，与知乎及其关联公司不存在隶属、授权或背书关系。项目依赖非公开接口，知乎服务端的变化可能随时导致部分功能失效。

## 特别感谢原项目

本项目基于 [zly2006/zhihu-plus-plus](https://github.com/zly2006/zhihu-plus-plus) 发展而来。原作者 **zly2006** 以及所有上游贡献者完成了产品方向、知乎接口探索、内容模型和大量基础能力；没有这些长期积累，就不会有这个原生 Swift 版本。

请优先关注、Star 并支持[原项目](https://github.com/zly2006/zhihu-plus-plus)。本 Swift 版本的问题不应转交给上游维护者处理。

本仓库是 2026 年 7 月制作的修改版。纯 Swift iOS 实现与迁移改造由 **OpenAI Codex** 完成，继续保留原项目的版权与开源许可。应用图标亦基于原项目素材制作，具体归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 维护说明

这是一个按当前需求生成的社区项目，欢迎 Fork 后按照自己的需要进行二次修改和维护。

本仓库后续**不承诺**：

- 修复已知或未来出现的 Bug；
- 增加、移植或维护新的 Feature；
- 适配知乎接口、iOS 或 Xcode 的后续变化；
- 回复 Issue、接受 Pull Request 或提供安装支持。

代码按现状提供，请在使用、修改或分发前自行审查和测试。

## 系统要求

### 运行

| 项目 | 要求 |
| --- | --- |
| 最低系统 | iOS / iPadOS 16.0 |
| 推荐系统 | iOS / iPadOS 26 或更高版本，可使用完整的系统 Liquid Glass 效果 |
| 翻译能力 | 需要 iOS / iPadOS 18 或更高版本，并取决于系统翻译资源可用性 |
| 设备 | Xcode Target 支持 iPhone 与 iPad；当前主要验收设备为 iPhone |

iOS 16–18/25 会使用系统提供的兼容样式；iOS 26+ 才会启用 Liquid Glass 等新系统效果。部分能力还取决于设备硬件与权限，例如相机扫码、Face ID / Touch ID、照片保存和语音朗读。

### 构建

| 项目 | 要求 |
| --- | --- |
| 开发环境 | macOS + 完整版 Xcode 26 或更高版本 |
| SDK | iOS 26 SDK 或更高版本 |
| Swift | Swift 5 language mode |
| 签名 | Apple Account、可用的 Development Team 与唯一 Bundle Identifier |

已知验证环境为 Xcode 26.6、iOS SDK 26.5。仅安装 Command Line Tools 无法完成 iOS App 构建。

## 当前原生能力

- SwiftUI 原生首页、关注、热榜、日报与搜索；
- 原生问题、回答、文章、想法与个人主页；
- 评论与楼中楼、投票、收藏、分享、图片预览和评论图片选择；
- 收藏夹、浏览历史、应用内通知、写回答与发布想法；
- `WKWebView` 登录与风控验证、Keychain 账户存储；
- AVFoundation 扫码授权、Photos 图片保存、系统分享；
- LocalAuthentication App 锁；
- Core Spotlight、App Intents / Shortcuts、前台朗读与系统翻译能力检测；
- iOS 26+ 原生 Liquid Glass 样式。

功能状态以当前源码为准。旧版 Zhihu++ 在 Android、Desktop 或 KMP 中存在的能力，不代表本 Swift 客户端已经实现。

### 图片查看器

- 双指缩放由 UIKit 原生识别器管理，与切图手势并行识别，不等待其失败；支持 1–5 倍缩放、触点跟随和边界回弹，放大后拖动平移图片。
- 双击围绕点击位置平滑放大至 2.5 倍，再次双击复原；开启“减弱动态效果”时直接切换缩放比例。
- 单击图片或空白区域关闭查看器，保留关闭按钮及 VoiceOver 关闭、缩放和退出操作。
- 未放大时左右滑动切图、上下滑动退出；手势方向锁定，避免与放大后的图片平移冲突。
- 动图继续播放；复制、分享和保存使用原始分辨率图片，不使用动图播放时的降采样帧。

## 构建与安装

### 通过 SideStore 安装与更新正式版

[一键添加到 SideStore](sidestore://source?url=https%3A%2F%2Fraw.githubusercontent.com%2Fkangyun1994%2Fzhihu-plus-plus-swift%2Fmain%2Fsidestore-source.json)

也可以在 SideStore 的来源页面手动添加：

```text
https://raw.githubusercontent.com/kangyun1994/zhihu-plus-plus-swift/main/sidestore-source.json
```

更新源只需添加一次。首次从来源安装后，后续正式版本会随
[GitHub Releases](https://github.com/kangyun1994/zhihu-plus-plus-swift/releases)
发布，并通过同一来源在 SideStore 中显示更新。正式 IPA 始终使用
`com.github.zly2006.zhplus.ios`，可以在现有正式版上更新；请勿为更新版改用不同的
Bundle Identifier，否则 iOS 和 SideStore 会将其视为另一个 App。

SideStore 检查到新版本后会下载 GitHub Release 中的未签名 IPA，并使用设备上的
Apple Account 重新签名安装。版本更新与 SideStore 的日常签名刷新是两件事：添加来源
用于发现新版本，7 天签名有效期仍由 SideStore 按其正常流程刷新。

### 从源码构建

克隆仓库并打开 Xcode 工程：

```bash
git clone https://github.com/kangyun1994/zhihu-plus-plus-swift.git
cd zhihu-plus-plus-swift
open iosApp/iosApp.xcodeproj
```

首次构建前可以运行只读预检：

```bash
./iosApp/scripts/preflight.sh
```

在 Xcode 的 `Signing & Capabilities` 中选择自己的 Development Team，并将 Bundle Identifier 改为自己可用的唯一值，然后选择模拟器或已信任的设备运行。

如需生成供 SideStore 重新签名的未签名 IPA：

```bash
BUNDLE_ID=com.example.zhihuplusplus.swift \
  ./iosApp/scripts/build-sidestore-ipa.sh
```

产物位于：

```text
build/iosApp/sidestore/ZhihuPlusPlus-SideStore.ipa
```

Apple Account、密码、签名证书、Provisioning Profile 和设备配对文件都不应提交到仓库，也不应提供给构建脚本之外的第三方。

更多签名与导出说明见 [iosApp/README.md](iosApp/README.md)。

## 隐私说明

- 当前 Swift Target 未实现项目自有遥测；
- 登录 Cookie 存储在系统 Keychain 中，不应写入源码或日志；
- 客户端会直接访问知乎及内容所需的网络服务，实际数据处理同时受对应服务条款与隐私政策约束；
- 请勿在公开 Issue、日志、截图或测试数据中提交 Cookie、Token、手机号、邮箱、设备标识或其他个人信息。

## 开源许可

Copyright © 2024–2026 zly2006 and contributors.

本项目是 [zly2006/zhihu-plus-plus](https://github.com/zly2006/zhihu-plus-plus) 的修改版，整体继续采用 **GNU Affero General Public License v3.0 only（AGPL-3.0-only）**。完整条款见 [LICENSE](LICENSE)。

如果分发 IPA 或其他目标代码，应同时以 AGPL v3 要求的方式提供该版本的完整对应源码，并保留版权、修改说明、许可与无担保告知。建议每个二进制 Release 对应一个源码 Tag，并在下载位置提供该 Tag 的源码链接。

本软件不提供任何明示或暗示的担保；使用、修改和分发风险由使用者自行承担。“知乎”及相关标识归其权利人所有。
