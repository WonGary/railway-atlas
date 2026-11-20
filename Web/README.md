# 铁道图鉴网页版本

当前网页版本为 `0.6.3`。它是可部署到 GitHub Pages 的 PWA，入口是 `index.html`。Windows、Android、iOS 和 macOS 浏览器可访问同一页面；iOS Safari 可通过“添加到主屏幕”安装，支持 PWA 的桌面浏览器会提供安装入口。

## 已实现

- 地图工作区、铁路与城市轨道图层、OpenStreetMap / OpenRailwayMap 底图切换。
- 地铁在建线路使用灰白色虚线；缩放时线路图层保持挂载，连续调整透明度和线宽。
- 沿线旅行开关、路线工作区、播放条、进度拖动和播放速度。顶部按钮、播放条关闭按钮、工作区关闭按钮、遮罩和 `Escape` 键都会关闭线路工作区、隐藏播放条并停止播放。
- 随包路线和时刻：`G337`（北京西 → 南昌西）与 `G6580`（2026-11-08 样例快照）。可导入包含 `stops` 和 `legs` 或 `routing.legs` 的 JSON。
- 车站目录、经停表、车站收藏、铁路护照、JSON / CSV 导入导出、旅程明信片、铁路历史时间轴和猜城市。
- 地图问答服务配置：GPT、Claude、DeepSeek、豆包和自定义接口。支持 GPT Chat Completions / Responses、Anthropic Messages、Chat Completions；可分别填写 API 地址、模型 ID 和 API Key。
- 问答回答支持 Markdown 渲染、鼠标选择、复制原文和复制格式化内容。Claude 可选服务端 `web_search` 和 `web_fetch`，支持有限次数的 `pause_turn` 续接和引用显示。
- 问答材料可选“少量信息”“完整信息”或“不附带信息”；问答面板可留在右侧、切换为浮窗，或在独立窗口打开。输入框随内容自动增高。

## 数据范围

网页包目前包含 2 条随包铁路路线及其时刻、约 1,082 条城市轨道概览记录、9 个铁路历史时间轴节点、G337 随包轨道几何，以及数据包中已有的其他路线几何。

这些资料用于跨平台试用，不是全国实时铁路系统。网页端目前没有放入原生版的完整全国铁路数据库、实时车站 / 车次数据、完整离线铁路地图，也没有接入 `cnrail.geogv.com` 的全网途经线路、线路所和本站车次表。车站信息栏提供原站入口，可在那里查询实时信息；若要把数据直接显示在本页，需要服务端代理解决跨域访问。

地图底图需要联网。问答服务由浏览器直接访问服务商接口，因此需要服务商允许浏览器跨域（CORS），且 API Key、模型 ID、余额和权限有效。

API Key 只保存在当前页面内存中，不写入 `localStorage`。勾选“记住地址和模型”时，仅保存接口地址、模型名和协议。公开部署时不要把个人 Key 写入源码、静态文件或 GitHub Actions 配置。

预置兼容地址包括 DeepSeek `https://api.deepseek.com/chat/completions` 和豆包 `https://ark.cn-beijing.volces.com/api/v3/chat/completions`。预置模型名是可编辑示例；豆包也可以填写控制台提供的 `ep-` 推理接入点 ID。其他服务商可使用自定义协议和接口地址。

## 本地预览

在仓库根目录运行：

```bash
python3 -m http.server 8080 --directory Web
```

然后打开 `http://127.0.0.1:8080`。建议通过 HTTP 服务访问，直接双击 HTML 文件会触发浏览器的本地文件权限限制。PWA 离线壳会缓存页面、脚本和随包数据，地图底图及问答接口仍需要网络。
