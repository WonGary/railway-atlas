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
  const [platform, target] = process.argv.slice(2);
  let app, folder;
  if (platform === "mac" && target) {
    app = fs.realpathSync(target);
    assert.ok(fs.statSync(path.join(app, "Contents/MacOS/RailwayAtlas")).isFile(), "choose the installed Railway Atlas.app");
    const entitlements = execFileSync("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", app],
      {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]});
    if (/<key>com\.apple\.security\.app-sandbox<\/key>\s*<true\s*\/>/.test(entitlements)) {
      const id = run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleIdentifier", path.join(app, "Contents/Info.plist")]);
      // The OS creates the container on first launch. Let the app create its own receipt directory.
      folder = path.join(os.homedir(), "Library/Containers", id, "Data/tmp", "rail-games-installed-" + randomUUID());
    } else {
      folder = fs.mkdtempSync(path.join(os.tmpdir(), "rail-games-installed-"));
    }
    run("/usr/bin/open", ["-n", app, "--args", "--ui-smoke", folder, "--rail-games-check"]);
  } else if (platform === "ios") {
    const device = target || "booted", bundleID = "app.railwayatlas.ios";
    app = run("xcrun", ["simctl", "get_app_container", device, bundleID, "app"]);
    const data = run("xcrun", ["simctl", "get_app_container", device, bundleID, "data"]);
    folder = fs.mkdtempSync(path.join(data, "tmp", "rail-games-installed-"));
    run("xcrun", ["simctl", "launch", "--terminate-running-process", device, bundleID, "--ui-smoke", folder, "--rail-games-check"]);
  } else throw Error('Usage: node check-rail-games-installed.cjs mac "/path/to/Railway Atlas.app" | ios [booted|UDID]');
  const receipt = path.join(folder, "rail-games.json");
  console.log(`验收报告 ${receipt}`);
  for (let i = 0; i < 1500; i++) {
    if (fs.existsSync(receipt)) {
      const report = JSON.parse(fs.readFileSync(receipt, "utf8"));
      assert.equal(fs.realpathSync(report.bundle), fs.realpathSync(app));
      assert.equal(report.status, "PASS", report.error || "app check failed");
      assert.deepEqual(report.rides.map(ride => ride.game), ["rail-blind", "rail-detective", "rail-puzzle", "rail-daily"]);
      for (const ride of report.rides) {
        assert.ok(ride.mainMapVisible && ride.playerRunning && ride.markerOnMap && ride.legs === ride.stations.length - 1);
        console.log(`PASS ${ride.game}  ${ride.train}  ${ride.date}  ${ride.stations.join(" → ")}  ${ride.legs} 段`);
      }
      return;
    }
    await delay(100);
  }
  throw Error("150 秒内未收到验收报告，请检查已安装的版本是否包含 --rail-games-check。");
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
