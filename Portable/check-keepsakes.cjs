// Verify the dated interval survives a printed card, shared link and local passport.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {withBrowser} = require("./check-history-network.cjs");

async function check({browser,devices,url}, phone, folder) {
  const context = await browser.newContext({...phone ? devices["Pixel 7"] : {viewport:{width:1430,height:950}},
    serviceWorkers:"block",acceptDownloads:true,locale:"zh-CN"});
  try {
    const page = await context.newPage(), failures=[];
    page.on("pageerror",error=>failures.push(error.message));
    await page.route("**/*",route=>new URL(route.request().url()).origin === new URL(url).origin ? route.continue() : route.abort());
    const hash = new URLSearchParams({ride:"1",train:"D174",day:"2026-11-26",from:"陇南",to:"广元"});
    await page.goto(url+"#"+hash,{waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>state.route?.stops.map(s=>s.name).join("/") === "陇南/广元");
    async function panel() {
      if (await page.locator("#toggleWorkspace").getAttribute("aria-expanded") !== "true")
        await page.locator("#toggleWorkspace").click();
    }
    await panel();
    await page.locator("#recordRidden").click();
    await page.locator('#journeyForm [name="note"]').fill("仅本机的合成测试备注");
    await page.locator('#journeyForm [type="submit"]').click();
    await page.locator("#footprintPanel summary").click();
    await page.waitForFunction(()=>document.getElementById("footprintStats").textContent.includes("最长"));
    assert.match(await page.locator("#footprintStats").textContent(),/1 条记录.*2 座经停车站/);
    assert.match(await page.locator("#footprintStamps").textContent(),/乘坐章 · 陇南/);
    await page.locator("#footprintKind").selectOption("simulated");
    assert.match(await page.locator("#footprintStats").textContent(),/0 条记录/);
    await page.locator("#passportList .postcard-from-record").click();
    await page.waitForFunction(()=>!document.querySelector("#downloadPostcard").disabled);
    await page.locator("#postcardStyle").selectOption("stock-blue");
    await page.locator("#postcardPassenger").fill("测试旅客");
    await page.locator("#cardOutput summary").click();
    await page.locator("#createRideShare").click();
    await page.locator("#rideShareLink").waitFor({state:"visible",timeout:8000}).catch(async e=>{
      throw Error(e.message+" "+await page.locator("#cardExportStatus").textContent());
    });
    const link = new URL(await page.locator("#rideShareLink").getAttribute("href"));
    const publicData = new URLSearchParams(link.hash.slice(1));
    assert.equal(publicData.get("from"),"陇南");
    assert.equal(publicData.get("to"),"广元");
    assert.equal(publicData.get("day"),"2026-11-26");
    assert.equal(publicData.get("trip"),"880000D17403");
    assert.deepEqual(Array.from(publicData.keys()).sort(),["day","depart","from","ride","to","train","trip"]);
    assert.ok(!decodeURIComponent(link.href).includes("测试"));
    await page.locator("#printRideQR").check();
    if (!phone) {
      async function save(button, name) {
        const download = page.waitForEvent("download");
        await button.click();
        await (await download).saveAs(path.join(folder,name));
      }
      await save(page.locator("#saveRideShare"),"share.png");
      await save(page.locator("#downloadPostcard"),"blue.png");
      for (const [format,name] of [["ticket","ticket.pdf"],["a4","sheet.pdf"],["svg","card.svg"],["wallpaper","wallpaper.png"]]) {
        await page.locator("#cardExportFormat").selectOption(format);
        await save(page.locator("#exportCardFormat"),name);
      }
      await page.locator("#postcardStyle").selectOption("stock-red");
      await save(page.locator("#downloadPostcard"),"red.png");
    }
    const recipient = await browser.newContext({serviceWorkers:"block"});
    try {
      const view = await recipient.newPage();
      await view.goto(url+link.hash,{waitUntil:"domcontentloaded"});
      await view.waitForFunction(()=>state.route?.stops.map(s=>s.name).join("/") === "陇南/广元");
      const incoming = await view.evaluate(()=>({trip:state.route.trip,rides:state.journeys.length,legs:state.route.legs.length}));
      assert.deepEqual(incoming,{trip:"880000D17403",rides:0,legs:1});
      await view.goto(url+"#"+new URLSearchParams({atlas:"line",name:"北同蒲线"}));
      await view.waitForFunction(()=>document.querySelector("#infoTitle").textContent==="北同蒲线" && LineFocus.active?.parts.length);
      await view.locator("#infoContent .rail-sequence button").filter({hasText:/^忻州$/}).click();
      await view.getByRole("button",{name:"复制本站链接"}).waitFor();
      await view.goto(url+"#"+new URLSearchParams({atlas:"station",name:"陇南"}));
      await view.waitForFunction(()=>document.querySelector("#infoTitle").textContent==="陇南");
    } finally { await recipient.close(); }
    assert.deepEqual(failures,[]);
    console.log(`${phone?"手机":"桌面"}：D174 陇南至广元，护照记录、独立足迹、票面及分享接收通过。`);
  } finally { await context.close(); }
}
withBrowser(async options=>{
  const folder=process.env.ATLAS_CARD_QA || fs.mkdtempSync(path.join(os.tmpdir(),"atlas-card-output-"));
  console.log(folder);
  await check(options,false,folder);
  await check(options,true,folder);
}).catch(err=>{console.error(err);process.exitCode=1;});
