// Build input only. The user's offline library stays on their own machine.
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const root = path.join(__dirname, "..", "Web");
const library = vm.runInNewContext(fs.readFileSync(path.join(root, "library.js"), "utf8") + "\nRailLibrary");
const index = library.index(JSON.parse(fs.readFileSync(process.argv[2], "utf8")));
require(path.join(root, "station-directory/national.js"));
const data = global.atlasRailDirectory;
const plans = {};
for (const [number, calendar, calls, id] of data.trains) {
  const dates = data.calendars[calendar];
  const matching = (index.servicesByTrain.get(number) || []).filter(row => {
    if (row.stops.length !== calls.length) return false;
    if (!row.stops.every((stop, i) => stop.station === data.names[calls[i][0]] &&
        (!i || stop.arrival % 1440 === calls[i][1] % 1440) &&
        (i === calls.length - 1 || stop.departure % 1440 === calls[i][2] % 1440))) return false;
    return dates.some(day => day >= row.validFrom.replaceAll("-", "") && day <= row.validThrough.replaceAll("-", ""));
  });
  const candidates = matching.map(row => [row, library.plan(row, index)]).filter(pair => pair[1]);
  if (!candidates.length) continue;
  const [,plan] = candidates[0];
  if (!candidates.every(([,rhs]) => JSON.stringify(rhs) === JSON.stringify(plan))) continue;
  plans[id] = {nodes:plan.nodes.map(n => [n.station, n.kilometre]),
    lines:plan.edges.map(e => e.lineName), stops:plan.stopIndices,
    versions:candidates.map(([row]) => [library.trainNames(row.train),row.validFrom,row.validThrough])};
}
fs.writeFileSync(process.argv[3], JSON.stringify(plans));
console.log(Object.keys(plans).length, "dated trips with matching stop times, order and mileage");
