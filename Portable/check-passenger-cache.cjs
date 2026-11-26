const assert = require("node:assert/strict");
const fs = require("node:fs");
const {chromium} = require("playwright-core");

const [url, output] = process.argv.slice(2);
const library = process.env.RAILWAY_TEST_LIBRARY;
const cases = [
  {train:"D174", origin:"西宁", from:"陇南", to:"广元", date:"2026-11-26", sections:1},
  {train:"V571", origin:"北京丰台", from:"菏泽", to:"浠水", date:"2026-11-27", sections:5}
];

async function board(page, item) {
  await page.evaluate(name=>showStationBoard(name),item.from);
  const panel=page.locator("#infoContent .station-directory");
  await panel.locator("input[type=date]").fill(item.date);
  await panel.locator("input[type=date]").dispatchEvent("change");
  await panel.locator("input[type=search]").fill(item.train);
  const row=panel.locator("details").filter({has:page.locator("summary").filter({
    hasText:new RegExp(`^${item.train}(?:/|${item.origin})`)
  })}).filter({hasText:item.origin});
  assert.equal(await row.count(),1);
  await row.locator("summary").first().click();
  return row;
}

async function check(page, item) {
  let row=await board(page,item);
  await row.getByRole("button",{name:"在主地图沿线旅行"}).click();
  await page.waitForFunction(train=>state.route?.geometryAvailable && RailLibrary.trainNames(state.route.train).includes(train),item.train);
  row=await board(page,item);
  await row.getByRole("button",{name:"制作路线明信片"}).click();
  await page.locator("#postcardTo").fill(item.to);
  await page.waitForFunction(({from,to})=>cardRoute?.stops[0].name===from && cardRoute.stops.at(-1).name===to,item);
  const result=await page.evaluate(async item=>{
    const {timetable}=cardContext;
    const full=state.routes.find(route=>route.train===timetable.train && route.geometryAvailable && route.serviceDate===timetable.serviceDate);
    const start=full.stops.findIndex(s=>s.name===item.from), end=full.stops.findIndex(s=>s.name===item.to);
    const expected=JSON.stringify(full.legs.slice(start,end));
    if (end-start!==item.sections || JSON.stringify(cardRoute.legs)!==expected) throw Error("明信片与主地图的乘车区间不一致");
    const original=state.routes, variants={};
    try {
      if (!timetable.routing) throw Error("测试需要导入含实际径路的路路通时刻库");
      for (const variant of ["equalCopy","differentLine","missingPlan","differentTrip"]) {
        const routing=structuredClone(timetable.routing);
        if (variant==="differentLine") routing.edges[0].lineName+=" (test)";
        const query={...timetable};
        if (variant==="differentTrip") {query.trip=full.trip; if (!query.trip) throw Error("测试排图缺少 ID");}
        state.routes=[{...full,id:"test-cached",trip:variant==="differentTrip" ? "test-other" : full.trip,
          routing:variant==="missingPlan" ? null : routing}];
        const section=await passengerSection({...item,timetable:query});
        if (JSON.stringify(section.legs)!==expected) throw Error("区间轨迹不一致："+variant);
        variants[variant]=section.id==="test-cached" ? "cache" : "atlas";
      }
    } finally {state.routes=original;}
    return {train:item.train,originDate:full.serviceDate,boardingDate:$("postcardDate").value,from:item.from,to:item.to,
      sections:cardRoute.legs.length,vertices:cardRoute.legs.reduce((n,leg)=>n+leg.length,0),variants};
  },item);
  assert.equal(result.originDate,"2026-11-26");
  assert.equal(result.boardingDate,item.date);
  assert.deepEqual(result.variants,{equalCopy:"cache",differentLine:"atlas",missingPlan:"atlas",differentTrip:"atlas"});
  const download=page.waitForEvent("download");
  await page.locator("#downloadPostcard").click();
  const png=fs.readFileSync(await (await download).path());
  assert.equal(png.toString("hex",0,8),"89504e470d0a1a0a");
  return {...result,pngBytes:png.length};
}

(async()=>{
  assert.ok(library && url);
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY && {proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"localhost,127.0.0.1"}})});
  try {
    const page=await browser.newPage({serviceWorkers:"block",locale:"zh-CN",timezoneId:"Asia/Shanghai"});
    await page.goto(url,{waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.map && state.corridor);
    await page.locator("#libraryFile").setInputFiles(library);
    await page.waitForFunction(()=>!!RailLibrary.current);
    const results=[];
    for (const item of cases) results.push(await check(page,item));
    const receipt=JSON.stringify({url,browser:browser.version(),results},null,2)+"\n";
    if (output) fs.writeFileSync(output,receipt);
    console.log(receipt);
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
