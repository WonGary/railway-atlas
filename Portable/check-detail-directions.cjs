const {chromium}=require("playwright-core");
const assert=require("node:assert/strict"), fs=require("node:fs"), path=require("node:path");
const [url,out,mode]=process.argv.slice(2);
(async()=>{
  fs.mkdirSync(out,{recursive:true});
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY?{proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"127.0.0.1,localhost"}}:{})});
  try {
    const page=await browser.newPage({viewport:{width:1250,height:870},locale:"zh-CN",serviceWorkers:"block"});
    const errors=[];page.on("pageerror",err=>errors.push(err.message));
    // This reproduces the original cross-origin failure while retaining the real base tiles.
    await page.route("https://openrailwaymap.app/**",r=>r.abort());
    await page.goto(url,{waitUntil:"domcontentloaded",timeout:70000});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.map && state.metroPolylines.length);
    const levels=[];
    for(const [z,lat,lon] of [[8,40.65,110.55],[10,40.62,110.22],[13,40.60,110.06]]) {
      await page.evaluate(([z,lat,lon])=>{
        LineFocus.clear(); Object.assign(AtlasPrefs.value,{mapAppearance:"dark",basemapDarkness:.35});
        updateBasemapAppearance(); state.map.setView([lat,lon],z,{animate:false});
      },[z,lat,lon]);
      if(mode!=="before")await page.waitForFunction(()=>{
        const layers=Object.values(state.map._layers), grid=layers.find(l=>l.options?.pane==="railDetail");
        return Object.values(grid?._tiles||{}).some(t=>t.current && t.el.hits?.some(h=>h.source==="atlas_rail_detail" && h.tags.maxspeed));
      },null,{timeout:25000});
      else await page.waitForTimeout(4000);
      const stats=await page.evaluate(()=>{
        const map=state.map,grid=Object.values(map._layers).find(l=>l.options?.pane==="railDetail");
        const bands=new Set(),names=new Set(); let colouredPixels=0,grayPixels=0,click=null;
        const colors=Object.entries(AtlasPrefs.categories).filter(([key])=>/^(speed\d+|below160)$/.test(key)).map(([,v])=>parseInt(v[1].slice(1),16));
        for(const t of Object.values(grid?._tiles||{}).filter(t=>t.current && t.coords.z===grid._tileZoom && t.el.hits)) {
          const ctx=t.el.getContext("2d"), a=ctx.getImageData(0,0,t.el.width,t.el.height).data;
          for(let i=0;i<a.length;i+=4) if(a[i+3]>100) {
            const rgb=(a[i]<<16)|(a[i+1]<<8)|a[i+2];
            if(colors.some(c=>[0,8,16].every(s=>Math.abs((rgb>>s&255)-(c>>s&255))<3)))colouredPixels++;
            if(Math.max(a[i],a[i+1],a[i+2])-Math.min(a[i],a[i+1],a[i+2])<29)grayPixels++;
          }
          for(const h of t.el.hits) {
            if(!h.points || !h.tags.maxspeed)continue;
            const cat=AtlasPrefs.classify(h.tags).category;
            if(!/^(speed\d+|below160)$/.test(cat)) continue;
            bands.add(cat);if(h.tags.name)names.add(h.tags.name);
            if(click || !h.tags.name)continue;
            for(const [x,y] of h.points) {
              if(x<2||x>254||y<2||y>254)continue;
              const ll=map.unproject([t.coords.x*256+x,t.coords.y*256+y],t.coords.z);
              const pt=map.latLngToContainerPoint(ll);
              if(pt.x>100&&pt.x<map.getSize().x-100&&pt.y>80&&pt.y<map.getSize().y-100){click=[ll.lat,ll.lng]; break;}
            }
          }
        }
        if(click)map.fire("click",{latlng:L.latLng(...click),originalEvent:{}});
        return {zoom:map.getZoom(),bands:[...bands],names:[...names].slice(0,7),colouredPixels,grayPixels,
          inspector:$("infoTitle").textContent,limit:$("infoContent").textContent.includes("限速")};
      });
      levels.push(stats);
      if(z===8) {await page.evaluate(()=>LineFocus.clear());await page.screenshot({path:path.join(out,"baotou.png")});}
      if(mode!=="before") {assert.ok(stats.colouredPixels>50 && stats.bands.length && stats.names.length,JSON.stringify(stats));}
    }
    const metro=await page.evaluate(async()=>{
      const city=state.metroCities.find(c=>c.id==="beijing"),detail=await loadMetroCity(city);
      const r=detail.routes.find(r=>r.id==="relation/20010805");selectMetroRoute(city,r,{fit:true});
      const buttons=[...document.querySelectorAll("[data-metro-stop]")];
      const names=buttons.map(b=>b.children[1].textContent);const fit=LineFocus.active.parts.every(p=>p.every(ll=>state.map.getBounds().contains(ll)));
      const click=buttons.find(b=>b.children[1].textContent==="东北旺");click?.click();
      const station=$("infoTitle").textContent;
      selectMetroRoute(city,detail.routes.find(r=>r.id==="relation/20010820"),{fit:true});
      return {names,fit,station,reverse:[...document.querySelectorAll("[data-metro-stop]")].map(b=>b.children[1].textContent)};
    });
    await page.screenshot({path:path.join(out,"beijing18.png")});
    if(mode!=="before") {
      assert.equal(metro.names.length,11);assert.deepEqual(metro.reverse,[...metro.names].reverse());
      assert.ok(metro.fit && metro.station.includes("东北旺"));
      assert.ok(levels.some(s=>s.limit));assert.deepEqual(errors,[]);
    }
    const report={version:await page.locator("#versionBadge").textContent(),levels,metro,errors};
    fs.writeFileSync(path.join(out,"checks.json"),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
