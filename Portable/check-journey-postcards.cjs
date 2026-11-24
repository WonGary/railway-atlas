const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {chromium} = require("playwright-core");

async function main() {
  const [url,output] = process.argv.slice(2);
  fs.mkdirSync(output,{recursive:true});
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER});
  try {
    const page=await browser.newPage({locale:"zh-CN",timezoneId:"Asia/Shanghai",viewport:{width:1360,height:900}});
    await page.goto(url,{waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.map);
    const board=page.locator("#infoContent .station-directory");
    async function trainBoard() {
      await page.evaluate(()=>showStationBoard("北京西"));
      await board.locator("input[type=date]").fill("2026-11-25");
      await board.locator("input[type=date]").dispatchEvent("change");
      await board.locator("input[type=search]").fill("G337");
      await board.locator("summary").filter({hasText:/^G337北京西/}).click();
    }
    await trainBoard();
    await board.getByRole("button",{name:"在主地图沿线旅行"}).click();
    await page.waitForFunction(()=>state.route?.train==="G337" && state.routePolylines.filter(Boolean).length===6);
    await trainBoard();
    await board.getByRole("button",{name:"制作路线明信片"}).click();
    await page.locator("#postcardFrom").fill("石家庄");
    await page.locator("#postcardTo").fill("武汉");
    await page.waitForFunction(()=>cardRoute?.stops[0].name==="石家庄" && cardRoute?.stops.at(-1).name==="武汉");
    const summary=await page.evaluate(()=>({stops:cardRoute.stops.map(s=>s.name),legs:cardRoute.legs.length}));
    assert.deepEqual(summary,{stops:["石家庄","郑州东","武汉"],legs:2});
    const styles=await page.locator("#postcardStyle option").evaluateAll(list=>list.map(o=>o.value));
    for (const style of styles) {
      await page.locator("#postcardStyle").selectOption(style);
      const download=page.waitForEvent("download");
      await page.locator("#downloadPostcard").click();
      const png=(await download);
      await png.saveAs(path.join(output,`${style}.png`));
    }
    await page.evaluate(async()=>{
      const other=await RailPaths.find({train:"C273",date:"2026-11-25"});
      displayTimetableJourney(other);
      setWorkspaceView("experiences");setWorkspaceOpen(true);setExperiencePage("postcard");
    });
    await page.waitForFunction(()=>cardRoute?.stops[0].name==="石家庄" && cardRoute?.stops.at(-1).name==="武汉");
    const download=page.waitForEvent("download");
    await page.locator("#downloadPostcard").click();
    assert.deepEqual(fs.readFileSync(await (await download).path()),fs.readFileSync(path.join(output,`${styles.at(-1)}.png`)));
    await page.locator("#postcardFrom").fill("南昌西");
    await page.waitForFunction(()=>document.getElementById("downloadPostcard").disabled && !cardRoute &&
      !document.getElementById("postcardStatus").textContent.includes("正在"));
    const overnight=await page.evaluate(async()=>{
      const full=await RailPaths.find({train:"Z58",date:"2026-11-25"});
      const a=full.stops.findIndex(s=>s.departure>=1440);
      const left=full.stops[a], right=full.stops[a+1];
      const day=StationCatalog.day(full.serviceDate, Math.floor(left.departure/1440));
      const section=await RailPaths.find({train:"Z58",date:day,boarding:true,from:left.name,to:right.name});
      return {origin:section.serviceDate,day,exact:JSON.stringify(section.legs[0])===JSON.stringify(full.legs[a])};
    });
    assert.deepEqual(overnight,{origin:"2026-11-25",day:"2026-11-26",exact:true});
    console.log(JSON.stringify({summary,styles,overnight,unchangedAfterMapSwitch:true,reverseBlocked:true}));
  } finally {await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
