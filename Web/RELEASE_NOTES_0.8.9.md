# 铁道漫游 0.8.9

在「沿线旅行」输入车号，选择始发日期即可在主地图上查看路线。也可以点车站，在右栏展开一趟车，选择「在主地图沿线旅行」或「制作路线明信片」。护照和明信片按乘车当天的上下车站截取轨迹，跨午夜上车会自动换算始发日期。

路线在发布时按车次、运行日期、经由线路和站序整理为 358 个文件。网页按车号下载所需文件，Mac 直接读取安装包。遇到缺段时，网页标出区间，连续的乘车区间可单独导出。Mac 可以从沿线瓦片补查。时刻表所列时间为排图时刻。

明信片保留暖红、铁路蓝和地图绿三款，增加旧式红纸票、蓝色磁介票、报销凭证纪念版、夜行和黑白线路卡。票面上的小图只画所选乘车区间。

## 资料和许可

车次、开行日历、停站和已有的轨迹取自 Jeremy Gao 的中国铁路 GTFS 2026-11-24 版。铁道漫游将 WGS84 轨迹分段、简化并编码。其他车次可复用具有相同经由、站序、分段里程的轨迹。[GTFS 发布包](https://github.com/wensimehrp/chinese-railway-gtfs/releases/tag/gtfs-20261124-112841) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)

其余地理数据来自 © OpenStreetMap contributors，使用 HOT 中国铁路摘录和 OpenStreetMap France 的区域摘录。匹配器沿相连的轨道通过途经站所。跨海行程采用标有 `railway=ferry` 的粤海铁路轮渡。轮渡票价里程与航道的实际长度分别处理。中国铁路地图原站的线路图保留在站表中。轨道分组数据库可从本项目的 `Web/station-directory/paths` 获取，其中 OSM 派生数据库按 ODbL 1.0 提供。[OSM 署名](https://www.openstreetmap.org/copyright) · [区域摘录](https://download.openstreetmap.fr/extracts/asia/china/) · [轮渡几何](https://www.openstreetmap.org/way/25172513) · [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) · [站表来源](RELEASE_NOTES_0.8.8.md)
