// Bundle independently licensed palette DATA, no upstream application code.
// Pin source revision; retain every original JSON field and the upstream GPL.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
const revision = '402c272b090c1548c5ffc867bb5d84469427278f';
const root = path.resolve(import.meta.dirname, '..');
const locations = JSON.parse(fs.readFileSync(path.join(import.meta.dirname, 'china-metro-cities.json')));
const overrides = JSON.parse(fs.readFileSync(path.join(import.meta.dirname, 'metro-palette-aliases.json')));
// One pinned archive instead of hundreds of serial requests. A local extracted
// archive can be passed as argv[2] to reproduce the resource without networking.
let upstream = process.argv[2];
if (!upstream) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'atlas-palette-'));
  const archive = path.join(temporary, 'source.tar.gz');
  await run('curl', ['-fLsS', '--connect-timeout', '8', '--max-time', '60', '--retry', '1',
    `https://codeload.github.com/railmapgen/rmg-palette/tar.gz/${revision}`, '-o', archive]);
  await run('tar', ['-xzf', archive, '-C', temporary]);
  upstream = path.join(temporary, `rmg-palette-${revision}`);
}
const catalogue = JSON.parse(fs.readFileSync(path.join(upstream, 'public/resources/city-config.json')));
const cities = catalogue.map(city => {
  const { id } = city;
  const location = locations.find(row => row[0] === id);
  const extra = overrides[id] ?? {};
  const lines = JSON.parse(fs.readFileSync(path.join(upstream, `public/resources/palettes/${id}.json`)));
  if (!Array.isArray(lines) || lines.some(r => typeof r.id !== 'string' || !/^#[0-9a-f]{6}$/i.test(r.colour) || !r.name))
    throw Error(`Invalid ${id}`);
  return { ...city, latitude: location?.[2] ?? extra.latitude, longitude: location?.[3] ?? extra.longitude,
    aliases: [...new Set([...(location?.[4].split('|') ?? []), ...(extra.aliases ?? [])])],
    lineAliases: extra.lines ?? {},
    source: `https://github.com/railmapgen/rmg-palette/blob/${revision}/public/resources/palettes/${id}.json`,
    url: `https://railmapgen.org/rmg-palette/resources/palettes/${id}.json`, lines };
});
const resource = path.join(root, 'Sources/RailwayCore/Resources');
const license = path.join(resource, 'METRO-PALETTE-LICENCE.txt');
fs.copyFileSync(path.join(upstream, 'LICENCE'), license);
const output = JSON.stringify({ version: 1, revision, license: 'GPL-3.0', cities });
fs.writeFileSync(path.join(resource, 'metro-palette.json'), output + '\n');
console.log(`${cities.length} cities, ${cities.reduce((n, c) => n + c.lines.length, 0)} palette entries, ${Buffer.byteLength(output)} bytes`);
