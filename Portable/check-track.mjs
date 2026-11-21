import assert from "node:assert/strict";
import {matchCache} from "../Web/track-match.mjs";

const first = [115.7, 37.3], last = [115.75, 37.3];
const stops = ["甲", "乙"];
const plan = {
  nodes: stops.map((station,i) => ({station, kilometre:i*4.42})),
  edges: [{lineName:"示例线"}], stopIndices:[0,1]
};
function feature(type, name, coordinates) {
  return {type, properties:{name, feature:"rail"}, toGeoJSON:()=>({geometry:{type:type===1?"Point":"LineString", coordinates}})};
}
function layer(features) {
  return {length:features.length, feature:i=>features[i]};
}
function fixture(ways) {
  return {
    selectValues:()=>[10],
    exec({sql,callback}) {
      if (sql.includes("standard_railway_text_stations")) {
        callback([10,0,0,{layers:{standard_railway_text_stations:layer([
          feature(1,"甲",first), feature(1,"乙",last)
        ])}}]);
      } else {
        callback([0,0,{layers:{railway_line_high:layer(ways)}}]);
      }
    }
  };
}
const track = (a,b,name="示例线") => feature(2,name,[a,b]);
const check = (ways,value=plan,names=stops) => matchCache(fixture(ways),tile=>tile,value,names);
const [route] = check([track(first,last)]);
assert.ok(route.length>50);
assert.deepEqual(route[0],first);
assert.deepEqual(route.at(-1),last);
assert.throws(()=>check([track(first,[115.71,37.3]),track([115.74,37.3],last)]),/连续/);
assert.throws(()=>check([track(first,last)],{...plan,nodes:[plan.nodes[0],{station:"乙",kilometre:18}]}),/里程不符/);
assert.throws(()=>check([track(first,last)],{nodes:[plan.nodes[0],{station:"换线所",kilometre:2},plan.nodes[1]],
  edges:[plan.edges[0],{lineName:"另一线"}],stopIndices:[0,2]}),/换线所/);
assert.throws(()=>check([track(first,last,"另一线")]),/命名轨道/);
assert.throws(()=>check([track(first,last)],plan,["丙","乙"]),/所选车次/);
console.log("轨道回归通过：匹配、断轨、里程、换线点、线路名和经停站。");
