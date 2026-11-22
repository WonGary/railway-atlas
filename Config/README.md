# 用户配置

## 地图问答（0.6.0 build 1）

设置 → 问答可以切换 GPT、Claude、DeepSeek、豆包和自定义服务。GPT 与 Claude 仍分别填写地址和 API Key；DeepSeek、豆包和自定义服务使用兼容 Chat Completions 的地址、模型 ID 和 API Key。留空 Key 保留已有凭据；删除凭据只作用于当前服务和地址。默认模型是可编辑的候选值，不代表账号已获得对应模型权限。

Claude 地址必须对应 Key 的签发服务。使用中转服务时，填写服务商支持的 Messages 地址；“套用 GPT 网关的 Messages 地址”仅修改设置草稿中的地址，需点击保存，并为新地址填写 Claude Key。它不会复制 GPT Key，也不证明该网关支持 Claude。若仍失败，错误区可选择复制具体状态码、接口 / 模型和服务端原因；401 检查 Key / 认证方式，403 检查权限或访问限制，404 检查地址及模型 ID，402 / 429 检查计费或频率。网络错误会区分超时、DNS 和 TLS。

输入区预留多行空间（侧栏 / 浮窗四行，独立窗口六行），长文字自动换行，超出可视区时滚动。发送期间可以编辑下一条草稿；未确认的输入法组合文字与新草稿不会被返回的答案清空。

“模型列表”可增加、删除条目，编辑模型 ID、显示名和备注。助手顶部菜单按 GPT／Claude 分组；点击条目切换服务、模型及其凭据，历史和草稿保留。旧配置中的自定义 GPT 模型不会被预置名称覆盖。

| 字段 | 含义 |
| --- | --- |
| `assistant.provider` | 当前服务 `gpt` / `claude` / `deepseek` / `doubao` / `custom` |
| `assistant.endpoint` / `apiProtocol` / `model` | GPT 地址、`responses` / `chat` 协议和模型，沿用旧字段 |
| `assistant.claude` | Claude 的 `endpoint`、`model`、`maxOutputTokens`、`authentication`、`apiVersion`、`webSearch`、`webFetch` |
| `assistant.claude.authentication` | `apiKey` 使用 x-api-key；`bearer` 使用 Authorization: Bearer，按网关要求选择 |
| `assistant.claude.apiVersion` | anthropic-version，默认 `2023-06-01`；可按服务商要求修改 |
| `assistant.claude.webSearch` / `webFetch` | 默认 `false`；分别启用 Claude Messages 服务端联网搜索与网页读取。仅在兼容的 Anthropic Messages API 服务启用；工具费用由服务商规则决定 |
| `assistant.compatible` | DeepSeek、豆包和自定义服务各自的 `endpoint`、`model`、`maxOutputTokens` |
| `assistant.models` | 模型条目数组：UUID `id`、服务 `provider`、模型 ID `name`、显示名 `label`、备注 `note` |
| `assistant.presentation` | macOS 显示位置：`sidebar` 右侧栏、`floating` 地图内浮窗、`window` 独立窗口（默认） |

助手右上角“显示位置”可随时切换；右侧栏和地图内浮窗共用右侧面板，“要素”和“地图问答”以左右并列页签切换，窄侧栏也不退回下拉菜单。独立窗口模式的右侧只显示要素。iOS 仍使用系统 sheet，保留文字选择。

输入框上方可选“附带地图信息”：不附带、精简、完整。选择存于各自会话的 `contextMode`（`none` / `summary` / `full`），新建对话沿用当前选择，旧会话缺失该字段时保留“完整”的原行为。

- 不附带：无需地图选择即可发送；本次请求移除新旧地图附件和引用标识，但保留聊天正文。正文中已经讨论过的地名等不会被删去；若要完全空白的上下文，先新建对话。
- 精简：仅附名称、类型、运营信息、少量统计与最多5个站名，不附坐标、任意标签或区段明细。当前材料预览显示实际精简内容；旧地图附件在本次发送时也会精简，原有本地快照仍保留。
- 完整：附带已载入范围的材料，沿用历史和字符限额；不代表下载完整路网。切换模式不会清空草稿、会话或旧引用，发送期间保持本次模式不变。

