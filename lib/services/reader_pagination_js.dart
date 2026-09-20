/// CSS and JavaScript used by the paged EPUB reader.
/// Page navigation is button/tap driven; horizontal touch dragging is reserved for text selection.
const String kPaginationCss = '''
html { margin:0 !important; height:100% !important; overflow:hidden !important; }
body {
  margin:0 !important; padding:0 !important; width:%PAGE_WIDTH_PX%px !important;
  height:100vh !important; overflow-x:hidden !important; overflow-y:hidden !important;
  -webkit-overflow-scrolling:auto !important;
  column-width:%PAGE_WIDTH_PX%px !important; -webkit-column-width:%PAGE_WIDTH_PX%px !important;
  column-gap:0 !important; -webkit-column-gap:0 !important; column-fill:auto !important;
  overscroll-behavior-x:none !important;
}
body::-webkit-scrollbar { display:none !important; }
#__reader_content_wrap__ { box-sizing:border-box !important; box-decoration-break:clone !important; -webkit-box-decoration-break:clone !important; }
img,table,figure,svg { break-inside:avoid !important; -webkit-column-break-inside:avoid !important; max-width:100% !important; }
#__reader_content_wrap__, #__reader_content_wrap__ * {
  -webkit-user-select:none !important; user-select:none !important; -webkit-touch-callout:none !important;
}
''';

