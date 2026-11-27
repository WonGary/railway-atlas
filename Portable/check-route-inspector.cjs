// node Portable/check-route-inspector.cjs [--data-only | --with-test-hooks] [Web URL]
const assert = require("node:assert/strict");
const {withBrowser} = require("./check-history-network.cjs");
const {report,slice,uniqueRange,tripMinutes,compareGeometry,directoryPaths,candidateProblem} = require("../Web/route-inspector.js");
const day = "2026-11-26";

function pure() {
  const route=(names,legs)=>({stops:names.map((name,i)=>({name,arrival:i?i*20:null,departure:i<names.length-1?i*20:null})),legs});
  const p=[31,110],q=[31,110.01],r=[31,110.02],s=[31,110.03],bend=[31.01,110.015];
  const a=route(["甲","乙","丙"],[[p,q,r],[r,s]]);
  const b=route(["丙","甲"],[[s,r,[31,110.005],p]]);
  const reversed=compareGeometry(a,b);
  assert.equal(reversed.a.onlyMetres,0);
  assert.equal(reversed.b.onlyMetres,0);
  assert.ok(reversed.a.sharedMetres>2800);
  const fork=compareGeometry(a,route(["甲","丙"],[[p,q,bend,r,s]]));
  assert.ok(fork.a.onlyMetres>700 && fork.b.onlyMetres>1800);
  assert.ok(fork.a.sharedMetres>1700 && fork.b.sharedMetres>1700);
  const cross=route(["东","西"],[[[30.99,110.015],[31.01,110.015]]]);
  assert.equal(compareGeometry(a,cross).a.sharedMetres,0);
  const separated=route(["甲","乙","丙","丁"],[[p,q],[],[r,s]]);
  const result=compareGeometry(separated,a);
  assert.equal(result.a.onlyMetres,0);
  assert.ok(result.b.onlyMetres>700);
  const points=report(separated);
  assert.equal(points[1].drawable,false);
  assert.equal(points[1].problem,"缺少区间轨迹");
  assert.equal(report({...route(["甲","乙"],[[p,[33,112]]]),imported:true})[0].drawable,false);
  assert.match(report(route(["甲","乙","丙"],[[p,q],[r,s]]))[1].problem,/站内衔接/);
  assert.match(candidateProblem(a,1,[p,s]),/前一区间/);
  assert.equal(tripMinutes(a),40);
  assert.deepEqual(uniqueRange(a.stops,"甲","丙"),[0,2]);
  assert.equal(slice(a,1,2).legs[0],a.legs[1]);
  assert.equal(uniqueRange([{name:"甲"},{name:"甲"},{name:"乙"}],"甲","乙"),null);
  const stops=[["甲",0],["乙",1],["丙",2]];
  assert.deepEqual(directoryPaths(stops,[["甲","乙",[p,q]],["丙","乙",[r,q]]],"丙","甲"),[[r,q,q,p]]);
  assert.deepEqual(directoryPaths(stops,[["甲","乙",[p,q]],["乙","丙",[r,s]]],"甲","丙"),[]);
  console.log("route algorithms: opposite direction, partial overlap, fork, crossing, missing leg, physical continuity, dated range and line topology passed");
}

