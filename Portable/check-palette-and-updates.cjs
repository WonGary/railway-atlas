const assert=require("node:assert/strict");
const fs=require("node:fs");
const path=require("node:path");
const crypto=require("node:crypto");
const {chromium}=require("playwright-core");
const [url,out]=process.argv.slice(2), root=path.join(__dirname,"../Web/data/metro-updates");
const feed="https://wongary.github.io/railway-atlas/data/metro-updates/";
const file=key=>fs.readFileSync(path.join(root,key));
const fingerprint=buf=>crypto.createHash("sha256").update(buf).digest("hex");

(async()=>{
  fs.mkdirSync(out,{recursive:true});
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY?{proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"127.0.0.1,localhost"}}:{})});
  try {
    const page=await browser.newPage({locale:"zh-CN",serviceWorkers:"block",viewport:{width:1360,height:860}});
    const errors=[];page.on("pageerror",e=>errors.push(e.message));
    await page.goto(url,{waitUntil:"domcontentloaded",timeout:90000});
    const ready=()=>page.waitForFunction(()=>typeof state!=="undefined" && state.routes?.length && state.metroPolylines.length && !$("updateNationalMetro").disabled);
    await ready();
    const colours=await page.evaluate(async()=>{
      const read=()=>[...state.map.getPane("lineFocus").querySelectorAll("path")].map(p=>p.getAttribute("stroke")?.toUpperCase());
      const city=state.metroCities.find(c=>c.id==="beijing");
      const detail=await loadMetroCity(city),route=detail.routes.find(r=>r.ref==="15");
      const station=detail.stations.find(s=>s.name==="望京");
      const coord=pointToLatLng(station.coordinate);
      state.map.setView(coord,15,{animate:false});refreshMetroDetailVisibility();selectMetroRoute(city,route);
      const line=read(), ring=metroStopColors(state.metroCityLayers.get("beijing"),station);
      LineFocus.clear();selectMetroStation(city,station,{pan:false});const stop=read();
      $("pref-focusColor").value="#119955";$("pref-focusColor").dispatchEvent(new Event("input"));
      return {expected:route.color.toUpperCase(),line:[...new Set(line)],ring,stop,after:read()};
    });
    assert.ok(colours.line.includes(colours.expected));
    assert.ok(colours.ring.length>=2 && colours.ring.every(c=>colours.stop.includes(c.toUpperCase())));
    assert.deepEqual(colours.after,colours.stop);
    await page.screenshot({path:path.join(out,"interchange.png")});
    async function region(name,at,z) {
      await page.evaluate(name=>{LineFocus.clear();$("regionSelect").value=name;$("regionSelect").dispatchEvent(new Event("change"));},name);
      await page.waitForFunction(s=>$("regionStatus").textContent.includes(s),name==="shanghai"?"上海":"南昌");
      await page.evaluate(([at,z])=>{state.map.setView(at,z,{animate:false});refreshMetroDetailVisibility();},[at,z]);
    }
    await region("shanghai",[31.2,121.34],14);
    const speed=await page.evaluate(()=>{
      let track;
      state.map.eachLayer(l=>{if(l instanceof L.Polyline && l.getTooltip?.()?.getContent()?.textContent==="京沪高铁")track=l;});
      if (!track) throw Error("没有载入京沪高铁的区域轨段");
      track.fire("click",{latlng:track.getCenter()});
      return [...new Set([...state.map.getPane("lineFocus").querySelectorAll("path")].map(p=>p.getAttribute("stroke")?.toLowerCase()))];
    });
    for(const color of ["#d7303f","#007f99","#3972c3"])assert.ok(speed.includes(color),speed);
    await region("nanchang-preview",[28.56,115.7844],17);
    const handoff=await page.evaluate(()=>{
      const p=state.map.project([28.56,115.7844]), near=[];
      state.map.eachLayer(l=>{
        if(!(l instanceof L.Polyline))return;
        const parts=l.getLatLngs();let nearest=Infinity;
        for(const part of Array.isArray(parts[0])?parts:[parts]) for(let i=1;i<part.length;i++)
          nearest=Math.min(nearest,L.LineUtil.pointToSegmentDistance(p,state.map.project(part[i-1]),state.map.project(part[i])));
        if(nearest<24)near.push({distance:nearest,overview:state.metroPolylines.some(e=>e.line===l),title:l.getTooltip?.()?.getContent()?.textContent});
      });
      return near;
    });
    assert.equal(handoff.filter(l=>l.overview).length,0,JSON.stringify(handoff));
    assert.equal(handoff.filter(l=>l.title?.includes("2号线") || l.title?.includes("2 号线")).length,2,JSON.stringify(handoff));
    await page.screenshot({path:path.join(out,"nanchang-z17.png")});
    const journey=await page.evaluate(()=>{
      setPlaybackVisible(true);selectRoute(state.routes.find(r=>r.geometryAvailable).id,{fit:false});startPlayback();
      $("journeyProgress").value=String(+($("journeyProgress").min)+240);updatePlayback();
      const timer=state.playbackTimer,seconds=state.playbackSeconds;
      document.querySelector('[data-focus-ink="#8057AB"]').click();
      const result={active:!!timer && state.playbackTimer===timer,seconds:state.playbackSeconds===seconds,
        lines:state.routePolylines.filter(Boolean).every(l=>l.options.color==="#8057AB"),marker:state.playbackMarker?.options.fillColor};
      stopPlayback();return result;
    });
    assert.deepEqual(journey,{active:true,seconds:true,lines:true,marker:"#8057AB"});
    await page.reload({waitUntil:"domcontentloaded"});await ready();
    assert.equal(await page.evaluate(()=>AtlasPrefs.value.focusColor),"#8057AB");
    // Exercise the real button, transport, checksum, IndexedDB commit, redraw, and reload.
    let manifest=JSON.parse(fs.readFileSync(path.join(__dirname,"../Sources/RailwayCore/Resources/national-metro-baseline.json")));
    const requests=[], replacements=new Map();
    await page.route(feed+"*",route=>{
      const key=route.request().url().split("/").at(-1);requests.push(key);
      const bytes=key==="manifest.json"?JSON.stringify(manifest):replacements.get(key);
      return bytes ? route.fulfill({contentType:"application/json",body:bytes}) : route.abort("failed");
    });
    const sync=async()=>{await page.evaluate(()=>$("updateNationalMetro").click());await page.waitForFunction(()=>!$("updateNationalMetro").disabled);return page.locator("#metroUpdateStatus").textContent();};
    const receipt={unchanged:await sync()};assert.match(receipt.unchanged,/0 个分块/);assert.deepEqual(requests,["manifest.json"]);
    function change(index) {
      const item=manifest.chunks[index],rows=JSON.parse(replacements.get(item.hash+".json") || file(item.hash+".json"));
      rows[0].parts[0][0][0]+=0.000001;const bytes=Buffer.from(JSON.stringify(rows));item.hash=fingerprint(bytes);item.bytes=bytes.length;
      replacements.set(item.hash+".json",bytes);return rows[0];
    }
    const changed=change(0);
    requests.length=0;receipt.oneCity=await sync();assert.match(receipt.oneCity,/已更新 1/);assert.equal(requests.length,2);
    function geometry(rec) {
      const item=state.metroPolylines.find(e=>e.record.city===rec.city && e.record.route.id===rec.route.id);
      return [item.record.parts[0][0][0],item.parts[0][0][1]];
    }
    const expected=[changed.parts[0][0][0],changed.parts[0][0][0]];
    assert.deepEqual(await page.evaluate(geometry,changed),expected);
    change(0);change(1);replacements.delete(manifest.chunks[1].hash+".json");
    receipt.interrupted=await sync();assert.match(receipt.interrupted,/保留当前地图/);
    assert.deepEqual(await page.evaluate(geometry,changed),expected);
    await page.reload({waitUntil:"domcontentloaded"});await ready();assert.deepEqual(await page.evaluate(geometry,changed),expected);
    assert.deepEqual(errors,[]);
    const result={colours,speed,handoff,journey,receipt};fs.writeFileSync(path.join(out,"palette-updates.json"),JSON.stringify(result,null,2)+"\n");
    console.log(JSON.stringify(result));
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
