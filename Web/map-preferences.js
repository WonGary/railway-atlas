// Keys match the native map configuration. Keep browser-only data sources explicit.
const AtlasPrefs = (() => {
  const categories = {
    speed350:["350+ km/h","#d7303f"], speed300:["300–349 km/h","#e96825"], speed250:["250–299 km/h","#b58b00"],
    speed200:["200–249 km/h","#39864a"], speed160:["160–199 km/h","#007f99"], below160:["低于 160 km/h","#3972c3"],
    unknown:["速度未知","#76818c"], urban:["城市轨道","#526672"], freight:["货运专线","#8b5aa6"], branch:["地方支线","#93704c"],
    service:["站场与联络轨道","#a8b0b6"], construction:["在建与规划","#f2c94c"], disused:["停用","#877d8d"], abandoned:["废弃与拆除","#827a73"]
  };
  const networks = {railway:"铁路",metro:"地铁",lightRail:"轻轨与单轨",tram:"有轨电车",industrial:"工业与专用铁路",narrowGauge:"窄轨",other:"其他轨道"};
  const minZoom = {urban:8,metro:8,lightRail:8,tram:8,freight:8,branch:8,industrial:9,narrowGauge:9,construction:10,disused:10,abandoned:10,service:15};
  // Keep both native opacity keys. Old exports can be read without a migration.
  const surfaceGroups = [
    ["panelBackgroundOpacity", "panel", "工作区", 1],
    ["inspectorBackgroundOpacity", "inspector", "要素栏与问答栏", 1],
    ["topbarOpacity", "topbar", "顶部栏", .84],
    ["playbackOpacity", "playback", "旅行播放栏", .88],
    ["legendOpacity", "legend", "图例与缩放按钮", .88],
    ["infoOpacity", "info", "地图信息浮窗与对话框", .88],
    ["statusOpacity", "status", "地图状态、比例尺与版权条", .82],
    ["noticeOpacity", "notice", "地图提示", .88]
  ];
  const surfaceDefaults = Object.fromEntries(surfaceGroups.map(([field,,,initial]) => [field,initial]));
  const surfaceModes = {glass:"玻璃感（默认）",translucent:"半透明",text:"纯文字（无底色）"};
  const defaults = {
    automaticDetail:true,showsNationalMetroOverview:true,showsStations:true,showsStationLayouts:true,showsLabels:true,showsMetroColors:true,prioritizesUrbanTransit:false,
    showsStationOutlines:true,showsConcourses:true,showsPlatforms:true,showsPassengerPassages:true,showsPlatformNumbers:true,
    showsStationEntrances:true,showsPassageSigns:true,
    categories:Object.keys(categories),networks:Object.keys(networks),forcedCategories:[],forcedNetworks:[],hiddenRoutes:[],
    metroWidthScale:1,railwayWidthScale:1,stationRadiusMultiplier:1.25,depotBrightness:.5,railwayPattern:true,viewportBuffer:.2,
    basemapDarkness:0,mapAppearance:"system",mode:"online",uiScale:1,panelWidth:320,inspectorWidth:380,panelSize:"medium",panelLayout:"floating",
    inspectorLayout:"docked",panelVisible:false,statusVisible:true,surfaceMode:"glass",surfaceGroupOpacity:1,...surfaceDefaults,
    assistantPresentation:"sidebar",statusX:0,statusY:0,focusColor:"#D45212"
  };
  const ranges = {metroWidthScale:[.5,2],railwayWidthScale:[.5,2],stationRadiusMultiplier:[.5,3],depotBrightness:[.1,1],
    viewportBuffer:[0,.5],basemapDarkness:[0,1],uiScale:[.75,1.6],panelWidth:[250,560],inspectorWidth:[200,560],
    surfaceGroupOpacity:[0,1],...Object.fromEntries(surfaceGroups.map(([field]) => [field,[0,1]])),statusX:[-2000,2000],statusY:[-2000,2000]};
  const enums = {mode:["online","cached","offline"],mapAppearance:["system","light","dark"],panelSize:["small","medium","large"],panelLayout:["floating","docked"],
    inspectorLayout:["floating","docked"],assistantPresentation:["sidebar","floating","window"],surfaceMode:Object.keys(surfaceModes)};
  const key = "railway-atlas-map-settings-v1";
  let p = {...defaults}, filter = "";
  const make = (tag, text) => Object.assign(document.createElement(tag), text == null ? {} : {textContent:text});
  function validated(input) {
    const result = {...defaults};
    for (const k of Object.keys(defaults)) {
      if (!Object.hasOwn(input,k)) continue;
      const val = input[k], d = defaults[k];
      let ok;
      if (Array.isArray(d)) {
        const allowed = k.toLowerCase().includes("categor") ? categories : k.toLowerCase().includes("network") ? networks : null;
        ok = Array.isArray(val) && val.length <= 10000 && val.every(v => typeof v === "string" && v.length <= 500 && (!allowed || Object.hasOwn(allowed,v)));
      } else if (ranges[k]) ok = Number.isFinite(val) && val >= ranges[k][0] && val <= ranges[k][1];
      else if (enums[k]) ok = enums[k].includes(val);
      else if (k==="focusColor") ok=typeof val==="string" && /^#[0-9a-f]{6}$/i.test(val);
      else ok = typeof val === "boolean";
      if (!ok) throw Error(`地图设置字段无效：${k}`);
      result[k] = Array.isArray(val) ? [...new Set(val)] : val;
    }
    return result;
  }
  function restore() {
    const saved = readStored(key,null);
    try { p = validated(saved || {}); } catch { p = {...defaults}; }
    if (!saved && !readStored(STORAGE.layers,null)) p.mapAppearance = "dark";
    applySurface();
    MapWindows.setup();
  }
  function persist() { writeStored(key,p); }
  function classify(t, urbanHint = false) {
    const lifecycle = ["abandoned","razed","disused","construction","proposed","planned"].find(k =>
      [t.state,t.status,t.railway,t.feature,t.subclass,t.route].includes(k) ||
      [t[k],t[`${k}:railway`],t[`${k}:route`],t[`railway:${k}`]].some(v => v && !/^(no|0|false|none)$/i.test(String(v))));
    const kinds = [t["construction:railway"],t["proposed:railway"],t["railway:construction"],t["railway:proposed"],t["construction:route"],t["proposed:route"],
      t.construction,t.proposed,t.railway,t.feature,t.subclass,t.kind,t.station,t.route,t.route_type,t["disused:railway"],t["abandoned:railway"]];
    const type = kinds.find(v=>["light_rail","monorail","tram","subway","narrow_gauge","funicular","miniature"].includes(v));
    const network = {light_rail:"lightRail",monorail:"lightRail",subway:"metro",tram:"tram",narrow_gauge:"narrowGauge",funicular:"other",miniature:"other"}[type]
      || (urbanHint ? "metro" : /^(industrial|military|test)$/.test(t.usage) || t.service==="spur" || t.ownership==="private" ? "industrial" : "railway");
    const urban = ["lightRail","metro","tram"].includes(network);
    let category;
    if (lifecycle) category = lifecycle==="disused" ? "disused" : ["abandoned","razed"].includes(lifecycle) ? "abandoned" : "construction";
    else if (urban) category = "urban";
    else if (t.service && t.service !== "no" || t.depot==="yes") category = "service";
    else if (["freight","industrial"].includes(t.usage) || t["railway:traffic_mode"]==="freight" || t.freight==="yes" && t.passenger==="no") category = "freight";
    else if (t.usage==="branch") category = "branch";
    else {
      const speeds = [t.maxspeed,t["maxspeed:forward"],t["maxspeed:backward"]].flatMap(v=>String(v ?? "").split(";"))
        .map(v=>v.trim().match(/^(\d+(?:\.\d+)?)\s*(mph|km\/h|kmh|kph)?$/i)).filter(Boolean)
        .map(m=>Number(m[1]) * (m[2]?.toLowerCase()==="mph" ? 1.609344 : 1));
      const speed = Math.max(...speeds);
      category = speeds.length ? [350,300,250,200,160].map(n=>speed>=n ? "speed"+n : "").find(Boolean) || "below160" : "unknown";
    }
    return {network,category,urban,priority:urban || /^(commuter|suburban)$/.test(t.service || t.train || "")};
  }
  function visible(f, z, {overview=false, station=false}={}) {
    if (station && !p.showsStations) return false;
    if (p.mode==="offline" && overview) return false;
    if (overview && f.urban && !p.showsNationalMetroOverview) return false;
    const priority = p.prioritizesUrbanTransit && f.priority;
    const lifecycle = ["construction","disused","abandoned"].includes(f.category);
    if ((!priority && !p.networks.includes(f.network)) || ((!priority || lifecycle) && (!station || lifecycle) && !p.categories.includes(f.category))) return false;
    if (!p.automaticDetail) return true;
    if (station && z<8) return false;
    const sourceOverview = overview && f.urban && p.showsNationalMetroOverview;
    return (sourceOverview || p.forcedNetworks.includes(f.network) || z >= (minZoom[f.network] || 0)) &&
      (station && !lifecycle || sourceOverview && !lifecycle || p.forcedCategories.includes(f.category) || z >= (minZoom[f.category] || 0));
  }
  function routeKey(city,r) {
    return r.tags?.["atlas:paletteIdentity"] || r.tags?.["atlas:routeMaster"] ||
      `${city}|${r.ref || r.tags?.ref || r.id}`;
  }
  const resolvedRoutes = new Map();
  function indexRoutes() {
    resolvedRoutes.clear();
    for (const {city,route:r} of state.metroRecords) resolvedRoutes.set(r.id,routeKey(city,r));
    for (const d of state.metroDetails.values()) for (const r of d.routes) if (!resolvedRoutes.has(r.id)) resolvedRoutes.set(r.id,routeKey(d.name,r));
  }
  const visibleRoute = (city,r) => !p.hiddenRoutes.includes(resolvedRoutes.get(r.id) || routeKey(city,r));
  function applySurface() {
    const root = document.documentElement;
    root.dataset.uiSurfaceMode = p.surfaceMode;
    root.toggleAttribute("data-apple-ui", /Mac|iPad|iPhone|iPod/i.test(navigator.platform));
    for (const [field,group] of surfaceGroups) root.style.setProperty(`--ui-alpha-${group}`, p[field] * p.surfaceGroupOpacity);
  }
  function apply(redraw=true) {
    const root = document.documentElement.style, shell = document.querySelector(".app-shell");
    root.setProperty("--left-size",p.panelWidth+"px"); root.setProperty("--right-size",p.inspectorWidth+"px");
    root.setProperty("--ui-scale",p.uiScale); root.setProperty("--left-height",({small:"43%",medium:"70%",large:"96%"})[p.panelSize]);
    shell.dataset.leftLayout=p.panelLayout; shell.dataset.rightLayout=p.inspectorLayout;
    applySurface();
    const status=document.querySelector(".map-status");status.hidden=!p.statusVisible;
    if (!state.map) return;
    $("basemapModeNote").hidden=p.mode==="online";
    $("baseLayer").disabled=$("darkStreetPreset").disabled=p.mode!=="online";
    updateBasemapAppearance();
    StationLabels.schedule();
    $("assistantPanel").classList.toggle("floating",p.assistantPresentation==="floating");
    if (redraw) {setBaseLayer($("baseLayer").value); drawMetro(); RailMapLayers.toggle(true);LineFocus.refresh();recolorJourney();}
    requestAnimationFrame(()=>state.map.invalidateSize({pan:false}));
  }
  function change(k,v,redraw=true) {
    p[k]=v;persist();
    if (k==="surfaceMode" || Object.hasOwn(surfaceDefaults,k)) applySurface();
    else if (k==="focusColor") {
      recolorJourney();LineFocus.refresh();
      for (const b of document.querySelectorAll("[data-focus-ink]")) b.setAttribute("aria-pressed",b.dataset.focusInk===v.toUpperCase());
      const picker=$("pref-focusColor");if(picker)picker.value=v;
    } else apply(redraw);
  }
  function section(parent,id,title,open=true) {
    const d=make("details");d.append(make("summary",title)); const old=readStored("railway-atlas-layer-folds",{});
    d.open=old[id] ?? open; d.ontoggle=()=>writeStored("railway-atlas-layer-folds",{...readStored("railway-atlas-layer-folds",{}),[id]:d.open});
    parent.append(d);return d;
  }
  function check(parent,id,title,on,callback) {
    const label=make("label");label.className="toggle-row";const input=make("input");input.type="checkbox";input.id="pref-"+id;
    input.checked=on;input.onchange=()=>callback(input.checked);label.append(input,document.createTextNode(title));parent.append(label);
  }
  function button(parent,title,callback) {const b=make("button",title);b.type="button";b.className="text-button";b.onclick=callback;parent.append(b);}
  function routeList() {
    const box=$("routeVisibility");if (!box) return; box.replaceChildren();indexRoutes();
    const byKey = new Map();
    function add(city,r) { const k=resolvedRoutes.get(r.id), name=`${city} · ${r.ref || r.tags?.ref || r.name}`;if (!byKey.has(k)) byKey.set(k,name); }
    for (const {city,route} of state.metroRecords) add(city,route);
    for (const detail of state.metroDetails.values()) for (const r of detail.routes) add(detail.name,r);
    const rows=[...byKey].filter(([,name])=>name.toLowerCase().includes(filter.toLowerCase())).sort((a,b)=>a[1].localeCompare(b[1],"zh"));
    const render=(start=0)=>{for (const [k,n] of rows.slice(start,start+60)) check(box,"route-"+k,n,!p.hiddenRoutes.includes(k),on=>{
      change("hiddenRoutes",on?p.hiddenRoutes.filter(v=>v!==k):[...new Set([...p.hiddenRoutes,k])]);
    });if(rows.length>start+60)button(box,"继续显示",e=>{e.target.remove();render(start+60);});};render();
  }
  function controls() {
    const l=$("mapLayers"),s=$("mapSettings");l.replaceChildren();s.replaceChildren();
    const basemap=$("basemapDisplayControls"), station=$("stationDisplayControls");
    basemap.replaceChildren();station.replaceChildren();
    const toggle=(parent,k,title,redraw)=>check(parent,k,title,p[k],on=>change(k,on,redraw));
    function range(parent,k,title,step,redraw=true){
      const label=make("label",title+" "),output=make("output",String(p[k])),input=make("input");
      Object.assign(input,{id:"pref-"+k,type:"range",min:ranges[k][0],max:ranges[k][1],step,value:p[k]});
      input.oninput=()=>{output.value=input.value;};input.onchange=()=>change(k,Number(input.value),redraw);label.append(output,input);parent.append(label);
    }
    function select(parent,k,title,values,callback) {
      const label=make("label",title),el=make("select");el.id="pref-"+k;
      for (const [v,n] of Object.entries(values)) el.add(new Option(n,v));el.value=p[k];
      el.onchange=()=>{change(k,el.value,k==="mode");callback?.();};label.append(el);parent.append(label);
    }
    select(basemap,"mapAppearance","地图外观",{system:"跟随系统",light:"浅色",dark:"深色"});
    range(basemap,"basemapDarkness","底图暗化",.05,false);
    const vis=section(l,"visibility","线路显示");
    toggle(vis,"automaticDetail","随缩放调整图层");toggle(vis,"showsNationalMetroOverview","全国城市轨道概览");
    const updater=make("button","检查城轨增量更新");updater.id="updateNationalMetro";updater.className="text-button";updater.type="button";
    updater.onclick=()=>MetroUpdates.sync();vis.append(updater);
    const edition=make("p");edition.id="metroUpdateStatus";edition.className="panel-note";edition.setAttribute("role","status");vis.append(edition);MetroUpdates.status();
    toggle(vis,"prioritizesUrbanTransit","优先显示都市轨道");toggle(station,"showsStations","车站位置");toggle(station,"showsLabels","放大后显示站名");
    toggle(station,"showsStationLayouts","站区细节",false);
    const detailControls=make("div");detailControls.id="stationDetailOptions";station.append(detailControls);
    for (const [key,title] of [["showsStationOutlines","车站轮廓 · Z14"],["showsConcourses","站厅轮廓 · Z15"],["showsPlatforms","站台（面、线或点）· Z15"],
      ["showsPassengerPassages","乘客通道 · Z16"],["showsPlatformNumbers","站台号 · Z16"],
      ["showsStationEntrances","出入口与方向 · Z16"],["showsPassageSigns","通道标识 · Z16"]]) toggle(detailControls,key,title,false);
    const load=make("button","重新查询当前站区");load.className="text-button";load.type="button";load.id="loadStationLayouts";load.hidden=true;
    load.onclick=StationLayoutLayer.supplement;station.append(load);
    const detailStatus=make("p");detailStatus.className="panel-note";detailStatus.id="stationLayoutStatus";detailStatus.hidden=true;
    detailStatus.setAttribute("role","status");station.append(detailStatus);
    toggle(vis,"showsMetroColors","使用地铁线路色");
    function preset(high) {p.categories=high?Object.keys(categories).slice(0,4):Object.keys(categories);p.forcedCategories=high?[]:[...p.categories];persist();controls();apply();}
    button(vis,"全部显示",()=>preset(false));button(vis,"仅高铁",()=>preset(true));
    for(const [group,title,entries] of [["categories","速度、用途与状态",Object.entries(categories).map(([k,v])=>[k,v[0]])],["networks","轨道网络",Object.entries(networks)]]) {
      const target=section(l,group,title,false), forced=group==="networks"?"forcedNetworks":"forcedCategories";
      for(const [k,n] of entries)check(target,k,n,p[group].includes(k),on=>{
        p[group]=p[group].filter(v=>v!==k);p[forced]=p[forced].filter(v=>v!==k);
        if(on){p[group].push(k);p[forced].push(k);}persist();apply();
      });
    }
    const lines=section(l,"lines","逐线显示城市轨道",false);
    const search=make("input");search.type="search";search.placeholder="搜索城市或线路";search.value=filter;
    search.oninput=()=>{filter=search.value;routeList();};lines.append(search);
    button(lines,"显示全部城市线路",()=>{p.hiddenRoutes=[];p.categories=[...new Set([...p.categories,"urban"])];p.networks=[...new Set([...p.networks,"metro","lightRail","tram"])];persist();controls();apply();});
    const list=make("div");list.id="routeVisibility";lines.append(list);routeList();
    const surfaces=section(s,"surfaces","浮窗外观");
    select(surfaces,"surfaceMode","表面模式",surfaceModes);
    const opacityControls=make("fieldset");
    opacityControls.className="surface-ranges";
    opacityControls.append(make("legend","背景透明度（100%为全透明）"));
    const syncRanges=[];
    const allLabel=make("label","全部地图界面"), allInput=make("input"), allOutput=make("output");
    Object.assign(allInput,{id:"pref-surfaceGroupOpacity",type:"range",min:0,max:100,step:1});
    const syncAll=()=>{
      allInput.value=String(Math.round((1-p.surfaceGroupOpacity)*100));
      allOutput.value=allInput.value+"%";
      allInput.setAttribute("aria-valuetext",allOutput.value);
    };
    allInput.oninput=()=>{
      p.surfaceGroupOpacity=1-allInput.valueAsNumber/100;
      syncAll();applySurface();
    };
    allInput.onchange=persist;
    syncAll();allLabel.append(allOutput,allInput);opacityControls.append(allLabel);
    for (const [field,,title] of surfaceGroups) {
      const row=make("label",title), input=make("input"), output=make("output");
      Object.assign(input,{id:"pref-"+field,type:"range",min:0,max:100,step:1});
      row.htmlFor=input.id;
      output.setAttribute("for",input.id);
      function sync() {
        input.value=String(Math.round((1-p[field])*100));
        output.value=input.value+"%";
        input.setAttribute("aria-valuetext",output.value);
      }
      input.oninput=()=>{
        p[field]=1-input.valueAsNumber/100;
        sync();
        applySurface();
      };
      input.onchange=persist;
      sync();syncRanges.push(sync);
      row.append(output,input);opacityControls.append(row);
    }
    surfaces.append(opacityControls);
    button(surfaces,"恢复浮窗默认外观",()=>{
      Object.assign(p,surfaceDefaults,{surfaceMode:defaults.surfaceMode});
      p.surfaceGroupOpacity=defaults.surfaceGroupOpacity;
      $("pref-surfaceMode").value=p.surfaceMode;
      syncAll();syncRanges.forEach(sync=>sync());applySurface();persist();
    });
    const source=section(s,"source","地图模式");select(source,"mode","数据来源",{online:"在线与本机缓存",cached:"仅随包与本机缓存",offline:"仅区域地图"});
    const render=section(s,"render","地图绘制");
    button(render,"调整底图与站点",openBasemap);
    const palette=make("fieldset");palette.className="focus-palette";palette.append(make("legend","旅行与无配色要素的高亮色"));
    for (const [name,hex] of [["朱橙","#D45212"],["湖蓝","#237BB5"],["青碧","#008778"],["鸢紫","#8057AB"],["玫红","#BE4771"],["琥珀","#B98213"]]) {
      const b=make("button");b.type="button";b.title=name;b.setAttribute("aria-label",name);b.dataset.focusInk=hex;
      b.setAttribute("aria-pressed",p.focusColor.toUpperCase()===hex);b.style.backgroundColor=hex;
      b.onclick=()=>change("focusColor",hex,false);palette.append(b);
    }
    const label=make("label","自定义 "),picker=make("input");picker.type="color";picker.id="pref-focusColor";picker.value=p.focusColor;
    picker.oninput=()=>change("focusColor",picker.value.toUpperCase(),false);label.append(picker);palette.append(label);render.append(palette);
    range(render,"railwayWidthScale","铁路线宽",.05);range(render,"metroWidthScale","地铁线宽",.05);range(render,"stationRadiusMultiplier","站点半径",.05);
    toggle(render,"railwayPattern","铁路轨枕纹理");range(render,"depotBrightness","站场轨道亮度",.05);range(render,"viewportBuffer","视野边缘预绘制比例",.05);
    const ui=section(s,"ui","界面与面板",false);range(ui,"uiScale","界面缩放",.05,false);
    toggle(ui,"panelVisible","桌面打开地图时展开工作区",false);
    select(ui,"panelLayout","左栏布局",{floating:"浮窗",docked:"贴边分屏"});select(ui,"panelSize","左侧浮窗高度",{small:"小",medium:"中",large:"大"});
    range(ui,"panelWidth","左栏宽度",1,false);
    select(ui,"inspectorLayout","右栏布局",{floating:"浮窗",docked:"贴边分屏"});range(ui,"inspectorWidth","右栏宽度",1,false);
    toggle(ui,"statusVisible","在图例中显示地图状态",false);
    select(ui,"assistantPresentation","地图问答位置",{sidebar:"右侧面板",floating:"地图浮窗",window:"独立窗口"});
  }
  function openBasemap(){
    setWorkspaceView("layers");
    $("basemapPanel").open=true;
    $("basemapPanel").scrollIntoView({block:"start"});
    $("baseLayer").focus({preventScroll:true});
  }
  function setup(){
    controls();apply(false);
    MapWindows.attachMap(state.map);
    const legend=$("speedLegend");
    for (const key of ["speed350","speed300","speed250","speed200","speed160","below160","unknown"]) {
      const [name,color]=categories[key], row=make("span"), line=make("i");
      line.className="legend-line";line.style.borderColor=color;
      row.append(line,document.createTextNode(name));legend.append(row);
    }
    $("goToBasemap").onclick=openBasemap;
    $("darkStreetPreset").onclick=()=>{
      p.mapAppearance="dark";p.basemapDarkness=0;persist();
      setBaseLayer("versatiles-vector");controls();apply(false);
    };
    $("exportMapSettings").onclick=()=>downloadFile("铁道漫游-地图设置.json",new Blob([JSON.stringify({version:1,mapPreferences:p,baseLayer:$("baseLayer").value},null,2)],{type:"application/json"}));
    $("importMapSettings").onchange=async e=>{
      const file=e.target.files[0];e.target.value="";if(!file)return;
      try {
        if(file.size>1048576)throw Error("设置文件上限为 1 MB。");
        const data=JSON.parse(await file.text());
        if(data.version!==1 || !(data.mapPreferences || data.layers || data.rendering || data.interface || data.map))throw Error("请选择地图设置 JSON。");
        const native=!data.mapPreferences;
        const settings=native?{...data.layers,...data.rendering,...data.interface,basemapDarkness:data.map?.basemapDarkness ?? 0,mode:({apple:"online",cached:"cached",offline:"offline"})[data.map?.mode] || "online"}:data.mapPreferences;
        const next=validated(settings);
        const standard=({versaTiles:"versatiles-vector",openFreeMap:"openfreemap-vector",openStreetMap:"osm"})[data.map?.standardBasemapSource] || "osm";
        const base=native?({satellite:"satellite",hybrid:"hybrid",standard})[data.map?.basemapStyle]:data.baseLayer;
        p=next;if(base && Object.hasOwn(state.baseLayers,base))$("baseLayer").value=base;
        persist();controls();apply();showToast("地图设置已导入。");
      }catch(error){showToast(error.message);}
    };
  }
  return {get value(){return p;},categories,visible,classify,restore,setup,routeList,visibleRoute,routeKey,indexRoutes,change,apply};
})();

