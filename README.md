# 铁道图鉴 Railway Atlas

铁道图鉴是一个用于查看铁路地图、车站资料和沿线旅行的 SwiftUI 应用，也提供跨平台浏览器试用版。

## 给朋友的最短用法

打开 GitHub Pages 入口即可。iOS Safari 可添加到主屏幕，Android、Windows 和新版桌面浏览器可安装 PWA。Mac 用户可下载 Release 中的 macOS 包；Windows、iOS 和 Android 使用网页入口。打开网页后，点“地图问答”，选择服务商，填写自己的 API 地址、模型 ID 和 API Key。

网页不提供 API 额度，也不会把 Key 写入仓库。Key 只在当前页面内存中使用。服务商是否允许浏览器直连，取决于该服务的 CORS 和账号权限。

## 当前版本

`0.6.0 (1)`

已验证：

- SwiftPM Release 构建和 `RailwayAtlasCheck` 核心回归。
- macOS 原生代码路径和 G337 本地沿线资料。
- 浏览器静态页面的本地资料加载、缩放时线路保持、G337 站点表和自定义 Chat Completions 请求构造。
- DeepSeek 与火山方舟的默认接口地址可在网页中直接替换和保存。预置模型名可改为账号实际提供的 Model ID 或 `ep-` 推理接入点 ID。

当前边界：

- 本机没有完整 Xcode、iOS SDK 或 Android SDK，因此没有在本机编译 iOS/Android 原生包。网页入口覆盖这三端的试用。
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

网页版本用于 Windows、iOS 和 Android 试用，不依赖这些原生 SDK。需要编译 iOS 原生包时，再安装完整 Xcode；需要编译 Android 原生包时，再安装 Android SDK 和 Android Studio。Xcode 工程由 `Scripts/generate-xcode.mjs` 生成，包含 macOS 和 iOS target。拥有完整 Xcode 后可打开 `RailwayAtlas.xcodeproj`，选择 `RailwayAtlas-iOS` 或 `RailwayAtlas-macOS`。

## 网页本地预览

```bash
python3 -m http.server 8080 --directory Web
```

然后访问 `http://127.0.0.1:8080`。GitHub Pages 直接发布 `Web/` 目录即可。

## 数据与许可

铁路几何、车站标签和城市轨道数据来自 OpenStreetMap 社区数据，按 ODbL 1.0 处理。随包资源保留各自来源和许可说明，详见 `Sources/RailwayAtlas/Resources/NOTICE.txt`、`Sources/RailwayCore/Resources/METRO-PALETTE-LICENCE.txt` 和 `Sources/RailwayCore/Resources/NATIONAL-METRO-LICENCE.txt`。

OpenRailwayMap、OpenFreeMap、OSM、Leaflet 以及中国铁路地图的来源和使用边界见资源说明与网页内链接。仓库没有内嵌 API Key、个人会话、地图账号或其他运行凭据。
