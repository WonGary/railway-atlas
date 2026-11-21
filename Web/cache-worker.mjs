import initSQLite from "./vendor/sqlite/index.mjs";
import {matchCache} from "./track-match.mjs";
import {decode} from "./vendor/vector.mjs";

let pool, database;
async function openPool() {
  if (!pool) {
    const sqlite = await initSQLite({print(){},printErr(){}});
    pool = await sqlite.installOpfsSAHPoolVfs({name:"railway-cache", directory:".railway-atlas-cache", initialCapacity:4});
  }
}
function openCache(path) {
  const db = new pool.OpfsSAHPoolDb(path,"r");
  try {
    db.exec("PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;");
    if (db.selectValue("PRAGMA application_id") !== 1380013132 ||
        db.selectValue("SELECT type FROM sqlite_schema WHERE name='tiles'") !== "table") throw Error("文件不是 Railway Atlas 瓦片缓存。");
    db.selectValue("SELECT length(data) FROM tiles WHERE z=4 AND x=12 AND y=5 LIMIT 1");
    return db;
  } catch (error) { db.close(); throw error; }
}
async function command({type, file, path, z, x, y, plan, stops}) {
  await openPool();
  if (type === "match") {
    if (!database) throw Error("请先导入铁路 .railcache 瓦片库。");
    return matchCache(database,decode,plan,stops);
  }
  if (type === "import" || type === "restore") {
    const allowed = ["/cache-a","/cache-b"];
    if (!allowed.includes(path)) throw Error("缓存名称无效。");
    if (type === "import") {
      let offset = 0;
      await pool.importDb(path, async () => {
        if (offset >= file.size) return;
        const next = await file.slice(offset,offset+1048576).arrayBuffer();
        offset += next.byteLength;
        return next;
      });
    }
    const next = openCache(path);
    let count;
    try { count = next.selectValue("SELECT count(*) FROM tiles"); }
    catch (error) { next.close(); throw error; }
    database?.close(); database = next;
    return count;
  }
  if (type === "tile" && database) {
    // The native primary key starts with source and layer. Use complete keys
    // for indexed lookup even on a several-hundred-megabyte imported cache.
    const candidates = [
      ["https://openrailwaymap.app", "railway_line_high,railway_text_km"],
      ["https://openrailwaymap.app","standard_railway_text_stations,standard_railway_grouped_stations,standard_railway_grouped_station_areas,standard_station_entrances,standard_railway_stop_positions,standard_interlocking,standard_interlocking_text"],
      ["https://openrailwaymap.app","standard_railway_text_stations_med"],
      ["https://openrailwaymap.app","standard_railway_text_stations_low"],
      ["https://openfreemap.org","atlas_openmaptiles_v1"],["https://tiles.openfreemap.org","atlas_openmaptiles_v1"],
      ["https://tiles.versatiles.org","atlas_shortbread_v1"],["https://openrailwaymap.app","speed_railway_line_low"]
    ];
    const result = [];
    for (const [source,layer] of candidates) {
      const bytes = database.selectValue("SELECT data FROM tiles WHERE source=? AND layer=? AND z=? AND x=? AND y=? AND length(data)<=12000000",
        [source,layer,z,x,y]);
      if (bytes?.length) result.push(bytes);
    }
    return result;
  }
  return [];
}
let queue = Promise.resolve();
self.onmessage = ({data}) => {
  queue = queue.then(async () => {
    try {
      const value = await command(data);
      self.postMessage({id:data.id,value}, data.type === "tile" ? value.map(bytes=>bytes.buffer) : []);
    } catch (error) { self.postMessage({id:data.id,error:error.message}); }
  });
};