async function runUI({browser, devices, url, testHooks},phone) {
  const context=await browser.newContext({...(phone?devices["Pixel 7"]:{viewport:{width:1440,height:900}}),serviceWorkers:"block"});
  try {
    const page=await context.newPage();
    const errors=[];
    page.on("pageerror",err=>errors.push(err.message));
    await page.route("**/*",route=>new URL(route.request().url()).origin===new URL(url).origin?route.continue():route.abort());
    await page.goto(url,{waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.map && state.routes.length);
    if (testHooks && !await page.evaluate(()=>Boolean(globalThis.RailwayRouteInspector)))
      await page.addScriptTag({url:new URL("route-inspector.js",url).href});
    const press=s=>phone?page.locator(s).tap():page.locator(s).click();
    const inspector=page.locator("#routeInspector");
    async function openPanel() {
      if (await page.locator("#toggleWorkspace").getAttribute("aria-expanded")!=="true") await press("#toggleWorkspace");
    }
    const ready=train=>page.waitForFunction(t=>state.route && RailLibrary.trainNames(state.route.train).includes(t) && !document.querySelector("#routeInspector")?.hidden &&
      document.querySelector("#routeInspector [data-leg]"),train,{timeout:10000}).catch(async err=>{
      const info=await page.evaluate(()=>({train:state.route?.train,id:state.route?.id,view:state.workspaceView,
        player:state.playbackVisible,hidden:document.querySelector("#routeInspector")?.hidden,
        report:document.querySelector("#routeInspector summary")?.textContent,status:document.querySelector("#libraryStatus")?.textContent}));
      throw Error(`${err.message} ${JSON.stringify({info,errors})}`);
    });
    await openPanel();
    await press('[data-view="experiences"]');
    await press("#toggleJourney");
    async function loadTrain(train) {
      await openPanel();
      await page.locator("#libraryDate").fill(day);
      await page.locator("#libraryTrain").fill(train);
      await page.locator("#libraryResults button").filter({hasText:new RegExp(`^${train}\\b`)}).first().click();
      await ready(train);
      await openPanel();
    }
    await loadTrain("D174");
    await inspector.getByText(/^逐段质量 ·/).click();
    await inspector.locator("[data-leg]").filter({hasText:"陇南 → 广元"}).click();
    assert.equal(await page.locator('[data-inspector-ink="leg"]').count(),1);
    assert.ok(await inspector.getByText(/轨道长度/).isVisible());
    await inspector.getByRole("button",{name:"只看这个乘车区间"}).click();
    await page.waitForFunction(()=>state.route.stops.length===2);
    await inspector.locator("[data-leg]").first().click();
    const fullJourney=inspector.getByRole("button",{name:/查看 D174.* 全程/});
    assert.equal(await fullJourney.count(),1);
    await fullJourney.click();
    await page.waitForFunction(()=>state.route.stops.length===15);
    await inspector.getByText("比较两趟车的径路",{exact:true}).click();
    await inspector.getByLabel("比较车次",{exact:true}).fill("D176");
    await inspector.getByRole("button",{name:"在主地图比较"}).click();
    await inspector.getByText(/45 m/).waitFor();
    const metrics=await inspector.locator("table tr").allTextContents();
    for (const identity of ["a","b","shared"])
      assert.equal(await page.locator(`[data-inspector-ink="${identity}"]`).count(),1);
    assert.ok(metrics.some(text=>text.includes("14/14")));
    assert.ok(await page.evaluate(()=>RailLibrary.trainNames(state.route.train).includes("D174")));
    await inspector.getByText("两车逐站到发与停留",{exact:true}).click();
    assert.ok(await inspector.getByText(/^陇南　/).first().isVisible());
    await inspector.getByRole("button",{name:"收起比较图层"}).click();
    assert.equal(await page.locator("[data-inspector-ink]").count(),0);
    await loadTrain("V604");
    await inspector.locator("[data-leg]").filter({hasText:"太原 → 忻州"}).click();
    await inspector.getByRole("button",{name:/北同蒲线全线/}).click();
    await page.waitForFunction(()=>LineFocus.active?.parts.length>0 && document.querySelector("#infoContent .rail-sequence"));
    const physicalStops=await page.locator("#infoContent .rail-sequence li").count();
    assert.ok(physicalStops>10);
    await page.locator("#infoContent .rail-sequence button").filter({hasText:/^忻州$/}).click();
    assert.equal(await page.locator("#infoTitle").textContent(),"忻州");
    await openPanel();
    // Controlled fault: discard one known leg of an otherwise real dated D174.
    // The candidate, verification and committed geometry must come from the real path group.
    await loadTrain("D174");
    const missing=await page.evaluate(()=>{
      const full=state.routes.find(r=>r.id===state.route.id), i=full.stops.findIndex(s=>s.name==="陇南");
      const points=full.legs[i];
      const result={i,count:points.length,first:points[0],last:points.at(-1)};
      full.legs=full.legs.slice();full.legs[i]=[];full.geometryAvailable=false;
      selectRoute(full.id,{fit:false});
      return result;
    });
    await inspector.locator(`[data-leg="${missing.i}"]`).filter({hasText:"缺少区间轨迹"}).click();
    assert.equal(await page.locator('[data-inspector-ink="leg"]').count(),0);
    await inspector.getByRole("button",{name:"核对区间候选"}).click();
    const accept=inspector.getByRole("button",{name:"采用并在本机记住"}).first();
    await accept.waitFor();
    assert.equal(await accept.isEnabled(),true);
    await inspector.getByRole("button",{name:"在地图预览候选"}).first().click();
    assert.equal(await page.locator('[data-inspector-ink="candidate"]').count(),1);
    await accept.click();
    await page.waitForFunction(()=>state.route.geometryAvailable);
    const fix=await page.evaluate(i=>({p:state.route.legs[i],saved:JSON.parse(localStorage.getItem("railway-atlas-confirmed-route-legs-v1")).length}),missing.i);
    assert.equal(fix.p.length,missing.count);assert.deepEqual(fix.p[0],missing.first);assert.deepEqual(fix.p.at(-1),missing.last);assert.equal(fix.saved,1);
    await press('[data-view="experiences"]');
    assert.equal(await page.locator("[data-inspector-ink]").count(),0);
    assert.deepEqual(errors,[]);
    console.log(JSON.stringify({view:phone?"phone":"desktop",entry:testHooks?"test script loaded if needed":"checkout",
      D174_D176:metrics,V604PhysicalStops:physicalStops,restoredD174Vertices:missing.count}));
  } finally {await context.close();}
}

(async()=>{
  pure();
  if (!process.argv.includes("--data-only")) await withBrowser(async options=>{
    await runUI(options,false);
    await runUI(options,true);
  });
})().catch(e=>{console.error(e);process.exitCode=1;});
