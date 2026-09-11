/// CSS and JavaScript used by the paged EPUB reader.
///
/// Text selection is intentionally custom rather than relying on Android WebView's
/// native selection UI. After a long-press creates a word selection, the same finger
/// can immediately keep moving to extend the selection. The selection gesture owns
/// the touch stream until it ends, so the normal page swipe cannot steal it.
const String kPaginationCss = '''
html {
  margin: 0 !important;
  height: 100% !important;
  overflow: hidden !important;
}
body {
  margin: 0 !important;
  padding: 0 !important;
  width: %PAGE_WIDTH_PX%px !important;
  height: 100vh !important;
  overflow-x: scroll !important;
  overflow-y: hidden !important;
  -webkit-overflow-scrolling: touch !important;
  column-width: %PAGE_WIDTH_PX%px !important;
  -webkit-column-width: %PAGE_WIDTH_PX%px !important;
  column-gap: 0px !important;
  -webkit-column-gap: 0px !important;
  column-fill: auto !important;
}
body::-webkit-scrollbar { display: none !important; }
#__reader_content_wrap__ {
  box-decoration-break: clone !important;
  -webkit-box-decoration-break: clone !important;
  box-sizing: border-box !important;
}
img, table, figure, svg {
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
  max-width: 100% !important;
}
#__reader_content_wrap__, #__reader_content_wrap__ * {
  -webkit-user-select: none !important;
  user-select: none !important;
  -webkit-touch-callout: none !important;
}
''';

