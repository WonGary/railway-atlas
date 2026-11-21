# 铁道漫游 Railway Atlas

铁道漫游是一张可以点开线路和车站的地图。你可以按速度和用途筛选铁路，单独显示某条地铁，查换乘和站表，也可以收藏要素或向地图助手提问。

## 给朋友的最短用法

[打开地图](https://wongary.github.io/railway-atlas/) ｜ [下载 Android、Windows、Mac 和 iOS 归档](https://github.com/WonGary/railway-atlas/releases/tag/web-v0.8.0)

0.8.0 首次打开是全国地图，以后回到上次浏览的位置。安卓手机可以直接安装 APK，Windows 和 Mac 的便携包用浏览器打开本机地图。iPhone、iPad 可以立即打开网页版，原生版由发布者签名后发 TestFlight 邀请。「更多」里保留了沿线旅行和铁路护照。[地图和离线资料](Web/README.md) · [手机安装与签名](Mobile/README.md)

网页不提供 API 额度，也不会把 Key 写入仓库。Key 只在当前页面内存中使用。服务商是否允许浏览器直连，取决于该服务的 CORS 和账号权限。

## SwiftUI 原生版

`0.6.0 (1)`

已验证：

- SwiftPM Release 构建和 `RailwayAtlasCheck` 核心回归。
- macOS 原生代码路径和 G337 本地沿线资料。
- 浏览器静态页面的本地资料加载、缩放时线路保持、G337 站点表和自定义 Chat Completions 请求构造。
- DeepSeek 与火山方舟的默认接口地址可在网页中直接替换和保存。预置模型名可改为账号实际提供的 Model ID 或 `ep-` 推理接入点 ID。

当前边界：

- iPhone 和 iPad 归档使用原生 SwiftUI / MapKit 工程。Android APK 随包附带网页地图与区域资料。
- macOS 包是本机临时签名，适合源码使用者和本机测试，未公证。
- 网页不保存 API Key。Claude、DeepSeek、豆包和自定义网关能否在浏览器使用，取决于端点的 CORS、模型权限和余额。
- G337 的轨道资料是随包的 OSM 派生快照，时刻是一次性样例，不是实时列车位置。

## 本机最小编译环境

macOS 原生版本只需要 Swift 6、macOS 14 SDK 和命令行工具。当前发布过程没有安装完整 Xcode、iOS SDK、Android SDK 或 Android Studio：

```bash
swift build -c release --product RailwayAtlas
swift run -c release RailwayAtlasCheck --assistant-regression
bash Scripts/build-macos.sh release
```

手机构建可使用仓库中的 GitHub Actions，本机只需下载成品。若选择本地编译，iOS 使用 Xcode，Android 使用 JDK、Gradle 与 Android SDK 命令行工具。Xcode 工程由 `Scripts/generate-xcode.mjs` 生成。

## 网页本地预览

```bash
python3 -m http.server 8080 --directory Web
```

然后访问 `http://127.0.0.1:8080`。GitHub Pages 直接发布 `Web/` 目录即可。

## 数据与许可

铁路几何、车站标签和城市轨道数据来自 OpenStreetMap 社区数据，按 ODbL 1.0 处理。随包资源保留各自来源和许可说明，详见 `Sources/RailwayAtlas/Resources/NOTICE.txt`、`Sources/RailwayCore/Resources/METRO-PALETTE-LICENCE.txt` 和 `Sources/RailwayCore/Resources/NATIONAL-METRO-LICENCE.txt`。

OpenRailwayMap、OpenFreeMap、OSM、Leaflet 以及中国铁路地图的来源和使用边界见资源说明与网页内链接。仓库没有内嵌 API Key、个人会话、地图账号或其他运行凭据。