// Fold only the presentation. The app owns actual closure, selection and playback.
const MapWindows = (() => {
  const folded = new Map();
  const buttonFor = el => el.querySelector("[data-fold]");
  function adjustTopbar(el, foldedState) {
    if (el.id !== "mapTopbar") return;
    if (foldedState) document.documentElement.style.setProperty("--bar-height", "0px");
    else document.documentElement.style.removeProperty("--bar-height");
  }
  function forget(el) {
    const chip=folded.get(el);
    if (!chip) return;
    folded.delete(el);chip.remove();
    el.removeAttribute("data-ui-folded");
    adjustTopbar(el, false);
    buttonFor(el)?.setAttribute("aria-expanded","true");
  }
  function expand(el) {
    forget(el);
    if (el instanceof HTMLDialogElement && !el.open) el.showModal();
    buttonFor(el)?.focus({preventScroll:true});
  }
  function fold(el) {
    if (folded.has(el)) return;
    const name=el.dataset.windowName, chip=document.createElement("button");
    chip.type="button";chip.textContent=name;
    chip.className="ui-restore";
    chip.setAttribute("aria-label","展开"+name);
    chip.setAttribute("aria-controls",el.id);
    chip.setAttribute("aria-expanded","false");
    chip.onclick=()=>expand(el);
    folded.set(el,chip);
    $("uiShelf").append(chip);
    buttonFor(el).setAttribute("aria-expanded","false");
    el.setAttribute("data-ui-folded","");
    adjustTopbar(el, true);
    // Closing the native top layer releases its backdrop and focus trap; form values stay in the DOM.
    if (el instanceof HTMLDialogElement) el.close();
    chip.focus({preventScroll:true});
  }
  function bind(el) {
    const button=buttonFor(el);
    button.type="button";
    button.setAttribute("aria-controls",el.id);
    button.setAttribute("aria-expanded","true");
    button.title="收起"+el.dataset.windowName;
    button.setAttribute("aria-label",button.title);
    button.onclick=event=>{event.stopPropagation();fold(el);};
  }
  function setup() {
    for (const el of document.querySelectorAll("[data-window-name]")) bind(el);
    const transientHidden = el => {
      if (el.classList.contains("map-notice-window")) return el.querySelector("p")?.hidden ?? true;
      if (el.id === "appToastWindow") return $("appToast")?.hidden ?? true;
      return false;
    };
    // Discard a restore chip if the app closes or reopens the underlying surface.
    const observer=new MutationObserver(()=>{
      for (const el of folded.keys()) {
        if (el.hidden || el.matches("dialog[open]") ||
            transientHidden(el) ||
            (el.id==="workspacePanel" && !el.closest(".workspace-open"))) forget(el);
      }
    });
    const observe=(el,attr)=>observer.observe(el,{attributes:true,attributeFilter:[attr]});
    for (const el of document.querySelectorAll("[data-window-name]")) {
      observe(el,el instanceof HTMLDialogElement ? "open" : "hidden");
      if (el.classList.contains("map-notice-window")) observe(el.querySelector("p"),"hidden");
      if (el.id === "appToastWindow") observe($("appToast"),"hidden");
    }
    observe(document.querySelector(".app-shell"),"class");
    for (const id of ["toggleWorkspace","toggleInfo","toggleAssistant"]) {
      const trigger=$(id), el=$(trigger.getAttribute("aria-controls"));
      trigger.addEventListener("click",event=>{
        if (!folded.has(el)) return;
        event.stopImmediatePropagation();expand(el);
      },true);
    }
  }
  function addFoldButton(el, id, title) {
    el.id=id;el.dataset.windowName=title;
    el.dataset.uiSurface=id==="mapScale" ? "status" : "legend";
    const button=document.createElement("button");
    button.className="collapse-button";button.dataset.fold="";button.textContent="−";
    el.append(button);bind(el);
  }
  function attachMap(map) {
    const zoom=map.zoomControl?.getContainer();
    if (zoom) addFoldButton(zoom,"mapZoomTools","缩放控件");
    const scale=map.getContainer().querySelector(".leaflet-control-scale");
    if (scale) {
      addFoldButton(scale,"mapScale","比例尺");
      L.DomEvent.disableClickPropagation(scale);
    }
    let popupId=0;
    map.on("popupopen",({popup})=>{
      const el=popup.getElement();
      [el,el?.querySelector(".leaflet-popup-content-wrapper"),el?.querySelector(".leaflet-popup-tip")]
        .filter(Boolean).forEach(part=>part.setAttribute("data-ui-surface","info"));
      if (!buttonFor(el)) addFoldButton(el,"mapPopup"+(++popupId),"地点资料");
    });
    map.on("popupclose",({popup})=>forget(popup.getElement()));
    // Docked panels and the restore shelf change the actual map viewport size.
    // Painting a slider has no effect on this observer.
    if (typeof ResizeObserver==="function") {
      const observer=new ResizeObserver(()=>map.invalidateSize({pan:false,debounceMoveend:true}));
      observer.observe(map.getContainer());
      map.once("unload",()=>observer.disconnect());
    }
  }
  return {setup,attachMap};
})();
