const assert=require("node:assert/strict");
const {chromium}=require("playwright-core");

async function main() {
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY?{proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"localhost,127.0.0.1"}}:{})});
  try {
    const page=await browser.newPage({viewport:{width:1440,height:840},serviceWorkers:"block"});
    const errors=[];page.on("pageerror",e=>errors.push(e.message));
    await page.goto(process.argv[2],{waitUntil:"domcontentloaded",timeout:90000});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.metroPolylines.length);
    const result=await page.evaluate(async()=>{
      const map=state.map;
      const wait=async predicate=>{
        const end=performance.now()+7000;
        while(!predicate()) {if(performance.now()>end)throw Error("地图等待超时");await new Promise(r=>setTimeout(r,25));}
      };
      setWorkspaceOpen(false);
      AtlasPrefs.change("mode","cached");
      AtlasPrefs.change("basemapDarkness",.42,false);
      const pane=n=>map.getPane(n);
      const grids={};map.eachLayer(l=>{if(l instanceof L.GridLayer)grids[l.options.pane]=l;});
      const live=grids.railDetail, overview=grids.railOverview;
      const point=map.project([31.196,121.32],12).divideBy(256).floor(),z=12;
      const center=map.unproject(point.multiplyBy(256).add([128,128]),z);
      // Three adjacent cells. Hold the middle one, with a primary track, an
      // uncoloured section and a second, displaced backup depiction in each.
      const original=AtlasVector.decode, mid=new Promise(r=>window.releaseMiddle=r);
      const name="回归样线";
      AtlasVector={...AtlasVector,decode:bytes=>{
        if(bytes.length!==3 || bytes[0]!==255)return original(bytes);
        const backup=bytes[1]===2, unknown=bytes[2]===1;
        return {layers:{[backup?"streets":"railway_line_high"]:{length:1,feature:()=>({
          id:17,type:2,extent:256,properties:backup?{kind:"rail",rail:true,name}:{feature:"rail",name,...(unknown?{}:{maxspeed:350})},
          bbox:()=>[0,128,256,136],loadGeometry:()=>[[{x:0,y:backup?136:128},{x:256,y:backup?136:128}]]
        })}}};
      }};
      LocalRailCache.read=async c=>{
        if(c.z!==z || c.y!==point.y || Math.abs(c.x-point.x)>1)return [];
        if(c.x===point.x)await mid;
        return [Uint8Array.of(255,1,Number(c.x===point.x)),Uint8Array.of(255,2,0)];
      };
      map.setView(center,6,{animate:false});
      await wait(()=>Object.values(overview._tiles).some(t=>t.el.tracks?.length));
      map.setView(center,12,{animate:false});
      const at=i=>live._tiles[`${point.x+i}:${point.y}:12`]?.el;
      await wait(()=>at(-1)?.hits?.length && at(1)?.hits?.length);
      const backupHits=at(-1).hits.filter(h=>h.source==="streets").length;
      const nearOverview=Object.keys(overview._tiles).length;
      const left=map.unproject(point.multiplyBy(256).add([-100,128]),z);
      map.fire("click",{latlng:left,originalEvent:{}});
      if(LineFocus.active?.title!==name)throw Error("未点中详细轨道");
      const tileCount=()=>[...LineFocus.active.extra.keys()].filter(k=>k.startsWith("tile/")).length;
      const before=tileCount();
      const originalPaths=[...pane("lineFocus").querySelectorAll("path")];
      window.releaseMiddle();
      await wait(()=>tileCount()===3);
      const after=tileCount(),colors=[...pane("lineFocus").querySelectorAll("path")].map(p=>p.getAttribute("stroke").toLowerCase());
      let frames=0,exposed=0,wrongShade=0;
      function sample() {
        const view=map.getContainer().getBoundingClientRect();
        for(const [id,alpha] of [["basemapShade",.42],["focusShade",LineFocus.active ? .5 : 0]]) {
          const sheet=pane(id),rect=sheet.getBoundingClientRect();
          if(rect.left>view.left+1 || rect.top>view.top+1 || rect.right<view.right-1 || rect.bottom<view.bottom-1)exposed++;
          if(Math.abs(+getComputedStyle(sheet).opacity-alpha)>.001)wrongShade++;
        }
        frames++;
      }
      async function gesture(fn) {
        fn();
        const start=performance.now();
        do {await new Promise(requestAnimationFrame);sample();} while(performance.now()-start<330);
      }
      await gesture(()=>map.panBy([210,45],{animate:true,duration:.2}));
      await gesture(()=>map.setZoom(12.5,{animate:true}));
      await gesture(()=>map.setZoom(12,{animate:true}));
      await gesture(()=>map.panTo(center,{animate:true,duration:.2}));
      const retained=originalPaths.every(p=>p.isConnected);
      LineFocus.clear();
      await gesture(()=>map.panBy([-200,30],{animate:true,duration:.2}));
      const backdropOnly=pane("lineFocus").querySelectorAll("path").length===0;
      await LineFocus.directory("京九线",[["北京西",[39.9,116.32]]],["北京西","广安门"],false);
      const directoryPaths=[...pane("lineFocus").querySelectorAll("path")];
      map.panBy([35,0],{animate:false});
      const directoryRetained=directoryPaths.length>0 && directoryPaths.every(p=>p.isConnected);
      return {before,after,backupHits,nearOverview,retained,directoryRetained,backdropOnly,frames,exposed,wrongShade,
        speed:colors.includes("#d7303f"),fallback:colors.includes(AtlasPrefs.value.focusColor.toLowerCase()),zoomStep:map.options.zoomDelta};
    });
    assert.equal(result.before,2);assert.equal(result.after,3);
    assert.equal(result.backupHits,0);assert.equal(result.nearOverview,0);
    assert.ok(result.retained && result.directoryRetained && result.backdropOnly && result.frames>10);
    assert.ok(result.speed && result.fallback);
    assert.equal(result.exposed,0);assert.equal(result.wrongShade,0);assert.equal(result.zoomStep,.5);
    assert.deepEqual(errors,[]);console.log(JSON.stringify(result));
  } finally {await browser.close();}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
