# 铁道图鉴跨平台试用版

打开 `index.html` 即可运行静态试用版。部署到 GitHub Pages 后，Windows、Android、iOS 和暂未安装原生开发环境的 Mac 都能用浏览器访问同一个入口。

试用版包含：

- G337 北京西到南昌西的本地轨道路线、经停站和 2026-11-20 时刻快照。
- 地铁概览。缩放到较大比例尺后才显示城市轨道细节，线路在缩放过程中保持挂载；在建线路使用灰白虚线。
- 地图问答。GPT、Claude、DeepSeek、豆包和自定义 Chat Completions 均可单独填写地址、模型 ID 和 API Key。
- 问答材料可选“少量信息”“完整信息”或“不附带信息”。回答支持鼠标框选和复制按钮。
- 支持 GitHub Pages 的 PWA 安装。iOS Safari 可通过“添加到主屏幕”使用，Android、Windows 和新版桌面浏览器可按浏览器提示安装。

API Key 只在当前页面内存中使用。勾选“记住地址和模型”只保存接口地址、模型名和协议，不保存 Key。浏览器直连需要服务商允许 CORS；服务商返回 401、403、404 或 429 时，按错误提示检查 Key、模型权限、余额和地址。

预置兼容地址使用 DeepSeek `https://api.deepseek.com/chat/completions` 和火山方舟 `https://ark.cn-beijing.volces.com/api/v3/chat/completions`。默认模型是可编辑示例：DeepSeek 为 `deepseek-flash`，豆包为 `doubao-seed-2-1-pro-260915`；豆包也可填写控制台中的 `ep-` 推理接入点 ID。

本地预览：

```bash
python3 -m http.server 8080 --directory Web
```

然后打开 `http://127.0.0.1:8080`。直接双击 HTML 文件会被浏览器的本地文件权限拦截，建议使用静态 HTTP 服务。PWA 离线壳只缓存应用文件和随包数据，地图底图仍需网络。
