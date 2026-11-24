const StationPanel = (() => {
  let nationalIndex, lastLibrary, localIndex;
  const node = (tag,text,cls) => {
    const el=document.createElement(tag);
    if (text != null) el.textContent=text;
    if (cls) el.className=cls;
    return el;
  };
  function link(title,href) {
    const el=node("a",title);
    el.href=href; el.target="_blank"; el.rel="noopener noreferrer";
    return el;
  }
  function button(text,action) {
    const el=node("button",text);
    el.type="button"; el.onclick=action;
    return el;
  }
  function disclosure(parent,label,draw) {
    const box=node("details"), summary=node("summary",label);
    box.append(summary); parent.append(box);
    box.ontoggle=()=>{
      if (!box.open || box.children.length>1) return;
      const body=node("div"); box.append(body); draw(body);
    };
    return box;
  }
  const geo="http://cnrail.geogv.org/zhcn/";
  function mount(root, rawName, options={}) {
    root.classList.add("station-directory");
    nationalIndex ||= StationCatalog.national(globalThis.atlasRailDirectory);
    const station=StationCatalog.resolve(rawName,nationalIndex);
    const base=nationalIndex, original=globalThis.atlasGeoGV?.stations[station];
    const source = node("select");
    source.setAttribute("aria-label","站表来源");
    const nationwide=new Option("全国铁路时刻与线路","national");
    source.add(nationwide);
    if (options.library) {
      if (lastLibrary!==options.library) { localIndex=StationCatalog.local(options.library); lastLibrary=options.library; }
      source.add(new Option("本机时刻库与列车径路","local"));
      if (localIndex.stations.has(StationCatalog.resolve(rawName,localIndex))) source.value="local";
    }
    if (original) source.add(new Option("中国铁路地图原站快照","original"));
    const local=options.library ? localIndex : null;
    const date=node("input"); date.type="date";
    date.value=options.date || new Intl.DateTimeFormat("sv-SE",{timeZone:"Asia/Shanghai"}).format(new Date());
    const dateLabel=node("label","本站日期 "); dateLabel.append(date);
    const controls=node("div",null,"directory-controls"); controls.append(source,dateLabel);
    const content=node("div"), credits=node("details");
    credits.append(node("summary","资料来源与日期"));
    const notes=node("p",`全国铁路快照 ${base.edition}，按本站日期查询。时刻为排图，出行前请核对 12306。`);
    notes.append(" ",link("Jeremy Gao · CC BY 4.0","https://github.com/wensimehrp/chinese-railway-gtfs"),
      " · ",link("OpenStreetMap 贡献者","https://www.openstreetmap.org/copyright"));
    const note2=node("p","中国铁路地图 · Kejing Peng。线路图和班表分别保留原站的站序及更新日期。");
    note2.append(" ",link("中国铁路地图",original ? geo+"geo/"+original.id : geo),
      " · ",link("CC BY-SA 4.0","https://creativecommons.org/licenses/by-sa/4.0/"));
    credits.append(notes,note2);
    root.replaceChildren(controls,content,credits);

    function current() { return source.value==="local" ? local : base; }
    function trainDetail(panel, data, origin) {
      panel.append(node("p",`${data.number}　${data.stops[0][0]} → ${data.stops.at(-1)[0]} · ${data.stops.length} 个停站`));
      if (origin) panel.append(node("small",`始发日期 ${origin}，跨日停站以 +1日、+2日 标注。`));
      const list=node("ol",null,"rail-sequence");
      for (const [i,[name,a,b]] of data.stops.entries()) {
        const row=node("li"); if (name===station) row.className="here";
        row.append(node("span",name),node("small",`${i ? StationCatalog.clock(a) : "始发"} / ${i+1<data.stops.length ? StationCatalog.clock(b) : "终到"}`));
        list.append(row);
      }
      panel.append(list);
      let plan=data.plan;
      // A schedule can use the imported routing only when every stop and both clocks agree.
      if (!plan && local && options.library) {
        const same=(options.library.servicesByTrain.get(data.number) || []).filter(row=>
          RailLibrary.runsOn(row,origin) && row.stops.length===data.stops.length &&
          row.stops.every((s,i)=>s.station===data.stops[i][0] && (s.arrival??null)===(data.stops[i][1]??null) &&
            (s.departure??null)===(data.stops[i][2]??null)));
        if (same.length===1) plan=same[0].routing || RailLibrary.plan(same[0],options.library);
      }
      if (plan?.edges?.length) {
        const spans=[];
        plan.edges.forEach((edge,i)=>{
          if (!spans.length || spans.at(-1).line!==edge.lineName) spans.push({line:edge.lineName,start:i,end:i+1});
          else spans.at(-1).end=i+1;
        });
        disclosure(panel,`经由 ${spans.length} 段线路 · ${plan.nodes.length} 个站所`, body=>{
          for (const span of spans) {
            body.append(node("strong",`${span.line}　${plan.nodes[span.start].station} → ${plan.nodes[span.end].station}`));
            body.append(node("p",plan.nodes.slice(span.start,span.end+1).map(s=>s.station).join(" → ")));
          }
        });
      } else panel.append(node("small","这份时刻资料未列出该车次的经由线路。"));
      const primary=data.number.split("/")[0];
      if (/^[A-Z0-9]+$/.test(primary)) panel.append(link("在中国铁路地图核对车次",geo+"route/"+encodeURIComponent("CN/"+primary)));
    }
    function draw() {
      content.replaceChildren();
      const isOriginal=source.value==="original", catalog=current(), name=StationCatalog.resolve(rawName,catalog);
      dateLabel.hidden=isOriginal;
      const lines=isOriginal ? original.lines.map(([title,id])=>({title,stops:globalThis.atlasGeoGV.lines[id] || [],id})) :
        catalog.lines.get(name) || [];
      const section=node("section");
      section.append(node("h3",`途经线路 · ${lines.length}`)); content.append(section);
      for (const line of lines) {
        disclosure(section,`${line.title} · ${line.stops.length} 个站所`, body=>{
          if (line.stops.length) body.append(node("p",`${line.stops[0][0]} → ${line.stops.at(-1)[0]}`));
          if (line.id) body.append(link("原站全线图",geo+"rail/"+line.id));
          if (options.locate && line.stops.length) {
            const points=line.stops.map(([n])=>[n,options.coordinate?.(n)]).filter(([,p])=>p);
            if (points.length>1) body.append(button(`地图查看沿线站点（${points.length}）`,()=>options.locate(points)));
          }
          const list=node("ol",null,"rail-sequence");
          line.stops.forEach(([n,km,note])=>{
            const row=node("li"); if (n===name) row.className="here";
            row.append(node("span",n),node("small",[km==null || km==="" ? "" : `${km}${Number.isFinite(Number(km)) ? " km" : ""}`,note].filter(Boolean).join(" · "))); list.append(row);
          });
          body.append(list);
        });
      }
      if (!lines.length) section.append(node("small","这份资料未收录本站所属线路。"));
      const heading=node("h3","本站车次"), filter=node("input");
      filter.type="search"; filter.placeholder="查车次、始发站或终到站"; filter.setAttribute("aria-label",filter.placeholder);
      let rows;
      if (isOriginal) {
        rows=original.trains.map(([number,from,to,arr,dep,route])=>({number,from,to,arr,dep,route}));
      } else {
        rows=catalog.board(name,date.value);
        rows.sort((a,b)=>Number(!!a.pass)-Number(!!b.pass) ||
          ((a.arr??a.dep??0)%1440)-((b.arr??b.dep??0)%1440) || a.number.localeCompare(b.number,"zh",{numeric:true}));
      }
      content.append(heading,node("small",isOriginal ? original.hasBoard ? `原站班表更新于 ${original.update || "未知日期"}` : "原站未提供本站班表。" :
        `${source.value==="local" ? "本机库" : "全国铁路快照"} ${catalog.edition} · ${date.value}`),filter);
      const status=node("p"), result=node("div"), pager=node("div",null,"directory-pager");
      status.setAttribute("role","status"); content.append(status,result,pager);
      if (!isOriginal && !rows.length && source.value==="national" &&
        (date.value.replaceAll("-","")<base.range[0] || date.value.replaceAll("-","")>base.range[1])) {
        content.append(node("small",`所选日期超出全国快照的开行日历（${base.range.join(" 至 ")}）。`));
      }
      if (!isOriginal && !rows.length && name.endsWith("所")) content.append(node("small","线路所通常没有客运时刻。有匹配径路的本机库可查通过车次。"));
      let page=0;
      function display() {
        result.replaceChildren(); pager.replaceChildren();
        const q=filter.value.trim().toUpperCase();
        const found=rows.filter(r=>[r.number,r.from,r.to].some(text=>text.toUpperCase().includes(q)));
        const pages=Math.max(1,Math.ceil(found.length/30)), start=page*30;
        status.textContent=found.length ? `${found.length} 条记录 · 第 ${page+1} / ${pages} 页` : "没有匹配的车次记录。";
        for (const row of found.slice(start,start+30)) {
          const timing=isOriginal ? [row.arr,row.dep].filter(Boolean).join(" / ") : row.pass ? (row.possible ? "通过 · 跨夜区间，通过日期待核" : "通过 · 时刻未公布") :
            [row.arr==null ? "始发" : StationCatalog.clock(row.arr),row.dep==null ? "终到" : StationCatalog.clock(row.dep)].join(" / ");
          const box=disclosure(result,row.number,body=>{
            if (row.detail) trainDetail(body,row.detail(),row.origin);
            else {
              const primary=row.number.split("/")[0];
              body.append(node("p",`${row.from} → ${row.to} · 本站 ${timing}`));
              if (row.route || /^[A-Z0-9]+$/.test(primary)) body.append(link("原站全程停站与时刻",geo+"route/"+encodeURIComponent(row.route || "CN/"+primary)));
              const matches=base.board(station,date.value).filter(r=>r.number===row.number && r.from===row.from && r.to===row.to);
              if (matches.length===1) {
                body.append(node("p",`同车次全国快照 · ${base.edition}`)); trainDetail(body,matches[0].detail(),matches[0].origin);
              }
            }
          });
          box.firstChild.append(node("span",`${row.from} → ${row.to}`),node("small",timing));
        }
        if (pages>1) {
          [["首页",0],["上一页",page-1],["下一页",page+1],["末页",pages-1]].forEach(([text,target])=>{
            const b=button(text,()=>{page=target;display();heading.scrollIntoView({block:"nearest"});});
            b.disabled=target===page || target<0 || target>=pages; pager.append(b);
          });
        }
      }
      filter.oninput=()=>{page=0;display();}; display();
    }
    source.onchange=draw; date.onchange=()=>{if(date.value) draw();}; draw();
    return {selectSource(value){source.value=value;draw();}};
  }
  return {mount, get national(){return nationalIndex ||= StationCatalog.national(globalThis.atlasRailDirectory);}};
})();
