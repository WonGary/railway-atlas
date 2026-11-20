import fs from "node:fs";

// Diagnostic wire-format inspector; reports field distributions, not full data.
function fields(data) {
  let offset = 0;
  const varint = () => {
    let value = 0n, shift = 0n;
    while (offset < data.length) {
      const byte = data[offset++];
      value |= BigInt(byte & 127) << shift;
      if (!(byte & 128)) return Number(value);
      shift += 7n;
      if (shift > 63n) throw new Error("invalid varint");
    }
    throw new Error("truncated varint");
  };
  const result = [];
  while (offset < data.length) {
    const field = varint(), type = field & 7, number = field >> 3;
    let value;
    if (type === 0) value = varint();
    else if (type === 2) {
      const length = varint();
      value = data.subarray(offset, offset + length);
      offset += length;
    } else if (type === 1) { value = data.readDoubleLE(offset); offset += 8; }
    else if (type === 5) { value = data.readFloatLE(offset); offset += 4; }
    else throw new Error("invalid wire type");
    result.push([number, value]);
  }
  return result;
}
function packed(data) {
  let offset = 0, values = [];
  while (offset < data.length) {
    let value = 0, shift = 0, byte;
    do { byte = data[offset++]; value += (byte & 127) * 2 ** shift; shift += 7; } while (byte & 128);
    values.push(value);
  }
  return values;
}
for (const [, layer] of fields(fs.readFileSync(process.argv[2]))) {
  const f = fields(layer), name = f.find(([n]) => n === 1)?.[1].toString();
  if (!/railway|transport|streets|poi/.test(name ?? "")) continue;
  const keys = f.filter(([n]) => n === 3).map(([, v]) => v.toString());
  const values = f.filter(([n]) => n === 4).map(([, v]) => {
    const [[n, value]] = fields(v);
    return n === 1 ? value.toString() : n === 7 ? !!value : value;
  });
  const counts = {};
  const samples = [];
  for (const [, feature] of f.filter(([n]) => n === 2)) {
    const properties = {};
    for (const [n, value] of fields(feature)) {
      if (n !== 2) continue;
      const tags = packed(value);
      for (let i = 0; i < tags.length; i += 2) properties[keys[tags[i]]] = values[tags[i + 1]];
    }
    const classification = [properties.class, properties.subclass, properties.kind, properties.rail].filter(v => v != null).join("/");
    counts[classification] = (counts[classification] ?? 0) + 1;
    if (samples.length < 3) samples.push(properties);
  }
  console.log(JSON.stringify({ name, counts, samples }, null, 2));
}
