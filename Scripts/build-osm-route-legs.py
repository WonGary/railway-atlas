"""Match dated operating plans to connected OSM rail ways at release time.

Arguments: sources national.js plans.json shape-directory output.json [train ...]
Sources may be a HOT country export or comma-separated regional OSM PBF extracts.
PBF input requires pyosmium.
"""
import functools
import heapq
import importlib.util
import itertools
import json
import math
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from zipfile import ZipFile

from scipy.spatial import cKDTree
from shapely.geometry import LineString
from shapely.geometry import Point
from shapely.ops import substring

spec = importlib.util.spec_from_file_location("compiler", Path(__file__).with_name("build-route-atlas.py"))
compiler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compiler)


def distance(a, b):
    return math.hypot((a[0]-b[0])*math.cos(math.radians((a[1]+b[1])/2)), a[1]-b[1])*111195


def line_key(text):
    return re.sub(r"(?:高速铁路|高速线|高速|高铁|客运专线|客专线|客专|城际铁路|铁路|线)$", "", text)


EQUIVALENT = [
    ("昌九城际线", "昌九城际铁路"), ("武九大庐段", "武九客运专线", "武九客专线"),
    ("武石城际线", "武黄城际铁路", "武九客运专线"), ("宁蓉线", "沪蓉线", "沪汉蓉铁路", "汉宜铁路", "宜万铁路", "渝利铁路", "遂渝铁路", "遂成铁路"),
    ("成宜高铁", "成自宜高速铁路", "成自高速铁路", "成宜高速铁路"),
    ("渝昆渝宜段", "渝昆高速铁路"), ("昆万昆磨段", "玉磨铁路", "昆玉铁路", "中老铁路", "昆玉河铁路"),
    ("湘桂线", "湘桂铁路"), ("衡柳线", "衡柳铁路"), ("柳南客专线", "柳南城际铁路", "柳南客运专线"),
    ("深湛江湛段", "深湛线", "深湛铁路", "江湛铁路", "深茂铁路"),
    ("海南西环线", "西环货线", "海南西环铁路"),
    ("集包线", "集包铁路", "集包第二双线"), ("西长铁路", "西长联络线"),
    ("柳广线", "柳村联络线"),  # OSM railway relation 13890345, old_name
    ("兰渝兰渭段", "兰渝线", "兰渝铁路"),
]

# These adjacent operating points have the same mileage in both line tables.
# A shared approach is not an alias for either railway outside the two stations.
SHARED_APPROACHES = {
    ("京原线", frozenset(("原平", "薛孤"))): "韩原线",
    ("京九线", frozenset(("北京西", "广安门"))): "京雄城际线",
}


def stage_lines(lines, start, finish):
    wanted = set(lines)
    pair = frozenset((start, finish))
    for line in lines:
        alternative = SHARED_APPROACHES.get((line, pair))
        if alternative:
            wanted.add(alternative)
    return wanted


def affinity(name, wanted):
    if not name:
        return 1.7
    names = set(re.split(r"[;/；、]", name))
    if any(a == b or ((bool(re.search("高速|高铁|客专", a)) == bool(re.search("高速|高铁|客专", b))) and
            line_key(a) == line_key(b)) for a in names for b in wanted):
        return 1.0
    if any(names.intersection(aliases) and wanted.intersection(aliases) for aliases in EQUIVALENT):
        return 1.0
    return 5.0


