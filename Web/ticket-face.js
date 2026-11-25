// Commemorative railway ticket layouts. The miniature uses the selected journey.
function drawTicketFace(ctx, style, palette, journey) {
  const voucher=style==="voucher", paper=style==="paper";
  const song='"Songti SC","STSong","SimSun",serif', hei='"Heiti SC","Microsoft YaHei",sans-serif';
  function text(value,x,y,size,{face=song,align="left",colour=palette.ink,bold=false,max=600}={}) {
    ctx.textAlign=align; ctx.font=`${bold ? "bold " : ""}${size}px ${face}`; ctx.fillStyle=colour;
    ctx.fillText(value,x,y,max);
  }
  const from=$("postcardFrom").value.trim(),to=$("postcardTo").value.trim(),train=$("postcardTrain").value.trim();
  const [year,month,day]=$("postcardDate").value.split("-");
  ctx.save(); ctx.fillStyle=palette.paper;ctx.fillRect(0,0,640,360);
  ctx.lineWidth=.55;ctx.strokeStyle=palette.accent+"23";
  for(let row=-1;row<30;row++) {
    ctx.beginPath();
    for(let x=0;x<=640;x+=4) {
      const y=row*13+3*Math.sin(x*.085+row*.57)+1.2*Math.cos(x*.19-row);
      if(x)ctx.lineTo(x,y);else ctx.moveTo(x,y);
    }
    ctx.stroke();
  }
  text("铁 道 漫 游",28,36,18,{bold:true,colour:palette.accent});
  text(voucher ? "铁路电子客票　报销凭证" : "铁 路 客 票",320,44,voucher?22:27,{align:"center",bold:true,max:354});
  text("纪念票样",610,34,16,{align:"right",colour:palette.accent});
  const station=n=>n ? (n.endsWith("站") ? n : n+"站") : "—";
  text(station(from),30,111,43,{face:paper?song:hei,bold:true,max:205});
  text(station(to),610,111,43,{face:paper?song:hei,bold:true,max:205,align:"right"});
  text(train||"—",320,93,27,{face:'"Menlo","Consolas",monospace',align:"center",bold:true,max:113});
  ctx.strokeStyle=palette.ink;ctx.lineWidth=1.5;ctx.beginPath();ctx.moveTo(267,108);ctx.lineTo(373,108);ctx.lineTo(363,101);ctx.stroke();
  text(year && day ? `${year}年${month}月${day}日` : "乘车日期　—",31,161,24,{bold:true});
  text(`${formatClock(journey?.stops[0]?.departure)} 开`,290,161,24,{bold:true});
  text("车厢 / 席位　—",610,159,18,{align:"right"});
  if(voucher) {
    ctx.strokeStyle=palette.accent;ctx.lineWidth=.7;ctx.strokeRect(29,181,582,81);
    text("票价　¥ —",43,212,19);text("旅客姓名　—",238,212,19);text("证件号　—",423,212,19);
    text("行程区间",43,246,17);text(`${from}　至　${to}`,151,246,19,{max:442});
  } else {
    text("票价　¥ —",32,207,24,{bold:true});text("客票",246,206,21);
    text(paper?"纸质车票":"磁介质车票",610,206,18,{align:"right"});
    text($("postcardCaption").value,32,249,19,{max:520});
  }
  ctx.strokeStyle=palette.accent+"99";ctx.lineWidth=.7;ctx.beginPath();ctx.moveTo(29,276);ctx.lineTo(611,276);ctx.stroke();
  text("乘车径路",32,308,16);CardMap.draw(ctx,journey,[107,279,190,54],palette.accent,palette.paper,1.8);
  text("旅行留念　不可乘车或报销",610,305,17,{align:"right",bold:true});
  if(voucher) text($("postcardCaption").value,610,328,14,{align:"right",max:297});
  text("RAILWAY ATLAS",29,348,11,{face:"monospace",colour:palette.accent});
  text(cardMapCredit(),610,347,10,{face:"sans-serif",align:"right",max:432});
  ctx.restore();
}
