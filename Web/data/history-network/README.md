# 铁路建设时光机数据

六个地区的轨道几何与 OSM 标签来自随包 `metro-snapshot-*.json`。本目录的派生数据库采用 [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/)，署名 [© OpenStreetMap contributors](https://www.openstreetmap.org/copyright)。各地区 JSON 均可直接下载。`source` 保留原摘录地址、快照名、原始 PBF 与快照的 SHA-256、最近对象编辑时间。`index.json` 给出每个地区文件的 SHA-256 和统计。

每条记录对应一个 OSM way。`way` 是 OSM 编号，`name` 索引同文件的 `names`，`path` 按纬度、经度顺序存储增量编码折线，精度为 10⁻⁷ 度，保留快照中的全部顶点。`dateTags` 保留该 way 的原始日期字符串。用 `opening_date`、其次用 `start_date` 判定开通，用 `construction:start_date` 判定开工，用 `end_date` 或 `closure_date` 判定停用。年月和年份分别取月末和年末，`before 2021-12` 等范围描述保留作出处，不作开通日期。

澳门另有一个可核对的工程区间。横琴站、莲花站是 `relation/18361945` 的两个端点。两站之间的 `way/909486580` 与 `way/909486582` 几何连续。`sections` 单列这个区间的公共工程记录。2021 年 3 月 18 日举行[动工仪式](https://www.gov.mo/zh-hans/news/330514/)，[公共建设局竣工报告](https://www.dsop.gov.mo/news/news/3217/)记载 2021 年 4 月动工，[通车公告](https://www.gov.mo/zh-hans/news/795575/)记载 2024 年 12 月 2 日载客通车。回放据此从 4 月 30 日显示该工程。站外延伸段、车场和其他线路另计。

在仓库根目录执行 `node Scripts/build-history-network.mjs` 可离线重建。`node Scripts/build-history-network.mjs --check` 只校验已生成文件。`node Portable/check-history-network.cjs --data-only` 逐点核对快照与派生几何，并检查日期边界。