def features(archive, seen=None):
    if seen is None:
        seen = set()
    if "," in archive:
        for source in archive.split(","):
            yield from features(source, seen)
        return
    if archive.endswith(".json"):
        snapshot = json.loads(Path(archive).read_text())
        if snapshot.get("remark") or not snapshot.get("osm3s", {}).get("timestamp_osm_base"):
            raise ValueError(f"Incomplete Overpass response: {archive}")
        for element in snapshot["elements"]:
            tags = element.get("tags", {})
            name = tags.get("name:zh") or tags.get("name") or ""
            if element["type"] == "node" and tags.get("railway") in ("station", "halt", "junction", "yard", "signal_box", "switch") and name:
                yield {"type": "Point", "coordinates": (element["lon"], element["lat"])}, tags | {"name": name}
            elif element["type"] == "way" and tags.get("railway") == "rail":
                vertices = element.get("geometry", [])
                if element["id"] not in seen and len(vertices) >= 2 and all(p and "lon" in p and "lat" in p for p in vertices):
                    seen.add(element["id"])
                    names = [name, tags.get("official_name"), tags.get("alt_name")]
                    yield {"type": "LineString", "coordinates": [(p["lon"], p["lat"]) for p in vertices]}, {
                        "name": ";".join(dict.fromkeys(n for n in names if n)), "railway": "rail"}
        return
    if archive.endswith(".zip"):
        with ZipFile(archive) as z, z.open("railways.geojson") as file:
            for line in file:
                if line.startswith(b'{ "type": "Feature"'):
                    feature = json.loads(line.rstrip(b",\r\n"))
                    # HOT splits ways by administrative unit. Keep every fragment
                    # unless a higher-priority source already provided the whole way.
                    kind, _, ident = str(feature["properties"].get("id", "")).partition("/")
                    if kind == "way" and ident.isdecimal() and int(ident) in seen:
                        continue
                    yield feature["geometry"], feature["properties"]
        return
    import osmium
    for source in archive.split(","):
        reader = osmium.FileProcessor(osmium.io.File(source, "pbf")).with_locations("flex_mem")
        for obj in reader.with_filter(osmium.filter.KeyFilter("railway")):
            rail = obj.tags.get("railway")
            name = obj.tags.get("name:zh") or obj.tags.get("name") or ""
            if obj.is_node() and name and rail in ("station", "halt", "junction", "yard", "signal_box", "switch"):
                yield {"type":"Point", "coordinates":(obj.lon,obj.lat)}, dict(obj.tags) | {"name":name}
            if not obj.is_way() or rail not in ("rail","ferry") or obj.id in seen:
                continue
            if not all(node.location.valid() for node in obj.nodes):
                continue
            seen.add(obj.id)
            labels = [name, obj.tags.get("official_name"), obj.tags.get("alt_name")]
            if rail == "ferry":
                if obj.tags.get("route") != "ferry": continue
                labels = ["rail-ferry/" + name]
            yield {"type":"LineString", "coordinates":[(n.lon,n.lat) for n in obj.nodes]}, {
                "name":";".join(dict.fromkeys(s for s in labels if s)), "railway":"rail"}