回答是一份连续原生富文本：支持中文标点边界的粗体、标题、列表、链接、代码与表格；macOS 表格使用有边框的原生单元格。鼠标可跨段选择，⌘C 或右键复制所选文字及样式。完整回答和整会话可复制为纯文本、格式化文本（RTF/HTML）或 Markdown 源文；纯文本保留代码中的字面符号，不再全局删除 `**`、下划线或反引号。格式化粘贴的效果由目标应用支持的格式决定。

Claude 在对话页及设置中有独立的“联网搜索”和“读取网页”开关，默认关闭。启用后分别声明 `web_search_20250305` 和 `web_fetch_20250910` 服务端工具，由模型按问题使用。每个工具每次请求最多使用 5 次，网页文本上限 12,000 tokens；最多自动续接 3 次，累计响应体上限 8 MiB。搜索与网页读取分别显示实际状态；来源可点击，复制及历史会保留来源和工具失败提示。仅点击开关不会发出请求。

搜索、网页读取及 GPT 的搜索偏好分别保存，切换模型不会互相覆盖。工具失败时保留服务端返回的文字，并显示应用解析出的失败原因；不支持工具的服务会报错，不自动退回普通对话。`pause_turn` 会携带原工具结果继续请求；需要客户端执行的 `tool_use` 明确报不支持。本版不执行模型提供的代码或本地工具。Messages 网关需兼容上述服务端工具；普通文字对话成功不能代替工具兼容性验证。

按 `⌘,` 打开设置；分为绘制、图层、界面、GPT、配置五页。图层页与地图侧栏共用同一状态。

首次运行会从旧偏好迁移并创建：

`~/Library/Application Support/RailwayAtlas/config.json`

设置页会显示实际路径（Xcode 沙盒版本位于自己的容器内）。修改自动保存；外部编辑后也自动重载，兼容编辑器的原子保存。错误 JSON、未知字段或越界参数不应用、不覆盖，修正文件后恢复同步。未提供的字段使用默认值。`default-config.json` 是完整示例；请先备份自己的配置，再用示例恢复默认值。

