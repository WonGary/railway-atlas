// Same-origin OSM way geometry, names and tags. Parent cells retain metre-scale
// coordinates so a zoomed-in view never needs to enlarge the Z4 overview.
const PackedRail = (() => {
  const root = "./data/rail/detail/", cells = new Map();
  let manifest;
  function geometry(text, left, top, scale) {
    const points = [];
    let offset = 0, x = 0, y = 0;
    function delta() {
      let bits = 0, shift = 0, digit;
      do {
        digit = text.charCodeAt(offset++) - 63;
        bits |= (digit & 31) << shift;
        shift += 5;
      } while (digit >= 32);
      return (bits >>> 1) ^ -(bits & 1);
    }
    while (offset < text.length) {
      x += delta(); y += delta();
      points.push({x:(x-left)*scale, y:(y-top)*scale});
    }
    return [points];
  }
  function cell(file) {
    if (!cells.has(file)) {
      const pending = loadJSON(root + file).catch(error => { cells.delete(file); throw error; });
      cells.set(file, pending);
      if (cells.size > 32) cells.delete(cells.keys().next().value);
    }
    return cells.get(file);
  }
  async function tile({x,y,z}) {
    if (z < 7) return null;
    manifest ??= loadJSON(root+"index.json").catch(error => { manifest = null; throw error; });
    const index = await manifest, scale = 2**(z-index.zoom);
    const file = index.cells[`${Math.floor(x/scale)}/${Math.floor(y/scale)}`];
    if (!file) return null;
    const span = index.extent/scale, left = (x%scale)*span, top = (y%scale)*span;
    const pad = span/64;
    const rows = (await cell(file)).filter(r => r[7]>=left-pad && r[5]<=left+span+pad && r[8]>=top-pad && r[6]<=top+span+pad);
    if (!rows.length) return null;
    return {layers:{atlas_rail_detail:{length:rows.length, feature(i) {
      const row = rows[i], [id,name,maxspeed,usage,service] = row;
      const tags = {railway:"rail",osm_id:id,source:"OpenStreetMap · HOT / QLever"};
      if (name) tags.name = name;
      if (maxspeed) tags.maxspeed = maxspeed;
      if (usage) tags.usage = usage;
      if (service) tags.service = service;
      return {id, type:2, extent:4096, properties:tags,
        bbox:()=>[(row[5]-left)*4096/span,(row[6]-top)*4096/span,(row[7]-left)*4096/span,(row[8]-top)*4096/span],
        loadGeometry:()=>geometry(row[9],left,top,4096/span)};
    }}}};
  }
  // Keep anonymous backup tracks only where the local extract has no track.
  // Build the mask from geometry, independent of filters, colour or tile borders.
  function mask(layer, scale, dx, dy) {
    if (!layer) return null;
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 128;
    const ctx = canvas.getContext("2d", {willReadFrequently:true});
    ctx.lineWidth = 4; ctx.lineJoin = ctx.lineCap = "round"; ctx.beginPath();
    for (let i=0;i<layer.length;i++) {
      const f = layer.feature(i), factor = 256*scale/f.extent;
      for (const path of f.loadGeometry()) path.forEach((p,j) => ctx[j?"lineTo":"moveTo"]((p.x*factor-dx)/2,(p.y*factor-dy)/2));
    }
    ctx.stroke();
    const data = ctx.getImageData(0,0,128,128).data;
    return ([x,y]) => x>=0 && y>=0 && x<256 && y<256 && data[4*(128*Math.floor(y/2)+Math.floor(x/2))+3]>0;
  }
  function outside(points, covered) {
    const pieces = []; let piece;
    for (let j=1;j<points.length;j++) {
      const [ax,ay] = points[j-1], [bx,by] = points[j];
      const segment = L.LineUtil.clipSegment(L.point(ax,ay),L.point(bx,by),L.bounds([-2,-2],[258,258]));
      if (!segment) { piece=null; continue; }
      const [a,b]=segment, count=Math.max(1,Math.ceil(a.distanceTo(b)/3));
      for(let k=0;k<count;k++) {
        const point=t=>[a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t];
        if (covered(point((k+.5)/count))) { piece=null; continue; }
        const start=point(k/count),end=point((k+1)/count);
        if(!piece || piece.at(-1)[0]!==start[0] || piece.at(-1)[1]!==start[1]) { piece=[start]; pieces.push(piece); }
        piece.push(end);
      }
    }
    return pieces;
  }
  return {tile, mask, outside};
})();