class Network:
    def __init__(self, archive, national):
        self.locations = defaultdict(list)
        self.points, self.adj = [], []
        ways, ends = [], set()
        railway_stations = defaultdict(set)
        urban_stations = defaultdict(set)
        for geo, tags in features(archive):
            name = tags.get("name_zh") or tags.get("name") or ""
            if geo["type"] == "Point" and name:
                if tags.get("station") in ("subway", "light_rail", "tram") or tags.get("subway") == "yes":
                    urban_stations[name.removesuffix("站")].add(tuple(geo["coordinates"]))
                    continue
                names = {name.removesuffix("站")}
                if tags.get("railway") == "junction" and name.endswith("线路所"):
                    names.update((name[:-3], name[:-3] + "所"))
                coordinate = tuple(geo["coordinates"])
                for key in names:
                    self.locations[key].append(coordinate)
                    if tags.get("railway:ref") and tags.get("railway") in ("station", "halt", "junction"):
                        railway_stations[key].add(coordinate)
            if geo["type"] not in ("LineString", "MultiLineString") or tags["railway"] != "rail":
                continue
            for raw in [geo["coordinates"]] if geo["type"] == "LineString" else geo["coordinates"]:
                path = [tuple(p[:2]) for p in raw]
                if len(path) < 2: continue
                ways.append((name, path))
                ends.update([path[0], path[-1]])
        for name, coord in zip(national["names"], national["coordinates"]):
            if coord and coord[0] > 0 and coord[1] > 0:
                published = (coord[1], coord[0])
                nearby = [p for p in railway_stations.get(name, ()) if 1700 < distance(p, published) < 12000]
                at_metro = any(distance(p, published) < 250 for p in urban_stations.get(name, ()))
                self.locations[name] = nearby if at_metro and len(nearby) == 1 else [published]
        ids = {}
        def node(p):
            key = (round(p[0], 6), round(p[1], 6))
            if key not in ids:
                ids[key] = len(self.points)
                self.points.append(key)
                self.adj.append([])
            return ids[key]
        for name, path in ways:
            cuts = [i for i,p in enumerate(path) if p in ends]
            for a,b in zip(cuts,cuts[1:]):
                coords = LineString(path[a:b+1]).simplify(.00012, preserve_topology=False).coords
                prev = node(coords[0])
                for p in coords[1:]:
                    # Include candidate attachment vertices on straight station tracks.
                    old = self.points[prev]
                    n = max(1, math.ceil(distance(old,p)/650))
                    for i in range(1,n+1):
                        nxt = node(tuple(x+(y-x)*i/n for x,y in zip(old,p)))
                        if prev != nxt:
                            length = distance(self.points[prev],self.points[nxt])
                            self.adj[prev].append((nxt,length,name)); self.adj[nxt].append((prev,length,name))
                        prev = nxt
        self.tree = cKDTree([(lon*.83,lat) for lon,lat in self.points])
        # The export clips OSM ways at administrative boundaries. Preserve the
        # crossing when two cut ends of the same named rail meet within 12 m.
        for i,edges in enumerate(self.adj):
            if len(edges)!=1 or not edges[0][2]: continue
            p=self.points[i]; name=edges[0][2]
            for j in self.tree.query_ball_point((p[0]*.83,p[1]),.00014):
                if j<=i or len(self.adj[j])!=1 or self.adj[j][0][2]!=name: continue
                gap=distance(p,self.points[j])
                if gap<=12:
                    self.adj[i].append((j,gap,name));self.adj[j].append((i,gap,name))
        print(f"OSM graph: {len(self.points)} vertices and {len(self.locations)} station names", flush=True)

    @functools.lru_cache(maxsize=None)
    def position(self, name):
        candidates = self.locations.get(name) or self.locations.get(name.replace("线路所","所"))
        if candidates and all(distance(candidates[0],p)<1700 for p in candidates):
            return candidates[0]

    @functools.lru_cache(maxsize=16384)
    def nearby(self, loc):
        return {int(i): d for i in self.tree.query_ball_point((loc[0]*.83, loc[1]), .009)
                if (d := distance(self.points[i], loc)) < 800}

    @functools.lru_cache(maxsize=None)
    def path(self, start, finish, lines, kilometres):
        p, q = self.position(start), self.position(finish)
        if not p or not q or kilometres <= 0:
            return None
        geodesic = distance(p,q)
        if geodesic > kilometres*1250+1800:
            return None
        wanted = stage_lines(lines, start, finish)
        ferry = any("轮渡" in line for line in lines)
        @functools.lru_cache(maxsize=None)
        def weight(name):
            if name.startswith("rail-ferry/"):
                return 1.0 if ferry and affinity(name.removeprefix("rail-ferry/"), wanted)==1 else math.inf
            return affinity(name,wanted)
        initial = {i: d*3 for i, d in self.nearby(p).items()}
        target = {i: d*3 for i, d in self.nearby(q).items()}
        if not initial or not target:
            return None
        queue = [(d+distance(self.points[i],q),d,i) for i,d in initial.items()]
        heapq.heapify(queue)
        costs = dict(initial); parent={}; end=None; best=math.inf
        limit = kilometres*2200+4500
        while queue:
            score,cost,i = heapq.heappop(queue)
            if score>min(best,limit): break
            if cost!=costs.get(i): continue
            if i in target and cost+target[i]<best:
                best,end=cost+target[i],i
            for j,length,name in self.adj[i]:
                w=weight(name)
                alt=cost+length*w
                if alt<costs.get(j, math.inf):
                    costs[j]=alt
                    parent[j]=(i,w,length)
                    heapq.heappush(queue,(alt+distance(self.points[j],q),alt,j))
        if end is None:
            if os.getenv("ATLAS_TRACE_MATCH"): print(start,finish,"disconnected",kilometres,flush=True)
            return None
        trace=[self.points[end]]; total=named=conflict=0
        used_ferry = False
        while end in parent:
            child = end
            end,w,length=parent[end]
            if ferry and not used_ferry:
                used_ferry = any(j==child and n.startswith("rail-ferry/") and weight(n)==1 for j,_,n in self.adj[end])
            total+=length
            if w==1: named+=length
            if w>2: conflict+=length
            trace.append(self.points[end])
        # A ferry's fare distance includes a tariff multiplier. Require the mapped
        # railway ferry itself and constrain physical length by the station separation.
        length_ok = (used_ferry and geodesic*.90 <= total <= geodesic*1.8+3000) if ferry else (
            abs(total-kilometres*1000)<=max(2300,kilometres*175))
        if (len(trace)<2 or not length_ok
                or named<min(total*.32,1500) or conflict>max(2000,.12*total)):
            if os.getenv("ATLAS_TRACE_MATCH"): print(start,finish,"km actual/named/conflicting/plan",*(round(x/1000,1) for x in (total,named,conflict)),kilometres,flush=True)
            return None
        return trace[::-1]

    def connect(self, left, right, max_gap=1600):
        gap=distance(left,right)
        if gap<=100: return []
        if gap>max_gap: return None
        def attach(p):
            result={}
            for i in self.tree.query_ball_point((p[0]*.83,p[1]),.007):
                a=self.points[i]
                for j,_,_ in self.adj[i]:
                    if i>=j: continue
                    b=self.points[j]; sx=math.cos(math.radians(p[1]))
                    dx=(b[0]-a[0])*sx;dy=b[1]-a[1]
                    fraction=max(0,min(1,((p[0]-a[0])*sx*dx+(p[1]-a[1])*dy)/max(1e-20,dx*dx+dy*dy)))
                    foot=(a[0]+(b[0]-a[0])*fraction,a[1]+dy*fraction)
                    offset=distance(p,foot)
                    if offset>100: continue
                    for k in (i,j):
                        cost=3*offset+distance(foot,self.points[k])
                        if cost < result.get(k,(math.inf,None))[0]: result[k]=(cost,foot)
            return result
        starts=attach(left); ends=attach(right)
        queue=[(d,i) for i,(d,_) in starts.items()];heapq.heapify(queue)
        costs={i:v[0] for i,v in starts.items()}; prev={}; best=math.inf; end=None
        while queue:
            cost,i=heapq.heappop(queue)
            if cost!=costs.get(i): continue
            if cost>min(best,gap*2+650): break
            if i in ends and cost+ends[i][0]<best:
                best,end=cost+ends[i][0],i
            for j,length,_ in self.adj[i]:
                alt=cost+length
                if alt<costs.get(j,math.inf):
                    costs[j]=alt;prev[j]=i;heapq.heappush(queue,(alt,j))
        if end is not None and best<gap*2+650:
            points=[ends[end][1],self.points[end]]
            while end in prev:
                end=prev[end];points.append(self.points[end])
            points.append(starts[end][1])
            return points[::-1]
        return None

    def station_throat(self, inbound, outbound, station):
        """Replace just the approaches to a station with a through track.

        The two shapes may end at widely separated platform tracks. Attach on
        either side of the station, keep the rest of each leg, and split the
        continuous OSM path at the closest point to the passenger station.
        """
        if not station or max(distance(inbound[-1],station),distance(outbound[0],station))>850: return None
        sx=111195*math.cos(math.radians(station[1]))
        def metric(p): return ((p[0]-station[0])*sx,(p[1]-station[1])*111195)
        def geog(p): return (station[0]+p[0]/sx,station[1]+p[1]/111195)
        a,b=(LineString([metric(p) for p in leg]) for leg in (inbound,outbound))
        for reach in (1100,2100,3500,5000):
            if min(a.length,b.length) < reach+200: continue
            prefix=substring(a,0,a.length-reach); suffix=substring(b,reach,b.length)
            p,q=geog(prefix.coords[-1]),geog(suffix.coords[0])
            middle=self.connect(p,q,max_gap=reach*2+250)
            if not middle: continue
            track=LineString([metric(point) for point in [p,*middle,q]])
            if not reach*1.65 <= track.length <= reach*2.35 or track.distance(Point(0,0))>350: continue
            cut=track.project(Point(0,0))
            if not reach*.55 < cut < track.length-reach*.55: continue
            arrival=[*prefix.coords,*substring(track,0,cut).coords]
            departure=[*substring(track,cut,track.length).coords,*suffix.coords]
            return tuple(compiler.pack([geog(p) for p in path]) for path in (arrival,departure))

    def via_stations(self, plan, anchors):
        """Find a *single* connected path through ordered station neighbourhoods.

        This avoids independently snapping arrival and departure to incompatible
        platform tracks. Weight each stage by its own operating line.
        """
        nodes = plan["nodes"]
        centres = [self.position(nodes[i][0]) for i in anchors]
        stages = []
        for a,b in zip(anchors, anchors[1:]):
            wanted = stage_lines(plan["lines"][a:b], nodes[a][0], nodes[b][0])
            # The Hohhot–Baotou passenger corridor was renamed. Keep aliases
            # scoped to its historical segment, away from the parallel freight line.
            if "集包线" in wanted:
                west = {"台阁牧","察素齐","萨拉齐","包头东","包头"}
                if nodes[a][0] in west and nodes[b][0] in west: wanted.add("京包客专线")
                if {nodes[a][0],nodes[b][0]} == {"呼和浩特","台阁牧"}: wanted.update(["京包线","京包客专线"])
            stages.append(wanted)
        candidates = [self.nearby(p) for p in centres]
        if not all(candidates): return None
        @functools.lru_cache(maxsize=None)
        def weight(stage, name):
            return affinity(name,stages[stage]) if not name.startswith("rail-ferry/") else (
                1.0 if affinity(name.removeprefix("rail-ferry/"),stages[stage])==1 else math.inf)
        limit = (nodes[anchors[-1]][1]-nodes[anchors[0]][1])*2400+5000
        queue, costs, parent = [], {}, {}
        for j in candidates[0]:
            costs[(0,j)] = cost = 3*distance(centres[0],self.points[j])
            heapq.heappush(queue,(cost,cost,0,j))
        best, end = math.inf, None
        while queue:
            estimate,cost,stage,j = heapq.heappop(queue)
            if estimate > min(best,limit): break
            if cost != costs.get((stage,j)): continue
            last = stage == len(stages)-1
            if j in candidates[stage+1]:
                if last:
                    value=cost+3*distance(centres[-1],self.points[j])
                    if value < best: best,end=value,(stage,j)
                elif cost < costs.get((stage+1,j),math.inf):
                    costs[(stage+1,j)]=cost
                    parent[(stage+1,j)]=((stage,j),0,1,False)
                    heapq.heappush(queue,(cost,cost,stage+1,j))
            for k,length,name in self.adj[j]:
                w=weight(stage,name)
                alt=cost+length*w
                if alt >= costs.get((stage,k),math.inf): continue
                costs[(stage,k)]=alt
                parent[(stage,k)]=((stage,j),length,w,name.startswith("rail-ferry/"))
                heapq.heappush(queue,(alt+distance(self.points[k],centres[-1]),alt,stage,k))
        if end is None: return None
        points=[self.points[end[1]]]
        totals=[[0,0,0,False] for _ in stages]
        while end in parent:
            prev,length,w,ferry=parent[end]
            if length:
                rec=totals[end[0]]
                rec[0]+=length; rec[1]+=length if w==1 else 0; rec[2]+=length if w>2 else 0
                rec[3]|=ferry; points.append(self.points[prev[1]])
            end=prev
        # Fare kilometres may be rounded differently at intermediate junctions.
        # Check the complete leg, each line, and the physical ferry separately.
        expected=0
        for stage,((a,b),(length,named,conflict,ferry)) in enumerate(zip(zip(anchors,anchors[1:]),totals)):
            km=nodes[b][1]-nodes[a][1]
            if any("轮渡" in n for n in stages[stage]):
                direct=distance(centres[stage],centres[stage+1])
                if not ferry or not direct*.9 <= length <= direct*1.8+3000: return None
                expected+=length
            else:
                if abs(length-km*1000)>max(6500,km*230): return None
                expected+=km*1000
            if named<min(length*.32,1500) or conflict>max(2200,length*.12): return None
        if abs(sum(v[0] for v in totals)-expected)>max(2500,expected*.14): return None
        return compiler.pack(points[::-1])

    def leg(self, plan, i):
        a,b=plan["stops"][i:i+2]; nodes=plan["nodes"]; lanes=plan["lines"]
        anchors=[j for j in range(a,b+1) if self.position(nodes[j][0])]
        if not anchors or anchors[0]!=a or anchors[-1]!=b:
            return None
        if any(len(set(lanes[x:y])) > 1 for x,y in zip(anchors,anchors[1:])):
            return None  # An unlocated line change cannot be checked against the graph.
        if any(not self.nearby(self.position(nodes[j][0])) for j in anchors):
            return None
        output=[]
        for x,y in zip(anchors,anchors[1:]):
            part=self.path(nodes[x][0],nodes[y][0],tuple(sorted(set(lanes[x:y]))),nodes[y][1]-nodes[x][1])
            if not part:
                break
            if output:
                connector=self.connect(output[-1],part[0])
                if connector is None: break
                output.extend(connector)
            output.extend(part)
        else:
            return compiler.pack(output) if len(output)>1 else None
        # Some passenger station positions lie on a platform centre or a different
        # track. Test the whole leg against each known intermediate station in order.
        same_line = len(set(lanes[a:b])) == 1
        part = self.path(nodes[a][0],nodes[b][0],(lanes[a],),nodes[b][1]-nodes[a][1]) if same_line else None
        if part:
            last=0
            for j in anchors[1:-1]:
                loc=self.position(nodes[j][0])
                near=min(range(last,len(part)),key=lambda ix:distance(part[ix],loc))
                if distance(part[near],loc)>1500: break
                last=near
            else: return compiler.pack(part)
        return self.via_stations(plan,anchors)


