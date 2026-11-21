const LocalRailCache = (() => {
  let worker, next = 0, loaded = false;
  const activeKey = "railway-atlas-cache-path", pending = new Map();
  function call(message) {
    if (!worker) {
      worker = new Worker("./cache-worker.mjs",{type:"module"});
      worker.onmessage = ({data}) => {
        const wait = pending.get(data.id);
        if (!wait) return;
        pending.delete(data.id);
        if (data.error) wait.reject(Error(data.error)); else wait.resolve(data.value);
      };
      worker.onerror = () => {
        pending.forEach(wait => wait.reject(Error("浏览器无法打开离线瓦片库，请在支持 OPFS 的浏览器重试。")));
        pending.clear();
        worker.terminate(); worker = null; loaded = false;
      };
    }
    return new Promise((resolve,reject) => {
      const id = ++next;
      pending.set(id,{resolve,reject}); worker.postMessage({...message,id});
    });
  }
  async function activate(file) {
    const current = readStored(activeKey,null);
    if (!current && !file) return;
    const path = file ? (current === "/cache-a" ? "/cache-b" : "/cache-a") : current;
    const label = $("cacheStatus"), input = $("railCacheFile");
    input.disabled = true;
    label.textContent = file ? "正在复制并校验本机瓦片库…" : "正在读取离线瓦片…";
    try {
      if (file && (file.size < 512 || file.size > 4000000000)) throw Error("文件大小超出支持范围（512 字节至 4 GB）。");
      const count = await call({type:file ? "import":"restore",file,path});
      loaded = true; writeStored(activeKey,path);
      label.textContent = `本机缓存有 ${count.toLocaleString()} 条瓦片记录。`;
      RailMapLayers.toggle(true);
    } catch (e) { label.textContent = `载入失败。${e.message}`; }
    finally { input.disabled = false; }
  }
  function setup() {
    $("railCacheFile").onchange = event => {
      const file = event.target.files[0]; event.target.value="";
      if (file) activate(file);
    };
    activate();
  }
  return {setup, match:(plan,stops)=>call({type:"match",plan,stops}), read:(coords) => loaded ? call({type:"tile",x:coords.x,y:coords.y,z:coords.z}) : Promise.resolve([]),
    get loaded() { return loaded; }};
})();