const String kReaderInitJsTemplate = r'''
(function(){
  function boot(){
    var vp=document.querySelector('meta[name="viewport"]');
    if(!vp){vp=document.createElement('meta');vp.name='viewport';document.head.insertBefore(vp,document.head.firstChild||null);}
    vp.content='width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';

    var wrap=document.getElementById('__reader_content_wrap__');
    if(!wrap){wrap=document.createElement('div');wrap.id='__reader_content_wrap__';while(document.body.firstChild)wrap.appendChild(document.body.firstChild);document.body.appendChild(wrap);}
    var style=document.getElementById('__reader_override__');
    if(!style){style=document.createElement('style');style.id='__reader_override__';document.head.appendChild(style);}
    style.textContent=%CSS%;

    var PAGE_WIDTH=%PAGE_WIDTH_PX%;
    function box(){return document.body;}
    function maxX(){return Math.max(0,box().scrollWidth-PAGE_WIDTH);}
    window.__reader=window.__reader||{};
    window.__reader.nextPage=function(){var b=box(),m=maxX();if(b.scrollLeft>=m-1)return'chapter-end';b.scrollLeft=Math.min(m,b.scrollLeft+PAGE_WIDTH);return'ok';};
    window.__reader.prevPage=function(){var b=box();if(b.scrollLeft<=1)return'chapter-start';b.scrollLeft=Math.max(0,b.scrollLeft-PAGE_WIDTH);return'ok';};
    window.__reader.goToStart=function(){box().scrollLeft=0;};
    window.__reader.goToEnd=function(){box().scrollLeft=maxX();};
    window.__reader.goToFraction=function(f){var m=maxX(),p=Math.round((f*m)/PAGE_WIDTH);box().scrollLeft=Math.max(0,Math.min(m,p*PAGE_WIDTH));};
    window.__reader.clampPosition=function(){var b=box(),m=maxX();b.scrollLeft=Math.max(0,Math.min(m,Math.round(b.scrollLeft/PAGE_WIDTH)*PAGE_WIDTH));};
    window.__reader.getFraction=function(){var m=maxX();return m<=0?0:box().scrollLeft/m;};
    window.__reader.getPageLabel=function(){return(Math.round(box().scrollLeft/PAGE_WIDTH)+1)+' / '+Math.max(1,Math.round(box().scrollWidth/PAGE_WIDTH));};

    function charOffset(root,node,offset){var r=document.createRange();r.selectNodeContents(root);try{r.setEnd(node,offset);}catch(e){return 0;}return r.toString().length;}
    function pointAt(root,target){var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT),n,c=0;while(n=w.nextNode()){var len=n.nodeValue.length;if(c+len>=target)return{node:n,offset:Math.max(0,target-c)};c+=len;}return n?{node:n,offset:n.nodeValue.length}:null;}
    function wrapRange(range,id,cls,attr,css){var root=range.commonAncestorContainer;if(root.nodeType===3)root=root.parentNode;var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT),a=[],n;while(n=w.nextNode())if(range.intersectsNode(n))a.push(n);for(var i=a.length-1;i>=0;i--){n=a[i];if(!n.parentNode||!n.nodeValue)continue;var s=n===range.startContainer?range.startOffset:0,e=n===range.endContainer?range.endOffset:n.nodeValue.length;if(s>=e)continue;var t=n;if(e<t.nodeValue.length)t=t.splitText(e);if(s>0)t=t.splitText(s);var span=document.createElement('span');span.className=cls;span.setAttribute(attr,String(id));span.style.cssText=css;t.parentNode.insertBefore(span,t);span.appendChild(t);}}
    function applyHighlight(e){var s=pointAt(wrap,e.start),t=pointAt(wrap,e.end);if(!s||!t)return;var r=document.createRange();try{r.setStart(s.node,s.offset);r.setEnd(t.node,t.offset);}catch(x){return;}wrapRange(r,e.id,'reader-highlight','data-hl-id','background-color:'+e.color+';border-radius:2px;');}
    function applyMemo(e){var s=pointAt(wrap,e.start),t=pointAt(wrap,e.end);if(!s||!t)return;var r=document.createRange();try{r.setStart(s.node,s.offset);r.setEnd(t.node,t.offset);}catch(x){return;}wrapRange(r,e.id,'reader-memo','data-memo-id','border-bottom:2px dashed rgba(255,145,0,.85);');}
    if(!window.__readerHighlightsApplied){window.__readerHighlightsApplied=true;(%HIGHLIGHTS_JSON%).forEach(applyHighlight);}
    if(!window.__readerMemosApplied){window.__readerMemosApplied=true;(%MEMOS_JSON%).forEach(applyMemo);}
    window.__reader.addHighlight=function(id,s,e,c){applyHighlight({id:id,start:s,end:e,color:c});if(window.__reader.clearCustomSelection)window.__reader.clearCustomSelection();};
    window.__reader.removeHighlight=function(id){document.querySelectorAll('.reader-highlight[data-hl-id="'+id+'"]').forEach(function(span){var p=span.parentNode;if(!p)return;while(span.firstChild)p.insertBefore(span.firstChild,span);p.removeChild(span);p.normalize();});};
    window.__reader.addMemo=function(id,s,e){applyMemo({id:id,start:s,end:e});if(window.__reader.clearCustomSelection)window.__reader.clearCustomSelection();};
    window.__reader.removeMemo=function(id){document.querySelectorAll('.reader-memo[data-memo-id="'+id+'"]').forEach(function(span){var p=span.parentNode;if(!p)return;while(span.firstChild)p.insertBefore(span.firstChild,span);p.removeChild(span);p.normalize();});};
    window.__reader.clearSelection=function(){if(window.__reader.clearCustomSelection)window.__reader.clearCustomSelection();};
    window.__reader.scrollToSelector=function(sel){var el=document.querySelector(sel);if(!el)return'not-found';var r=el.getBoundingClientRect(),b=box(),p=Math.max(0,Math.floor((r.left+b.scrollLeft)/PAGE_WIDTH));b.scrollLeft=Math.min(maxX(),p*PAGE_WIDTH);return'ok';};
    window.__reader.findAndScrollTo=function(query,occ){var w=document.createTreeWalker(wrap,NodeFilter.SHOW_TEXT),n,text='',ranges=[];while(n=w.nextNode()){var s=text.length;text+=n.nodeValue;ranges.push({node:n,start:s,end:text.length});}var q=String(query).toLowerCase(),lower=text.toLowerCase(),idx=-1,c=0,from=0;while((idx=lower.indexOf(q,from))>=0){if(c===occ)break;c++;from=idx+1;}if(idx<0)return'not-found';var target=null,local=0;for(var i=0;i<ranges.length;i++)if(idx>=ranges[i].start&&idx<ranges[i].end){target=ranges[i].node;local=idx-ranges[i].start;break;}if(!target)return'not-found';var r=document.createRange();r.setStart(target,local);r.setEnd(target,Math.min(target.nodeValue.length,local+q.length));var rect=r.getBoundingClientRect(),b=box(),p=Math.max(0,Math.floor((rect.left+b.scrollLeft)/PAGE_WIDTH));b.scrollLeft=Math.min(maxX(),p*PAGE_WIDTH);return'ok';};

    if(!window.__readerCustomSelectionBound){
      window.__readerCustomSelectionBound=true;
      var sel={startNode:null,startOffset:0,endNode:null,endOffset:0,active:false};
      var layer=null,startHandle=null,endHandle=null,rectPool=[],longTimer=null,origin=null;
      var draggingHandle=null,dragging=false,continueSelection=false,suppressClick=false,raf=0;
      function ensureLayer(){if(layer&&layer.isConnected)return layer;layer=document.createElement('div');layer.id='__reader_selection_layer__';layer.style.cssText='position:fixed;inset:0;pointer-events:none;z-index:2147483000;';document.body.appendChild(layer);return layer;}
      function handle(side){var h=document.createElement('div');h.className='__reader_sel_handle__';h.dataset.side=side;h.style.cssText='position:fixed;width:40px;height:40px;margin:0;pointer-events:auto;touch-action:none;z-index:2147483001;';h.innerHTML='<svg width="40" height="40" viewBox="0 0 40 40"><circle cx="20" cy="20" r="10" fill="#4285F4"/><circle cx="20" cy="20" r="4" fill="white" opacity=".95"/></svg>';return h;}
      function range(){if(!sel.startNode||!sel.endNode)return null;var r=document.createRange();try{r.setStart(sel.startNode,sel.startOffset);r.setEnd(sel.endNode,sel.endOffset);}catch(e){return null;}return r.collapsed?null:r;}
      function normalize(){if(!sel.startNode||!sel.endNode)return;var r=document.createRange();try{r.setStart(sel.startNode,sel.startOffset);r.setEnd(sel.endNode,sel.endOffset);}catch(e){return;}if(r.collapsed){var n=sel.startNode,o=sel.startOffset;sel.startNode=sel.endNode;sel.startOffset=sel.endOffset;sel.endNode=n;sel.endOffset=o;}}
      function render(){var r=range();if(!r){if(startHandle){startHandle.remove();startHandle=null;}if(endHandle){endHandle.remove();endHandle=null;}return;}var rs=r.getClientRects(),l=ensureLayer(),i;
        for(i=0;i<rs.length;i++){var x=rs[i],el=rectPool[i];if(!el){el=document.createElement('div');el.className='__reader_sel_rect__';el.style.pointerEvents='none';el.style.position='fixed';el.style.background='rgba(66,133,244,.30)';el.style.borderRadius='2px';l.appendChild(el);rectPool[i]=el;}el.style.display=x.width>0&&x.height>0?'block':'none';el.style.left=x.left+'px';el.style.top=x.top+'px';el.style.width=x.width+'px';el.style.height=x.height+'px';}
        for(;i<rectPool.length;i++)rectPool[i].style.display='none';
        var first=rs[0],last=rs[rs.length-1];if(!startHandle){startHandle=handle('start');l.appendChild(startHandle);bindHandle(startHandle);}if(!endHandle){endHandle=handle('end');l.appendChild(endHandle);bindHandle(endHandle);}startHandle.style.left=(first.left-20)+'px';startHandle.style.top=(first.bottom-8)+'px';endHandle.style.left=(last.right-20)+'px';endHandle.style.top=(last.bottom-8)+'px';
      }
      function scheduleRender(){if(raf)return;raf=requestAnimationFrame(function(){raf=0;render();});}
      function report(){if(!window.ReaderSelection)return;var r=range();if(!r){ReaderSelection.postMessage('none');return;}var text=r.toString();if(!text.trim()){ReaderSelection.postMessage('none');return;}var s=charOffset(wrap,r.startContainer,r.startOffset),e=charOffset(wrap,r.endContainer,r.endOffset);if(s>e){var t=s;s=e;e=t;}var rect=r.getBoundingClientRect(),endRange=document.createRange(),endRect=rect;try{endRange.setStart(r.endContainer,r.endOffset);endRange.collapse(true);endRect=endRange.getBoundingClientRect();}catch(x){}var pageEnd=box().scrollLeft+PAGE_WIDTH;var atPageEnd=(endRect.right+box().scrollLeft)>=pageEnd-18;ReaderSelection.postMessage(JSON.stringify({text:text,start:s,end:e,left:rect.left,top:rect.top,width:rect.width,height:rect.height,atPageEnd:atPageEnd}));}
      function clear(){sel.active=false;dragging=false;draggingHandle=null;sel.startNode=sel.endNode=null;for(var i=0;i<rectPool.length;i++)rectPool[i].style.display='none';if(startHandle){startHandle.remove();startHandle=null;}if(endHandle){endHandle.remove();endHandle=null;}if(window.ReaderSelection)ReaderSelection.postMessage('none');}
      window.__reader.clearCustomSelection=clear;window.__reader.continueSelection=function(){if(!sel.active)return'no-selection';var b=box(),m=maxX();if(b.scrollLeft>=m-1)return'chapter-end';b.scrollLeft=Math.min(m,b.scrollLeft+PAGE_WIDTH);continueSelection=true;return'ok';};
      function caret(x,y){var r=null;try{if(document.caretRangeFromPoint)r=document.caretRangeFromPoint(x,y);else if(document.caretPositionFromPoint){var p=document.caretPositionFromPoint(x,y);if(p)r={startContainer:p.offsetNode,startOffset:p.offset};}}catch(e){}if(r&&r.startContainer&&r.startContainer.nodeType===3)return{node:r.startContainer,offset:r.startOffset};return null;}
      function word(node,offset){var text=node.nodeValue||'';if(window.Intl&&Intl.Segmenter){try{var seg=new Intl.Segmenter(undefined,{granularity:'word'}),it=seg.segment(text)[Symbol.iterator](),v;while(!(v=it.next()).done){var s=v.value;if(offset>=s.index&&offset<=s.index+s.segment.length&&s.segment.trim())return{start:s.index,end:s.index+s.segment.length};}}catch(e){}}var a=offset,b=offset;while(a>0&&!/\s/.test(text[a-1]))a--;while(b<text.length&&!/\s/.test(text[b]))b++;if(a===b)b=Math.min(text.length,offset+1);return{start:a,end:b};}
      function setEnd(c){if(!c)return;sel.endNode=c.node;sel.endOffset=c.offset;normalize();scheduleRender();}
      function bindHandle(h){h.addEventListener('touchstart',function(e){e.preventDefault();e.stopPropagation();draggingHandle=h.dataset.side;dragging=true;},{passive:false});h.addEventListener('touchmove',function(e){if(!draggingHandle)return;e.preventDefault();e.stopPropagation();var t=e.touches[0],c=caret(t.clientX,t.clientY);if(c){if(draggingHandle==='start'){sel.startNode=c.node;sel.startOffset=c.offset;}else{sel.endNode=c.node;sel.endOffset=c.offset;}normalize();scheduleRender();}},{passive:false});h.addEventListener('touchend',function(e){e.preventDefault();e.stopPropagation();dragging=false;draggingHandle=null;report();},{passive:false});}

      document.body.addEventListener('touchstart',function(e){if(e.touches.length!==1||dragging)return;if(sel.active&&continueSelection){continueSelection=false;dragging=true;var ct=e.touches[0];origin={x:ct.clientX,y:ct.clientY};return;}if(sel.active)return;var target=e.target;if(target.closest&&target.closest('.reader-memo,.reader-highlight,a,.__reader_sel_handle__'))return;var t=e.touches[0];origin={x:t.clientX,y:t.clientY};if(longTimer)clearTimeout(longTimer);longTimer=setTimeout(function(){longTimer=null;if(!origin)return;var c=caret(origin.x,origin.y);if(!c)return;var w=word(c.node,c.offset);sel.startNode=c.node;sel.startOffset=w.start;sel.endNode=c.node;sel.endOffset=w.end;sel.active=true;dragging=true;suppressClick=true;render();report();if(navigator.vibrate)navigator.vibrate(10);},450);},{passive:true});
      document.body.addEventListener('touchmove',function(e){if(!dragging||!sel.active){if(!longTimer||!origin)return;var t0=e.touches[0];if(Math.abs(t0.clientX-origin.x)>8||Math.abs(t0.clientY-origin.y)>8){clearTimeout(longTimer);longTimer=null;origin=null;}return;}e.preventDefault();e.stopPropagation();var t=e.touches[0];setEnd(caret(t.clientX,t.clientY));},{passive:false});
      document.body.addEventListener('touchend',function(){if(longTimer){clearTimeout(longTimer);longTimer=null;}origin=null;if(dragging){dragging=false;draggingHandle=null;report();}},{passive:true});
      document.body.addEventListener('touchcancel',function(){if(longTimer){clearTimeout(longTimer);longTimer=null;}origin=null;if(dragging){dragging=false;draggingHandle=null;report();}},{passive:true});
      document.addEventListener('click',function(e){if(suppressClick){suppressClick=false;e.preventDefault();e.stopImmediatePropagation();return;}if(sel.active&&!(e.target.closest&&e.target.closest('#__reader_selection_layer__'))){clear();e.preventDefault();e.stopImmediatePropagation();}},true);
    }

    if(!window.__readerTapBound){window.__readerTapBound=true;document.addEventListener('click',function(e){var memo=e.target.closest&&e.target.closest('.reader-memo');if(memo){if(window.ReaderMemoTap)ReaderMemoTap.postMessage(memo.getAttribute('data-memo-id'));return;}var hl=e.target.closest&&e.target.closest('.reader-highlight');if(hl){if(window.ReaderHighlightTap)ReaderHighlightTap.postMessage(hl.getAttribute('data-hl-id'));return;}if(e.target.closest&&e.target.closest('a'))return;var x=e.clientX;ReaderTap.postMessage(x<PAGE_WIDTH*.3?'left':x>PAGE_WIDTH*.7?'right':'center');});}
    if(!window.__readerSnapBound){window.__readerSnapBound=true;var touching=false,timer=null;function snap(){if(touching||dragging)return;if(timer)clearTimeout(timer);timer=setTimeout(function(){if(touching||dragging)return;var b=box(),m=maxX(),to=Math.max(0,Math.min(m,Math.round(b.scrollLeft/PAGE_WIDTH)*PAGE_WIDTH));if(Math.abs(b.scrollLeft-to)>1)b.scrollTo({left:to,behavior:'smooth'});if(window.ReaderTap)ReaderTap.postMessage('settled');},180);}document.body.addEventListener('touchstart',function(){touching=true;if(timer)clearTimeout(timer);},{passive:true});document.body.addEventListener('touchend',function(){touching=false;snap();},{passive:true});document.body.addEventListener('touchcancel',function(){touching=false;snap();},{passive:true});document.body.addEventListener('scroll',snap,{passive:true});}
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
})();
''';