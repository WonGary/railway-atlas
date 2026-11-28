// Serve this checkout on loopback. Pick real tracks with browser pointer events.
const assert = require("node:assert/strict");
const {withBrowser} = require("./check-history-network.cjs");

async function measure(page, label) {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const result = await page.evaluate(() => {
    const map = state.map, rect = map.getContainer().getBoundingClientRect();
    const focus = LineFocus.active;
    const paths = focus.backing?.length ? focus.backing : focus.parts;
    const vertices = paths.flat();
    const coordinates = vertices.concat(focus.stops.map(s => s[1]));
    const panels = [...document.querySelectorAll("#mapTopbar,.workspace-open > .left-rail,.right-panel,#playbackBar")]
      .filter(el => !el.hidden && !el.hasAttribute("data-ui-folded") && getComputedStyle(el).visibility === "visible")
      .map(el => [el,el.getBoundingClientRect()]).filter(([,r]) => r.width && r.height);
    let west = rect.left, east = rect.right, north = rect.top, south = rect.bottom;
    for (const [el,r] of panels) {
      if (el.id === "mapTopbar") north = Math.max(north,r.bottom);
      else if (el.id === "playbackBar" || (el.id === "infoPanel" && innerWidth <= 900)) south = Math.min(south,r.top);
      else if (el.matches(".left-rail")) west = Math.max(west,r.right);
      else east = Math.min(east,r.left);
    }
    const points = coordinates.map(ll => map.latLngToContainerPoint(ll).add([rect.left,rect.top]));
    const width = east-west, height = south-north;
    const xs = points.map(p=>p.x), ys = points.map(p=>p.y);
    const span = Math.max((Math.max(...xs)-Math.min(...xs))/width,(Math.max(...ys)-Math.min(...ys))/height);
    return {vertices:vertices.length, stops:focus.stops.length, clear:[west,north,width,height].map(Math.round),
      span:+span.toFixed(4), outside:points.filter(p=>p.x<west || p.x>east || p.y<north || p.y>south).length,
      offset:[(Math.max(...xs)+Math.min(...xs)-east-west)/2,(Math.max(...ys)+Math.min(...ys)-north-south)/2],
      direction:state.selectedMetroRoute?.route.id || null};
  });
  console.log(label,JSON.stringify(result));
  assert.ok(result.vertices > 80 && Math.abs(result.span-.8)<.012, label);
  assert.equal(result.outside,0,label);
  assert.ok(result.offset.every(v=>Math.abs(v)<2),label);
  return result;
}

async function clickTrack(page, location, zoom) {
  await page.evaluate(({location,zoom})=>{
    LineFocus.clear();
    $("infoPanel").hidden=true;
    setWorkspaceOpen(false);
    state.map.invalidateSize({pan:false});
    state.map.setView(location,zoom,{animate:false});
  },{location,zoom});
  await page.waitForTimeout(300);
  const {x,y} = await page.evaluate(ll=>{
    const map=state.map, r=map.getContainer().getBoundingClientRect();
    return map.latLngToContainerPoint(ll).add([r.left,r.top]);
  },location);
  await page.mouse.click(x,y);
}

