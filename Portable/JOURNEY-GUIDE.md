# 沿线旅行 8–10 接线和验收

## 网页入口与离线缓存

正式页面已载入 `Web/route-inspector.js`。首次打开车次时，它依次载入 `station-directory/journey-guide-core.js` 和 `journey-guide.js`。后者挂在 `#routeInspector` 后面，读取当前乘车区间、播放器标记和时间。保留现有 `#followJourney` 和 `selectRoute(id, {from, to, fit})` 即可。若 HTML 集中声明脚本，也可按上述顺序放在 `route-inspector.js` 后。

SW 的 shell 缓存需覆盖以下三个相对于 `Web/` 的路径，并更新缓存版本。

```text
station-directory/journey-guide-core.js
journey-guide.js
station-directory/journey-places.json
```

地点包约 2.29 MB。普通网页打开「沿线地点」才读取它。站表沿用 `station-directory/national.js`，接力用已有的 `station-directory/paths/` 日期分组。在没有对应径路的情况下，面板指出缺段并保留当前行程。

## 原生入口

`MapExperienceControls` 在列车模式下挂载 `RideGuideControls(player:guide:)`。「途中」菜单打开沿线地点和同站接力。「观光模式」释放相机，「回到列车」重新跟随。继续使用原播放器的 `start(_:route:)`、`play()` 和 `seek(_:)` 即可。

| 调用处 | 接口 |
| --- | --- |
| MapKit 拖图或离线 Canvas 拖图 | `RailMapPlayback.userPanned()` |
| MapKit 手势、Canvas 捏合以及地图缩放按钮 | 读取 `RailMapPlayback.holdsZoom` |
| 查看地点或回到列车 | `inspectPlace(_:)`、`resumeFollowing()` |
| 查询指定站后续 6 或 24 小时内的车次 | `RideGuideStore.connections(_:stop:hours:)` |
| 跳到接续班次的上车时刻 | `RideGuideStore.board(_:at:through:player:)`，`at` 是当前车的换乘站序，`through` 是接续车的下车站序 |
| 从全国排图提取乘车几何 | `NationalJourneyPaths.relaySection(train:origin:trip:indices:)` |

两个原生目标使用现有的 `station-directory` 文件夹资源。发布构建执行 `node Scripts/generate-xcode.mjs` 可将新增 Swift 文件列入 macOS 和 iOS 的 Sources 阶段。SwiftPM 会自动发现这些文件。

## 复测

在 checkout 根目录运行。浏览器检查使用 Playwright 和本机 Chromium，macOS 脚本为每次运行建立单独的 QA 目录，并核对本次回执。

```sh
node Scripts/build-journey-places.mjs --check
node Portable/check-route-inspector.cjs http://127.0.0.1:18974/
node Portable/check-journey-guide.cjs http://127.0.0.1:18974/
sh Portable/check-journey-guide-native.sh
```

2026-11-26 的复测样例从 D174 开始。14:28 到广元，接 14:42 的 Z318 至江油，该车始发于 11 月 25 日。17:38 到江油，接 17:40 的 G8689 至绵阳。Web 验收还会从 D1928 的响应中移除广元至宁强南的轨迹，核对当前列车、进度和接力顺序。路线比较另查 D174/D176 全程反向共线以及 D174/D2236 部分共线。

地点列表同时按距列车和距轨道的距离筛选。距列车上限为 12 km，桥隧距轨道最多 1 km，城市中心最多 8 km。交汇站按目录列出的两条及以上铁路识别。地点详情保留数据来源，换乘时间按图定到发计算。
