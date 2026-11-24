let nativeIndex;
function nativeStation(name, archive) {
  if (archive) nativeIndex=RailLibrary.index(JSON.parse(archive));
  StationPanel.mount(document.getElementById("board"),name,{library:nativeIndex});
}