| 字段 | 含义 / 范围 |
| --- | --- |
| `rendering.metroWidthScale` | 地铁基准线宽倍率，0.5–2 |
| `rendering.railwayWidthScale` | 铁路基准线宽倍率，0.5–2 |
| `rendering.stationRadiusMultiplier` | 站点外半径 / 对应线宽，0.5–3，默认 1.25；内描边不额外增加半径 |
| `rendering.depotBrightness` | 车辆段线路色亮度，0.1–1，默认 0.5 |
| `rendering.viewportBuffer` | 视野每边预绘制比例，0–0.5，默认 0.2；移动离开缓冲区时更新，保留缓存和原始元信息 |
| `rendering.railwayPattern` | 铁路空实相间线型开关；在建、停用等状态虚线仍保留 |
| `map.mode` | `apple` 在线、`cached` 仅缓存、`offline` 本地地图包 |
| `map.basemapStyle` | `standard`、`satellite`、`hybrid` |
| `map.basemapDarkness` | 底图暗化，0–1 |
| `map.alignment` | `mainlandGCJ`：中国区域 Apple 底图，含港澳（默认）；`mainlandOnlyGCJ`：仅大陆；`wgs84`：原始坐标。只改变显示，缓存不转换 |
| `map.tileSource` | ORM 兼容铁路数据源 |
| `layers.categories` | 允许显示的铁路速度 / 用途 / 状态分类 |
| `layers.networks` | 允许显示的铁路、地铁、轻轨、电车、工业、窄轨等网络 |
| `layers.hiddenRoutes` | 关闭的整线标识；在图层页操作后自动填写，不建议猜测 ID |
| `layers.forcedCategories` / `forcedNetworks` | 手动强制显示，覆盖低缩放自动隐藏规则 |
| `layers.automaticDetail` | 按比例尺自动隐藏次要线路 |
| `layers.prioritizesUrbanTransit` | 都市轨道交通优先显示，默认 `false`；开启越过网络与速度 / 用途类别筛选，关闭恢复原有各分类设置，不是都市交通总隐藏 |
| `layers.showsNationalMetroOverview` | 全国地铁、轻轨、单轨和有轨电车简化概览开关；关闭不影响放大后的详细城市轨道 |
| `layers.showsStations` / `showsLabels` | 站点、站名开关 |
| `layers.showsStationLayouts` | 站区细节总开关。关闭时保留下面四项选择 |
| `layers.showsStationOutlines` / `showsPlatforms` | Z16 显示车站轮廓，Z17 显示站台面或站台线 |
| `layers.showsPassengerPassages` / `showsPlatformNumbers` | Z18 显示乘客通道和已知站台号，可单独开关。关闭线路或车站圆点仍可查看 |
| `layers.showsMetroColors` / `enrichWikiColours` | 线路色、在线百科补色开关 |
| `interface.uiScale` | 原生字号与布局缩放，0.75–1.6；保持屏幕原生像素密度 |
| `interface.panelVisible` / `panelWidth` | 左侧面板可见性 / 基准宽度 250–560 点；浮窗、分屏均可拖动右缘调宽 |
| `interface.panelLayout` | 左侧布局：`floating` 浮窗（默认）、`docked` 贴边分屏 |
| `interface.panelSize` | 左侧浮窗 `small`、`medium`、`large`；大小菜单或 ⌥⌘1 / 2 / 3；仅影响浮窗高度，分屏时保留所选档位 |
| `interface.panelBackgroundOpacity` | 左侧浮窗玻璃背景不透明度，0–1，默认 1；0 完全透明。设置中的“透明度” = 1 − 此值 |
| `interface.inspectorVisible` / `inspectorWidth` | 右侧面板可见性 / 基准宽度 200–560 点；浮窗、分屏均可拖动左缘调宽 |
| `interface.inspectorLayout` | 右侧布局：`floating` 浮窗、`docked` 贴边分屏（默认） |
| `interface.inspectorBackgroundOpacity` | 右侧浮窗玻璃背景不透明度，0–1，默认 1；独立于左侧。分屏时保留此值但使用实色背景 |
| `interface.inspectorTab` | 右侧页签 `feature` 要素 / `assistant` GPT；点选线路或车站自动打开要素页 |
| `interface.statusVisible` / `statusX` / `statusY` | 状态卡可见性 / 拖动偏移 |
| `assistant` | API 端点、协议、模型、输出上限、联网搜索 |

“轨道网络”最前的强调色开关“都市轨道交通”使用 `layers.prioritizesUrbanTransit`。它不修改 `categories`、`networks`、`forcedCategories`、`forcedNetworks` 或 `hiddenRoutes`；开启期间仍可编辑这些选项，关闭优先显示后按当前各分类设置绘制。“仅高铁”预设只设置速度类别，因此都市优先开启时仍会显示符合条件的都市轨道。旧配置缺少此字段时补入 `false`，保留已有偏好；新字段沿用配置自动保存、外部原子重载及启动恢复，不改变配置版本。

判定依据是运营服务：地铁、轻轨、单轨、有轨电车的明确类型，或铁路 / 窄轨自身及所属 `route=train` 关系中 `usage`、`service`、`passenger`、`train`、`railway:traffic_mode` 的明确 `urban`、`suburban`、`commuter`、`metro` 值。线路关系及已取得的 `route_master` 证据在在线解码、缓存、身份账本和本地地图包中保留。通勤铁路仍保留原有速度 / 用途分类与网络分类；不因为城市位置、线路名字、运营商、私有所有权、普通客运或区域列车标签而推断都市服务。明确货运、工业、军用、试验、观光或禁止客运的记录不获得优先显示；证据缺失的干线仍交给原有分类开关。