withBrowser(async ({browser,url}) => {
  for (const [width,height] of [[1440,900],[390,844]]) {
    const page = await browser.newPage({viewport:{width,height},serviceWorkers:"block"});
    const errors=[];
    page.on("pageerror",e=>errors.push(e.message));
    try {
      await page.route("**/*",r=>new URL(r.request().url()).origin===new URL(url).origin ? r.continue() : r.abort());
      await page.goto(url,{waitUntil:"domcontentloaded"});
      await page.waitForFunction(()=>typeof state!=="undefined" && state.routes.length && state.map);
      await page.evaluate(()=>{AtlasPrefs.change("inspectorLayout","floating");selectStation("郑州",{pan:false});});
      const railway = page.locator('#infoContent details').filter({has:page.locator('summary',{hasText:/^陇海线 ·/})}).first();
      await railway.locator("summary").click();
      await page.waitForFunction(()=>LineFocus.active?.title==="陇海线" && LineFocus.active.parts.length);
      const disclosure = await measure(page,`${width} station line disclosure`);
      await railway.getByRole("button",{name:/地图查看沿线站点/}).click();
      await page.waitForFunction(()=>LineFocus.active?.parts.length);
      assert.equal((await measure(page,`${width} station full-line button`)).span,disclosure.span);
      if (width>900) {
        for (const [left,right] of [["floating","floating"],["docked","floating"],["floating","docked"],["docked","docked"]]) {
          await page.evaluate(([l,r])=>{AtlasPrefs.change("panelLayout",l);AtlasPrefs.change("inspectorLayout",r);setWorkspaceOpen(true);},[left,right]);
          await measure(page,`${width} unchanged selection ${left}/${right}`);
        }
      }

      // Select an actual segment of the regional map, then wait for the national backing geometry.
      const railPoint=await page.evaluate(async()=>{
        AtlasPrefs.change("mode","offline");
        $("regionSelect").value="shanghai";
        $("regionSelect").dispatchEvent(new Event("change"));
        const data=await loadJSON("./data/regions/shanghai.railmap");
        const path=data.lines.find(l=>l.id==="way/24943912").coordinates;
        const a=path[2], b=path[3];
        return [(a.latitude+b.latitude)/2,(a.longitude+b.longitude)/2];
      });
      await page.waitForFunction(()=>$("regionStatus").textContent.includes("段轨道"));
      await clickTrack(page,railPoint,15);
      await page.waitForFunction(()=>LineFocus.active?.title==="沪昆线" && LineFocus.active.backing?.length);
      await measure(page,`${width} track click 沪昆线`);

      const metroPoint = await page.evaluate(async()=>{
        AtlasPrefs.change("mode","cached");
        const city=state.metroCities.find(c=>c.id==="beijing"), d=await loadMetroCity(city);
        const route=d.routes.find(r=>r.id==="relation/20010805"), path=route.parts[0];
        const [a,b]=path.slice(22,24);
        return [(a[1]+b[1])/2,(a[0]+b[0])/2];
      });
      await clickTrack(page,metroPoint,17);
      await page.waitForFunction(()=>state.selectedMetroRoute?.route.ref==="18" && LineFocus.active?.parts.length);
      const picked = await measure(page,`${width} metro track click`);
      assert.ok(["relation/20010805","relation/20010820"].includes(picked.direction));
      const expected=await page.evaluate(()=>state.selectedMetroRoute.route.parts.flat().length);
      assert.equal(picked.vertices,expected);
      // Use a stop's actual direction buttons, including the opposite direction.
      for (const id of ["relation/20010820","relation/20010805"]) {
        // Separate platforms at the terminus publish their own direction first.
        await page.evaluate(id=>{
          const city=state.metroCities.find(c=>c.id==="beijing"),detail=state.metroDetails.get(city.id);
          const terminus=detail.routes.find(r=>r.id===id).stops[0];
          selectMetroStation(city,detail.stations.find(s=>s.id===terminus.id),{pan:false});
        },id);
        const directionButton = page.locator(`[data-metro-route="${id}"]`);
        await directionButton.click();
        const result=await measure(page,`${width} station direction ${id}`);
        assert.equal(result.direction,id);
        assert.equal(result.vertices,await page.evaluate(()=>state.selectedMetroRoute.route.parts.flat().length));
      }
      await page.evaluate(()=>AtlasPrefs.change("inspectorLayout","floating"));
      await measure(page,`${width} re-opened float`);
      const camera = await page.evaluate(()=>{
        state.map.panBy([53,31],{animate:false});
        return [state.map.getCenter(),state.map.getZoom()];
      });
      await page.evaluate(()=>{$("infoPanel").hidden=true;});
      await page.waitForTimeout(200);
      assert.deepEqual(await page.evaluate(()=>[state.map.getCenter(),state.map.getZoom()]),camera);
      assert.deepEqual(errors,[]);
    } finally { await page.close(); }
  }
}).catch(e=>{console.error(e);process.exitCode=1;});
