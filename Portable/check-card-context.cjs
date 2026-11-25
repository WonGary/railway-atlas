const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const {chromium} = require("playwright-core");

async function main() {
  const [url, file, output] = process.argv.slice(2);
  fs.mkdirSync(output, {recursive:true});
  const browser = await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY ? {proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"127.0.0.1,localhost"}} : {})});
  try {
    const context = await browser.newContext({locale:"zh-CN", timezoneId:"Asia/Shanghai"});
    const page = await context.newPage();
    const errors = [], outlineRequests = [];
    context.on("request", req => {
      if (req.url().includes("card-contours.json") || req.method() === "POST" && req.url().startsWith(url))
        outlineRequests.push(req.url());
    });
    page.on("pageerror", e => errors.push(e.message));
    async function openCard() {
      await page.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.map,null,{timeout:90000});
      await page.evaluate(async()=>{
        setWorkspaceView("experiences"); setWorkspaceOpen(true); setExperiencePage("postcard");
        for (const [key,value] of Object.entries({Style:"map",Train:"Z58",Date:"2026-11-25",From:"北京西",To:"三亚"}))
          $("postcard"+key).value=value;
        await refreshPostcard();
        if(!cardRoute) throw Error($("postcardStatus").textContent);
      });
    }
    async function exportCard(name) {
      const download=page.waitForEvent("download");
      await page.locator("#downloadPostcard").click();
      const dest=path.join(output,name+".png");
      await (await download).saveAs(dest);
      const data=fs.readFileSync(dest);
      assert.deepEqual([data.readUInt32BE(16),data.readUInt32BE(20)],[1280,720]);
      return crypto.createHash("sha256").update(data).digest("hex");
    }
    await page.goto(url,{waitUntil:"domcontentloaded",timeout:120000});
    await page.waitForFunction(()=>!!navigator.serviceWorker.controller,null,{timeout:150000});
    await openCard();
    assert.equal(await page.evaluate(()=>CardMap.hasContours),false);
    const defaultPNG=await exportCard("Z58-default");
    await page.evaluate(()=>{
      setExperiencePage("passport");
      state.journeys=[{train:"G337",from:"石家庄",to:"武汉",date:"2026-11-25",status:"travelled"}];renderPassport();
    });
    const details=page.locator("#passportList .passenger-map");
    await details.locator("summary").click();
    await details.locator("canvas").waitFor();
    const before=await details.locator("canvas").evaluate(c=>c.toDataURL());
    assert.match(await details.locator("[role=status]").innerText(),/石家庄 → 郑州东 → 武汉 · 沿线城市及海岸/);
    await page.locator("#cardContextSettings summary").click();
    const picker=page.locator("#cardContourFile");
    await picker.setInputFiles(file);
    await page.waitForFunction(()=>CardMap.hasContours && $("cardContourStatus").textContent.includes("已保存"));
    await page.waitForFunction(()=>document.querySelector(".passenger-map small")?.textContent.includes("天地图"));
    assert.equal(await details.locator("canvas").count(),1);
    assert.notEqual(await details.locator("canvas").evaluate(c=>c.toDataURL()),before);
    const damaged=Buffer.from(fs.readFileSync(file));
    damaged[damaged.length-1]^=1;
    await picker.setInputFiles({name:"card-contours.json",mimeType:"application/json",buffer:damaged});
    await page.waitForFunction(()=>$("cardContourStatus").textContent.includes("校验未通过"));
    assert.equal(await page.evaluate(()=>CardMap.hasContours),true);
    await openCard();
    const importedPNG=await exportCard("Z58-land");
    assert.notEqual(defaultPNG,importedPNG);
    await context.setOffline(true);
    await page.reload({waitUntil:"domcontentloaded"});
    await openCard();
    assert.equal(await page.evaluate(()=>CardMap.hasContours),true);
    const offlinePNG=await exportCard("Z58-offline");
    assert.equal(offlinePNG,importedPNG);
    assert.deepEqual(errors,[]);
    assert.deepEqual(outlineRequests,[]);
    const receipt={url,defaultPNG,importedPNG,offlinePNG,passportUpdated:true,damagedFileRejected:true,outlineRequests};
    fs.writeFileSync(path.join(output,"context.json"),JSON.stringify(receipt,null,2)+"\n");
    console.log(JSON.stringify(receipt));
  } finally {await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