优先级明确如下：全国概览总闸、重复轨道抑制和整线隐藏先于都市优先；在建 / 规划、停用、废弃 / 拆除记录不获得都市优先，仍需相应状态及网络开关允许。之后仅对符合条件的运营轨道越过类别 / 网络筛选。原有缩放细节规则、全国概览与细节交接继续有效，手动强制缩放显示也继续有效。开关只影响已加载数据的显示，不触发全国概览加载；`showsNationalMetroOverview: false` 时，即使旧概览几何仍在内存或异步装配随后完成，也不能重新绘制概览。

站点可凭自身类型或明确线路归属越过网络筛选，但仍服从 `showsStations`、整线隐藏和原有 Z8 / Z10 显示门槛。带明确生命周期标签的站点还需相应状态类别允许；`showsLabels` 继续独立控制站名。附近轨道与运营商名称不构成站点的都市服务证据。同轨共线或共站时先移除隐藏线路，再判断余下服务是否有都市优先资格，避免已隐藏的通勤服务带出另一条普通铁路。

检查入口为 `RailwayAtlasCheck --urban-transit-regression`，覆盖开关组合、旧配置迁移与往返保存、全国概览总闸、共线隐藏、站点和生命周期、在线 / 本地解码，以及内置上海干线 / 工业站场 / 停用线路和港澳、东京 OSM 记录。此入口仅需 Core 检查程序，不需构建或安装应用。

面板布局只作用于 macOS 桌面。两侧顶部菜单可切换布局、选择宽度和隐藏；地图顶部按钮重新显示对应面板。小、中、大浮窗高度分别为 250 点、480 点和可用高度，均随界面缩放并受窗口高度限制。正文与控件不随玻璃背景透明度变化；未使用 `scaleEffect` 或 `drawingGroup`。

宽度是界面缩放前的偏好值；实际显示时两侧共同分配空间，左侧至少 250 点、右侧至少 200 点（放大界面时最低宽度也相应增加），中间保留至少 `max(260, 280 × uiScale)` 点无遮挡地图。先缩窄面板；最低宽度仍放不下时，临时收起一侧，优先最近请求显示的面板。点选要素、打开 GPT 会优先右侧；地图顶部按钮可切换优先侧。浮窗还预留顶部工具栏、右侧缩放按钮和底部信息区；高度不足时临时收起。临时收起不会改写可见性、宽度、布局或左侧大小，扩大窗口后自动恢复。极窄窗口若连单侧最低宽度与地图都放不下，会临时收起两侧。

旧配置通过现有递归 defaults 合并补入 `panelLayout: "floating"`、`inspectorLayout: "docked"` 及两个背景不透明度 `1`，无需修改配置版本；已有可见性、宽度、页签和大小保持原值。布局名称由 Codable 枚举验证，不透明度由 `validate()` 验证为有限的 0–1。未知字段、`null`、无效枚举或越界值沿用“拒绝整份应用并暂停写入”的行为。四个新字段已纳入 `ConfigurationStore.snapshot()` / `apply()`，继续使用现有自动保存、文件监视和原子重载路径。

站点与线路的尺寸使用地图逻辑点计算。站点颜色和归属不依靠尺寸匹配推定；附近轨道只用于没有线路关联时的宽度选择，不合并任何站点。界面字号缩放不会改变这组地图尺寸比例。

GPT 的 `webSearch` 默认关闭，可在助手中随时切换。启用后，Responses 请求附带 `web_search` 工具，由模型按需使用。回答下方显示本次是否实际完成搜索，并展示 API 返回的可点击引用。需要服务商及所选模型支持；Chat Completions 模式暂不提供搜索，发送前明确提示。服务商拒绝搜索时不会偷偷重试为普通回答。API key 只保存在钥匙串，禁止写入配置；同一网关切换 GPT 协议可沿用凭据，更换服务地址需分别配置。

打开设置或编辑配置不会调用模型。只有点击“发送”才把地图材料、问题及本会话发送给配置的服务商；搜索和网页读取可能另收费。GPT Responses 与 Claude Messages 工具链均有本地模拟响应验证，尚未用真实付费账号验证服务商兼容性。
