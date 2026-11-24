let nativeIndex;
function nativeStation(name, archive) {
  if (archive) nativeIndex=RailLibrary.index(JSON.parse(archive));
  const coords=new Map(atlasRailDirectory.names.map((n,i)=>[n,atlasRailDirectory.coordinates[i]]));
  const send=(body)=>window.webkit?.messageHandlers?.stationAction?.postMessage(body);
  StationPanel.mount(document.getElementById("board"),name,{library:nativeIndex,coordinate:n=>coords.get(n),
    locate:rows=>send({mode:"line",names:rows.map(r=>r[0])}),
    trainAction:(data,origin,mode,station)=>send({mode,train:data.number,date:origin,station,
      stops:data.stops.map(([station,arrival,departure])=>({station,arrival,departure}))})});
}