const String kReaderInitJsTemplate = r'''
(function() {
  function __readerBoot() {
    var vp = document.querySelector('meta[name="viewport"]');
    if (!vp) {
      vp = document.createElement('meta');
      vp.setAttribute('name', 'viewport');
      document.head.insertBefore(vp, document.head.firstChild || null);
    }
    vp.setAttribute('content', 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no');

    var wrapId = "__reader_content_wrap__";
    var wrap = document.getElementById(wrapId);
    if (!wrap) {
      wrap = document.createElement("div");
      wrap.id = wrapId;
      while (document.body.firstChild) wrap.appendChild(document.body.firstChild);
      document.body.appendChild(wrap);
    }

    var styleId = "__reader_override__";
    var styleEl = document.getElementById(styleId);
    if (!styleEl) {
      styleEl = document.createElement("style");
      styleEl.id = styleId;
      document.head.appendChild(styleEl);
    }
    styleEl.textContent = %CSS%;

    var PAGE_WIDTH = %PAGE_WIDTH_PX%;
    function scrollBox() { return document.body; }
    function maxScrollLeft() { return Math.max(0, scrollBox().scrollWidth - PAGE_WIDTH); }

    window.__reader = window.__reader || {};
    window.__reader.nextPage = function() {
      var box = scrollBox(), max = maxScrollLeft();
      if (box.scrollLeft >= max - 1) return "chapter-end";
      box.scrollLeft = Math.min(max, box.scrollLeft + PAGE_WIDTH);
      return "ok";
    };
    window.__reader.prevPage = function() {
      var box = scrollBox();
      if (box.scrollLeft <= 1) return "chapter-start";
      box.scrollLeft = Math.max(0, box.scrollLeft - PAGE_WIDTH);
      return "ok";
    };
    window.__reader.goToStart = function() { scrollBox().scrollLeft = 0; };
    window.__reader.goToEnd = function() { scrollBox().scrollLeft = maxScrollLeft(); };
    window.__reader.goToFraction = function(f) {
      var max = maxScrollLeft();
      var page = Math.round((f * max) / PAGE_WIDTH);
      scrollBox().scrollLeft = Math.max(0, Math.min(max, page * PAGE_WIDTH));
    };
    window.__reader.clampPosition = function() {
      var box = scrollBox(), max = maxScrollLeft();
      var snapped = Math.round(box.scrollLeft / PAGE_WIDTH) * PAGE_WIDTH;
      box.scrollLeft = Math.max(0, Math.min(max, snapped));
    };
    window.__reader.getFraction = function() {
      var max = maxScrollLeft();
      return max <= 0 ? 0 : scrollBox().scrollLeft / max;
    };
    window.__reader.getPageLabel = function() {
      var current = Math.round(scrollBox().scrollLeft / PAGE_WIDTH) + 1;
      var total = Math.max(1, Math.round(scrollBox().scrollWidth / PAGE_WIDTH));
      return current + " / " + total;
    };

    function charOffsetOfBoundary(root, node, offset) {
      var r = document.createRange();
      r.selectNodeContents(root);
      try { r.setEnd(node, offset); } catch (e) { return 0; }
      return r.toString().length;
    }

    function pointForCharOffset(root, target) {
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var count = 0, node;
      while ((node = walker.nextNode())) {
        var len = node.nodeValue.length;
        if (count + len >= target) return { node: node, offset: Math.max(0, target - count) };
        count += len;
      }
      if (node) return { node: node, offset: node.nodeValue.length };
      return null;
    }

    function wrapRangeWithSpan(range, id, className, attrName, styleCss) {
      var rootEl = range.commonAncestorContainer;
      if (rootEl.nodeType === 3) rootEl = rootEl.parentNode;
      var walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT, null);
      var targets = [], node;
      while ((node = walker.nextNode())) {
        if (range.intersectsNode(node)) targets.push(node);
      }
      for (var i = targets.length - 1; i >= 0; i--) {
        var n = targets[i];
        if (!n.parentNode || !n.nodeValue) continue;
        var startLocal = n === range.startContainer ? range.startOffset : 0;
        var endLocal = n === range.endContainer ? range.endOffset : n.nodeValue.length;
        if (startLocal >= endLocal) continue;
        var target = n;
        if (endLocal < target.nodeValue.length) target.splitText(endLocal);
        if (startLocal > 0) target = target.splitText(startLocal);
        var span = document.createElement("span");
        span.className = className;
        span.setAttribute(attrName, String(id));
        span.style.cssText = styleCss;
        target.parentNode.insertBefore(span, target);
        span.appendChild(target);
      }
    }

    function applyHighlightEntry(entry) {
      var start = pointForCharOffset(wrap, entry.start), end = pointForCharOffset(wrap, entry.end);
      if (!start || !end) return;
      var range = document.createRange();
      try { range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset); } catch (e) { return; }
      wrapRangeWithSpan(range, entry.id, "reader-highlight", "data-hl-id", "background-color:" + entry.color + ";border-radius:2px;");
    }

    function applyMemoEntry(entry) {
      var start = pointForCharOffset(wrap, entry.start), end = pointForCharOffset(wrap, entry.end);
      if (!start || !end) return;
      var range = document.createRange();
      try { range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset); } catch (e) { return; }
      wrapRangeWithSpan(range, entry.id, "reader-memo", "data-memo-id", "border-bottom:2px dashed rgba(255,145,0,0.85);");
    }

    if (!window.__readerHighlightsApplied) {
      window.__readerHighlightsApplied = true;
      var HIGHLIGHTS = %HIGHLIGHTS_JSON%;
      HIGHLIGHTS.forEach(applyHighlightEntry);
    }
    if (!window.__readerMemosApplied) {
      window.__readerMemosApplied = true;
      var MEMOS = %MEMOS_JSON%;
      MEMOS.forEach(applyMemoEntry);
    }

    window.__reader.addHighlight = function(id, start, end, colorCss) {
      applyHighlightEntry({ id: id, start: start, end: end, color: colorCss });
      if (window.__reader.clearCustomSelection) window.__reader.clearCustomSelection();
    };
    window.__reader.removeHighlight = function(id) {
      document.querySelectorAll('.reader-highlight[data-hl-id="' + id + '"]').forEach(function(span) {
        var parent = span.parentNode;
        if (!parent) return;
        while (span.firstChild) parent.insertBefore(span.firstChild, span);
        parent.removeChild(span);
        parent.normalize();
      });
    };
    window.__reader.addMemo = function(id, start, end) {
      applyMemoEntry({ id: id, start: start, end: end });
      if (window.__reader.clearCustomSelection) window.__reader.clearCustomSelection();
    };
    window.__reader.removeMemo = function(id) {
      document.querySelectorAll('.reader-memo[data-memo-id="' + id + '"]').forEach(function(span) {
        var parent = span.parentNode;
        if (!parent) return;
        while (span.firstChild) parent.insertBefore(span.firstChild, span);
        parent.removeChild(span);
        parent.normalize();
      });
    };
    window.__reader.clearSelection = function() {
      if (window.__reader.clearCustomSelection) window.__reader.clearCustomSelection();
    };
    window.__reader.scrollToSelector = function(selector) {
      var el = document.querySelector(selector);
      if (!el) return "not-found";
      var rect = el.getBoundingClientRect(), box = scrollBox();
      var pageIndex = Math.max(0, Math.floor((rect.left + box.scrollLeft) / PAGE_WIDTH));
      box.scrollLeft = Math.min(maxScrollLeft(), pageIndex * PAGE_WIDTH);
      return "ok";
    };

    window.__reader.findAndScrollTo = function(query, occurrenceIndex) {
      var walker = document.createTreeWalker(wrap, NodeFilter.SHOW_TEXT, null);
      var node, fullText = "", ranges = [];
      while ((node = walker.nextNode())) {
        var s = fullText.length;
        fullText += node.nodeValue;
        ranges.push({ node: node, start: s, end: fullText.length });
      }
      var text = fullText.toLowerCase(), q = String(query).toLowerCase();
      var idx = -1, count = 0, from = 0;
      while (true) {
        idx = text.indexOf(q, from);
        if (idx < 0) break;
        if (count === occurrenceIndex) break;
        count++; from = idx + 1;
      }
      if (idx < 0) return "not-found";
      var target = null, local = 0;
      for (var i = 0; i < ranges.length; i++) {
        if (idx >= ranges[i].start && idx < ranges[i].end) {
          target = ranges[i].node; local = idx - ranges[i].start; break;
        }
      }
      if (!target) return "not-found";
      var range = document.createRange();
      range.setStart(target, local);
      range.setEnd(target, Math.min(target.nodeValue.length, local + q.length));
      var rect = range.getBoundingClientRect(), box = scrollBox();
      var pageIndex = Math.max(0, Math.floor((rect.left + box.scrollLeft) / PAGE_WIDTH));
      box.scrollLeft = Math.min(maxScrollLeft(), pageIndex * PAGE_WIDTH);
      return "ok";
    };

    // ---- Custom text selection ----
    // Long-press creates a word selection. Crucially, once the timer fires, the same
    // finger is promoted to an "end-handle drag". We therefore do not wait for a
    // second touch on the circular handle. This is the behavior of a native reader
    // selection gesture that the old implementation was missing.
    if (!window.__readerCustomSelectionBound) {
      window.__readerCustomSelectionBound = true;
      var csel = { startNode: null, startOffset: 0, endNode: null, endOffset: 0, active: false };
      var overlayLayer = null, startHandle = null, endHandle = null;
      var longPressTimer = null, longPressOrigin = null;
      var draggingHandle = null, selectionDrag = false, autoPageLock = false;
      var suppressNextClick = false;

      function ensureOverlayLayer() {
        if (overlayLayer && overlayLayer.isConnected) return overlayLayer;
        overlayLayer = document.createElement("div");
        overlayLayer.id = "__reader_selection_layer__";
        overlayLayer.style.cssText = "position:fixed;left:0;top:0;right:0;bottom:0;pointer-events:none;z-index:2147483000;";
        document.body.appendChild(overlayLayer);
        return overlayLayer;
      }
      function makeHandle(side) {
        var h = document.createElement("div");
        h.className = "__reader_sel_handle__";
        h.dataset.side = side;
        h.style.cssText = "position:fixed;width:28px;height:28px;pointer-events:auto;z-index:2147483001;touch-action:none;";
        h.innerHTML = '<svg width="28" height="28" viewBox="0 0 28 28"><circle cx="14" cy="14" r="8" fill="#4285F4"/></svg>';
        return h;
      }
      function currentRange() {
        if (!csel.startNode || !csel.endNode) return null;
        var r = document.createRange();
        try { r.setStart(csel.startNode, csel.startOffset); r.setEnd(csel.endNode, csel.endOffset); } catch (e) { return null; }
        return r.collapsed ? null : r;
      }
      function normalizeOrder() {
        if (!csel.startNode || !csel.endNode) return;
        var r = document.createRange();
        try { r.setStart(csel.startNode, csel.startOffset); r.setEnd(csel.endNode, csel.endOffset); } catch (e) { return; }
        if (r.collapsed) {
          var n = csel.startNode, o = csel.startOffset;
          csel.startNode = csel.endNode; csel.startOffset = csel.endOffset;
          csel.endNode = n; csel.endOffset = o;
        }
      }
      function renderOverlay() {
        var range = currentRange(), layer = ensureOverlayLayer();
        layer.querySelectorAll(".__reader_sel_rect__").forEach(function(x) { x.remove(); });
        if (!range) {
          if (startHandle) { startHandle.remove(); startHandle = null; }
          if (endHandle) { endHandle.remove(); endHandle = null; }
          return;
        }
        var rects = range.getClientRects();
        for (var i = 0; i < rects.length; i++) {
          var r = rects[i];
          if (r.width <= 0 || r.height <= 0) continue;
          var box = document.createElement("div");
          box.className = "__reader_sel_rect__";
          box.style.cssText = "position:fixed;left:" + r.left + "px;top:" + r.top + "px;width:" + r.width + "px;height:" + r.height + "px;background:rgba(66,133,244,0.35);pointer-events:none;";
          layer.appendChild(box);
        }
        if (rects.length) {
          var first = rects[0], last = rects[rects.length - 1];
          if (!startHandle) { startHandle = makeHandle("start"); layer.appendChild(startHandle); bindHandleEvents(startHandle); }
          if (!endHandle) { endHandle = makeHandle("end"); layer.appendChild(endHandle); }
          startHandle.style.left = (first.left - 14) + "px";
          startHandle.style.top = (first.bottom - 6) + "px";
          endHandle.style.left = (last.right - 14) + "px";
          endHandle.style.top = (last.bottom - 6) + "px";
        }
      }
      function reportSelection() {
        if (!window.ReaderSelection) return;
        var range = currentRange();
        if (!range) { ReaderSelection.postMessage("none"); return; }
        var text = range.toString();
        if (!text || !text.trim()) { ReaderSelection.postMessage("none"); return; }
        var start = charOffsetOfBoundary(wrap, range.startContainer, range.startOffset);
        var end = charOffsetOfBoundary(wrap, range.endContainer, range.endOffset);
        if (start > end) { var t = start; start = end; end = t; }
        var rect = range.getBoundingClientRect();
        ReaderSelection.postMessage(JSON.stringify({text:text,start:start,end:end,left:rect.left,top:rect.top,width:rect.width,height:rect.height}));
      }
      function clearCustomSelection() {
        csel.active = false; selectionDrag = false; draggingHandle = null; autoPageLock = false;
        csel.startNode = csel.endNode = null;
        if (overlayLayer) overlayLayer.querySelectorAll(".__reader_sel_rect__").forEach(function(x) { x.remove(); });
        if (startHandle) { startHandle.remove(); startHandle = null; }
        if (endHandle) { endHandle.remove(); endHandle = null; }
        if (window.ReaderSelection) ReaderSelection.postMessage("none");
      }
      window.__reader.clearCustomSelection = clearCustomSelection;

      function caretAt(x, y) {
        var fn = document.caretRangeFromPoint || document.caretPositionFromPoint;
        if (!fn) return null;
        try {
          var r = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : document.caretPositionFromPoint(x, y);
          if (r && r.startContainer && r.startContainer.nodeType === 3) return {node:r.startContainer,offset:r.startOffset};
          if (r && r.offsetNode && r.offsetNode.nodeType === 3) return {node:r.offsetNode,offset:r.offset};
        } catch (e) {}
        return null;
      }
      function wordBoundsAround(node, offset) {
        var text = node.nodeValue || "";
        if (window.Intl && Intl.Segmenter) {
          try {
            var seg = new Intl.Segmenter(undefined, {granularity:"word"});
            var it = seg.segment(text)[Symbol.iterator](), item;
            while (!(item = it.next()).done) {
              var s = item.value;
              if (offset >= s.index && offset <= s.index + s.segment.length && s.segment.trim().length) return {start:s.index,end:s.index+s.segment.length};
            }
          } catch (e) {}
        }
        var boundary = function(ch) { return /\s/.test(ch); };
        var start = offset, end = offset;
        while (start > 0 && !boundary(text[start-1])) start--;
        while (end < text.length && !boundary(text[end])) end++;
        if (start === end) end = Math.min(text.length, offset + 1);
        return {start:start,end:end};
      }
      function setEndAtCaret(caret) {
        if (!caret) return;
        csel.endNode = caret.node; csel.endOffset = caret.offset;
        normalizeOrder(); renderOverlay(); reportSelection();
      }
      function bindHandleEvents(handle) {
        handle.addEventListener("touchstart", function(e) {
          e.preventDefault(); e.stopPropagation(); draggingHandle = handle.dataset.side;
        }, {passive:false});
        handle.addEventListener("touchmove", function(e) {
          if (!draggingHandle) return;
          e.preventDefault(); e.stopPropagation();
          var t = e.touches[0];
          var caret = caretAt(t.clientX, t.clientY);
          if (caret) {
            if (draggingHandle === "start") { csel.startNode = caret.node; csel.startOffset = caret.offset; }
            else { csel.endNode = caret.node; csel.endOffset = caret.offset; }
            normalizeOrder(); renderOverlay();
          }
        }, {passive:false});
        handle.addEventListener("touchend", function(e) {
          e.preventDefault(); e.stopPropagation(); draggingHandle = null; reportSelection();
        }, {passive:false});
      }

      // The important path: after long-press, touchmove becomes the end-handle drag.
      // preventDefault() is only used while selection is active, so ordinary page swiping
      // remains unchanged before a selection is created.
      document.body.addEventListener("touchstart", function(e) {
        if (draggingHandle || selectionDrag) return;
        if (e.touches.length !== 1) return;
        var target = e.target;
        if (target.closest && target.closest(".reader-memo, .reader-highlight, a, .__reader_sel_handle__")) {
          longPressOrigin = null; return;
        }
        var t = e.touches[0];
        longPressOrigin = {x:t.clientX,y:t.clientY};
        if (longPressTimer) clearTimeout(longPressTimer);
        longPressTimer = setTimeout(function() {
          longPressTimer = null;
          if (!longPressOrigin) return;
          var caret = caretAt(longPressOrigin.x, longPressOrigin.y);
          if (!caret) return;
          var bounds = wordBoundsAround(caret.node, caret.offset);
          csel.startNode = caret.node; csel.startOffset = bounds.start;
          csel.endNode = caret.node; csel.endOffset = bounds.end;
          csel.active = true;
          selectionDrag = true;
          suppressNextClick = true;
          renderOverlay(); reportSelection();
          if (navigator.vibrate) navigator.vibrate(10);
        }, 380);
      }, {passive:true});

      document.body.addEventListener("touchmove", function(e) {
        if (!selectionDrag || !csel.active) {
          if (!longPressTimer || !longPressOrigin) return;
          var t0 = e.touches[0];
          if (Math.abs(t0.clientX-longPressOrigin.x) > 10 || Math.abs(t0.clientY-longPressOrigin.y) > 10) {
            clearTimeout(longPressTimer); longPressTimer = null;
          }
          return;
        }
        e.preventDefault();
        e.stopPropagation();
        var t = e.touches[0], box = scrollBox(), edge = 26, max = maxScrollLeft();
        if (t.clientX > PAGE_WIDTH-edge && box.scrollLeft < max-1) {
          if (!autoPageLock) {
            autoPageLock = true;
            box.scrollLeft = Math.min(max, box.scrollLeft + PAGE_WIDTH);
            setTimeout(function() {
              if (!selectionDrag) return;
              var c = caretAt(PAGE_WIDTH-edge-2, t.clientY);
              if (c) setEndAtCaret(c);
            }, 50);
          }
          return;
        }
        if (t.clientX < edge && box.scrollLeft > 1) {
          if (!autoPageLock) {
            autoPageLock = true;
            box.scrollLeft = Math.max(0, box.scrollLeft - PAGE_WIDTH);
            setTimeout(function() {
              if (!selectionDrag) return;
              var c = caretAt(edge+2, t.clientY);
              if (c) setEndAtCaret(c);
            }, 50);
          }
          return;
        }
        autoPageLock = false;
        setEndAtCaret(caretAt(t.clientX, t.clientY));
      }, {passive:false});

      document.body.addEventListener("touchend", function() {
        if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; }
        longPressOrigin = null;
        if (selectionDrag) { selectionDrag = false; reportSelection(); }
      }, {passive:true});
      document.body.addEventListener("touchcancel", function() {
        if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; }
        longPressOrigin = null;
        if (selectionDrag) { selectionDrag = false; reportSelection(); }
      }, {passive:true});

      document.addEventListener("click", function(e) {
        if (suppressNextClick) {
          suppressNextClick = false;
          e.preventDefault(); e.stopImmediatePropagation(); return;
        }
        if (csel.active && !(e.target.closest && e.target.closest("#__reader_selection_layer__"))) {
          clearCustomSelection(); e.preventDefault(); e.stopImmediatePropagation();
        }
      }, true);
    }

    if (!window.__readerTapBound) {
      window.__readerTapBound = true;
      document.addEventListener("click", function(e) {
        var memo = e.target.closest && e.target.closest(".reader-memo");
        if (memo) { if (window.ReaderMemoTap) ReaderMemoTap.postMessage(memo.getAttribute("data-memo-id")); return; }
        var hl = e.target.closest && e.target.closest(".reader-highlight");
        if (hl) { if (window.ReaderHighlightTap) ReaderHighlightTap.postMessage(hl.getAttribute("data-hl-id")); return; }
        if (e.target.closest && e.target.closest("a")) return;
        var x = e.clientX;
        var zone = x < PAGE_WIDTH*0.3 ? "left" : (x > PAGE_WIDTH*0.7 ? "right" : "center");
        if (window.ReaderTap) ReaderTap.postMessage(zone);
      });
    }

    if (!window.__readerSnapBound) {
      window.__readerSnapBound = true;
      var isTouching = false, snapTimer = null;
      function scheduleSnap() {
        if (snapTimer) clearTimeout(snapTimer);
        snapTimer = setTimeout(function() {
          if (isTouching) return;
          var box = scrollBox(), max = maxScrollLeft();
          var target = Math.max(0, Math.min(max, Math.round(box.scrollLeft/PAGE_WIDTH)*PAGE_WIDTH));
          if (Math.abs(box.scrollLeft-target)>1) box.scrollTo({left:target,behavior:"smooth"});
          if (window.ReaderTap) ReaderTap.postMessage("settled");
        }, 150);
      }
      document.body.addEventListener("touchstart", function() { isTouching=true; if(snapTimer) clearTimeout(snapTimer); }, {passive:true});
      document.body.addEventListener("touchend", function() { isTouching=false; scheduleSnap(); }, {passive:true});
      document.body.addEventListener("touchcancel", function() { isTouching=false; scheduleSnap(); }, {passive:true});
      document.body.addEventListener("scroll", scheduleSnap, {passive:true});
    }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", __readerBoot);
  else __readerBoot();
})();
''';