def main():
    hot, src, plans, shapes, out, *numbers = sys.argv[1:]
    data=json.loads(Path(src).read_text().split(" = ",1)[1].rstrip(";\n"))
    plans=json.loads(Path(plans).read_text())
    shapes=Path(shapes)
    results=json.loads(Path(out).read_text()) if Path(out).exists() else {}
    graph=Network(hot,data)
    dirs=json.loads((shapes/"index.json").read_text())
    count=0
    join="--joins" in numbers
    if join: numbers.remove("--joins")
    for group in dirs["groups"].values():
        data_group=json.loads((shapes/group).read_text())
        trains=data_group["trains"]
        for number,entries in trains.items():
            if numbers and number not in numbers: continue
            for record in entries:
                trip=record["id"]
                if trip not in plans: continue
                fill=results.setdefault(trip,{})
                for i,k in enumerate(record["k"]):
                    if not k and str(i) not in fill:
                        path=graph.leg(plans[trip],i)
                        if path: fill[str(i)]=path
                if join:
                    previous=None
                    for i,k in enumerate(record["k"]):
                        encoded=fill.get(f"join:{i}") or (data_group["paths"][record["p"][i]] if k else fill.get(str(i)))
                        if not encoded: previous=None; continue
                        leg=compiler.unpack(encoded)
                        if previous is not None and distance(previous[-1],leg[0])>120:
                            connector=graph.connect(previous[-1],leg[0])
                            if connector:
                                fill[f"join:{i}"]=compiler.pack([previous[-1],*connector,*leg])
                            else:
                                plan=plans[trip]
                                station=plan["nodes"][plan["stops"][i]][0]
                                pair=graph.station_throat(previous,leg,graph.position(station))
                                if pair:
                                    fill[f"join:{i-1}"],fill[f"join:{i}"]=pair
                                    leg=compiler.unpack(pair[1])
                        previous=leg
                count+=len(fill)
        if numbers: print(group, count, flush=True) if any(n in trains for n in numbers) else None
    compiler.dump(Path(out),{k:v for k,v in results.items() if v})
    print(count,"matched OSM legs",flush=True)


if __name__=="__main__":
    main()
