// Use an already installed .app or iOS Simulator app. No checkout, browser driver or build step required.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const {randomUUID} = require("node:crypto");
const assert = require("node:assert/strict");
const {execFileSync} = require("node:child_process");
const {setTimeout: delay} = require("node:timers/promises");
const run = (file, args) => execFileSync(file, args, {encoding: "utf8"}).trim();

async function main() {
  const [platform, target, suite = "games"] = process.argv.slice(2);
  const suites = {
    games: {name:"rail-games", flags:["--rail-games-check"]},
    passport: {name:"passport-footprints", flags:["--experiences-check", "--passport-footprints-check"]},
    inspector: {name:"route-inspector", flags:["--route-inspector-check"]}
  };
  assert.ok(Object.hasOwn(suites, suite), "choose games, passport or inspector");
  const {name, flags} = suites[suite];
  const prefix = `${name}-installed-`;
  let app, folder;
  if (platform === "mac" && target) {
    app = fs.realpathSync(target);
    assert.ok(fs.statSync(path.join(app, "Contents/MacOS/RailwayAtlas")).isFile(), "choose the installed Railway Atlas.app");
    const entitlements = execFileSync("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", app],
      {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]});
    if (/<key>com\.apple\.security\.app-sandbox<\/key>\s*<true\s*\/>/.test(entitlements)) {
      const id = run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleIdentifier", path.join(app, "Contents/Info.plist")]);
      // The OS creates the container on first launch. Let the app create its own receipt directory.
      folder = path.join(os.homedir(), "Library/Containers", id, "Data/tmp", prefix + randomUUID());
    } else {
      folder = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
    }
    run("/usr/bin/open", ["-n", app, "--args", "--ui-smoke", folder, ...flags]);
  } else if (platform === "ios") {
    const device = target || "booted", bundleID = "app.railwayatlas.ios";
    app = run("xcrun", ["simctl", "get_app_container", device, bundleID, "app"]);
    const data = run("xcrun", ["simctl", "get_app_container", device, bundleID, "data"]);
    folder = fs.mkdtempSync(path.join(data, "tmp", prefix));
    run("xcrun", ["simctl", "launch", "--terminate-running-process", device, bundleID, "--ui-smoke", folder, ...flags]);
  } else throw Error('Usage: node check-rail-games-installed.cjs mac "/path/to/Railway Atlas.app" [games|passport|inspector] | ios booted [games|passport|inspector]');
  const receipt = path.join(folder, name + ".json");
  console.log(`验收报告 ${receipt}`);
  for (let i = 0; i < 1500; i++) {
    if (fs.existsSync(receipt)) {
      const report = JSON.parse(fs.readFileSync(receipt, "utf8"));
      assert.equal(fs.realpathSync(report.bundle), fs.realpathSync(app));
      assert.equal(report.status, "PASS", [report.stage, report.error].filter(Boolean).join(" / ") || "app check failed");
      if (suite === "inspector") {
        assert.deepEqual(report.pairs.map(p=>p.other), ["D176", "D2236"]);
        assert.deepEqual(report.pairs.map(p=>p.mapLayers), [["shared"], ["first", "second", "shared"]]);
        assert.deepEqual(report.pairs[0].uniqueMetres, [0, 0]);
        assert.ok(report.pairs[1].uniqueMetres.every(n=>n>1000));
        assert.equal(report.day, "2026-11-26");
        assert.ok(report.legVertices>2 && report.station && report.stationCount===20 && report.lineParts>0);
        for (const pair of report.pairs) {
          assert.ok(pair.mapLayers.every(key=>pair.inkPixels[key]>10));
          console.log(`PASS D174 / ${pair.other}  ${pair.mapLayers.join(" + ")}  ${JSON.stringify(pair.inkPixels)}`);
        }
        console.log(`PASS ${report.physicalLine}  ${report.stationCount} 个站所  定位 ${report.station}`);
        return;
      }
      if (suite === "passport") {
        assert.deepEqual(report.stages, ["shelves-and-overnight", "review-and-dedup", "geometry-mileage-and-gaps",
          "local-persistence-and-stamps", "edit-delete-undo"]);
        assert.equal(report.section, "乐都 → 平安驿");
        assert.ok(report.origin < report.boarding && report.boarding === "2026-11-25" && report.metres > 0);
        console.log(`PASS Z230 ${report.boarding} ${report.section} ${(report.metres / 1000).toFixed(1)} km`);
        console.log(report.stages.join("\n"));
        return;
      }
      assert.deepEqual(report.rides.map(ride => ride.game), ["rail-blind", "rail-detective", "rail-puzzle", "rail-daily"]);
      for (const ride of report.rides) {
        assert.ok(ride.mainMapVisible && ride.playerRunning && ride.markerOnMap && ride.legs === ride.stations.length - 1);
        console.log(`PASS ${ride.game}  ${ride.train}  ${ride.date}  ${ride.stations.join(" → ")}  ${ride.legs} 段`);
      }
      return;
    }
    await delay(100);
  }
  throw Error(`150 秒内未收到验收报告，请检查已安装的版本是否支持 ${flags.at(-1)}。`);
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
