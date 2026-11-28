// Open a real line share with the same panel layouts available in Settings.
const assert = require("node:assert/strict");
const {withBrowser} = require("./check-history-network.cjs");

withBrowser(async ({browser, url}) => {
  for (const [width, height, left, right] of [[1440,900,"floating","floating"],
       [1440,900,"docked","docked"], [390,844,"floating","floating"]]) {
    const page = await browser.newPage({viewport:{width,height}, serviceWorkers:"block"});
    try {
      await page.goto(url, {waitUntil:"domcontentloaded"});
      await page.waitForFunction(() => typeof state !== "undefined" && state.map && state.routes.length);
      await page.evaluate(([a,b]) => {
        AtlasPrefs.change("panelLayout",a);
        AtlasPrefs.change("inspectorLayout",b);
        setWorkspaceOpen(true);
        location.hash = new URLSearchParams({atlas:"line",name:"陇海线"}).toString();
      }, [left,right]);
      await page.waitForFunction(() => LineFocus.active?.title === "陇海线" && LineFocus.active.parts.length);
      await page.waitForTimeout(250); // allow the mobile drawer to finish closing
      const result = await page.evaluate(() => {
        const map = state.map, rect = map.getContainer().getBoundingClientRect();
        const panels = [...document.querySelectorAll(".left-rail,.right-panel")].filter(p =>
          !p.hidden && !p.hasAttribute("data-ui-folded") && getComputedStyle(p).visibility === "visible"
        ).map(p => p.getBoundingClientRect());
        const points = LineFocus.active.parts.flat().map(ll => map.latLngToContainerPoint(ll))
          .map(({x,y}) => [x + rect.left, y + rect.top]);
        const covered = points.filter(([x,y]) => panels.some(r =>
          x>r.left && x<r.right && y>r.top && y<r.bottom)).length;
        const outside = points.filter(([x,y]) => x<rect.left || x>rect.right || y<rect.top || y>rect.bottom).length;
        return {vertices:points.length,covered,outside,zoom:map.getZoom()};
      });
      console.log(`${width}×${height} ${left}/${right}`, result);
      assert.ok(result.vertices > 1000);
      assert.equal(result.covered, 0);
      assert.equal(result.outside, 0);
    } finally { await page.close(); }
  }
}).catch(err => { console.error(err); process.exitCode=1; });
