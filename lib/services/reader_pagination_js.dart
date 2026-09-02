/// 챕터를 화면 너비만큼의 "페이지"로 나누는 CSS.
///
/// 핵심 설계: 컬럼(페이지) 폭을 `100vw` 같은 상대 단위로 WebView가 스스로 계산하게
/// 두지 않는다. 대신 Flutter가 이미 정확히 알고 있는 실제 렌더링 폭(위젯 실측 크기,
/// %PAGE_WIDTH_PX%로 주입됨)을 리터럴 px 값으로 그대로 박아 넣는다.
///
/// 컬럼 속성은 반드시 body 하나에만, padding 없이 순수 페이지 폭으로만 건다.
/// 여백(상하좌우 padding)이나 글자 확대(zoom)는 body가 아니라 그 안의 별도
/// wrapper(#__reader_content_wrap__)에 적용해서, 컬럼 폭 계산과 절대 간섭하지 않게 한다.
/// wrapper에는 box-decoration-break: clone을 줘서, padding(여백)이 첫/마지막 페이지에만
/// 나오지 않고 모든 페이지에 똑같이 반복되도록 한다.
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
body::-webkit-scrollbar {
  display: none !important;
}
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
/* 네이티브(안드로이드 WebView) 텍스트 선택을 완전히 꺼둔다. 이걸 켜두면 롱프레스 시
   시스템 복사/공유 툴바가 우리 형광펜 팝업보다 먼저 뜨는 문제가 생긴다. 대신
   본문 선택은 아래 커스텀 롱프레스 로직(JS)으로 직접 구현해서 시스템 UI를
   아예 거치지 않는다. */
#__reader_content_wrap__, #__reader_content_wrap__ * {
  -webkit-user-select: none !important;
  user-select: none !important;
  -webkit-touch-callout: none !important;
}
''';

/// document에 주입하면 window.__reader에 페이지 넘김 관련 함수들을 만들어준다.
///
/// 실제 DOM 조작(wrapper 만들기, 스타일 적용 등)은 DOMContentLoaded 시점에 실행된다.
/// onPageFinished(이미지/폰트 등 모든 리소스가 다 로드된 뒤 발생)까지 기다리면,
/// 느린 웹폰트나 이미지가 있는 챕터에서 우리 설정(폰트/글자크기/여백)이 몇 초씩 늦게
/// 적용되는 문제가 있었다(실제 겪은 버그). DOMContentLoaded는 HTML 구조만 다 읽히면
/// 바로 발생해서 이미지/폰트를 기다리지 않으므로 훨씬 빨리 적용된다.
/// 이 스크립트를 언제 호출하든(로딩 시작 직후든 완료 후든) 안전하게 동작한다.
///
/// pageWidth()는 WebView 안에서 아무것도 다시 측정하지 않는다. Flutter가 넘겨준
/// %PAGE_WIDTH_PX% 리터럴 값을 그대로 쓴다 (CSS의 column-width와 완전히 동일한 값).
const String kReaderInitJsTemplate = '''
(function() {
  function __readerBoot() {
    // EPUB 안에 뷰포트 메타 태그가 없거나 잘못된 경우, WebView가 "넓은 가상 화면"으로
    // 렌더링한 뒤 축소해서 보여주는 경우가 있다. 항상 device-width로 강제 고정해서
    // 이런 축소/확대로 인한 좌표 왜곡을 방지한다.
    var vp = document.querySelector('meta[name="viewport"]');
    if (!vp) {
      vp = document.createElement('meta');
      vp.setAttribute('name', 'viewport');
      document.head.insertBefore(vp, document.head.firstChild || null);
    }
    vp.setAttribute('content', 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no');

    // body의 기존 내용을 전부 wrapper 하나로 감싼다. 여백/글자 확대는 이 wrapper에만
    // 적용해서, body 자체(컬럼/페이지 폭 계산 기준)는 항상 순수 페이지 폭을 유지한다.
    // 설정이 바뀌어 이 스크립트가 다시 실행돼도 한 번만 감싸지도록 방지한다.
    var wrapId = "__reader_content_wrap__";
    var wrap = document.getElementById(wrapId);
    if (!wrap) {
      wrap = document.createElement("div");
      wrap.id = wrapId;
      while (document.body.firstChild) {
        wrap.appendChild(document.body.firstChild);
      }
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

    // Flutter가 실측해서 넘겨준 값 그대로 사용 (WebView 안에서 다시 계산하지 않음).
    var PAGE_WIDTH = %PAGE_WIDTH_PX%;
    function pageWidth() { return PAGE_WIDTH; }
    function scrollBox() { return document.body; }
    function maxScrollLeft() {
      return Math.max(0, scrollBox().scrollWidth - PAGE_WIDTH);
    }

    window.__reader = {
      nextPage: function() {
        var box = scrollBox();
        var max = maxScrollLeft();
        if (box.scrollLeft >= max - 1) return "chapter-end";
        box.scrollLeft = Math.min(max, box.scrollLeft + PAGE_WIDTH);
        return "ok";
      },
      prevPage: function() {
        var box = scrollBox();
        if (box.scrollLeft <= 1) return "chapter-start";
        box.scrollLeft = Math.max(0, box.scrollLeft - PAGE_WIDTH);
        return "ok";
      },
      goToStart: function() { scrollBox().scrollLeft = 0; },
      goToEnd: function() { scrollBox().scrollLeft = maxScrollLeft(); },
      goToFraction: function(f) {
        var max = maxScrollLeft();
        var page = Math.round((f * max) / PAGE_WIDTH);
        scrollBox().scrollLeft = Math.max(0, Math.min(max, page * PAGE_WIDTH));
      },
      clampPosition: function() {
        var box = scrollBox();
        var max = maxScrollLeft();
        var snapped = Math.round(box.scrollLeft / PAGE_WIDTH) * PAGE_WIDTH;
        box.scrollLeft = Math.max(0, Math.min(max, snapped));
      },
      getFraction: function() {
        var max = maxScrollLeft();
        if (max <= 0) return 0;
        return scrollBox().scrollLeft / max;
      },
      getPageLabel: function() {
        var current = Math.round(scrollBox().scrollLeft / PAGE_WIDTH) + 1;
        var total = Math.max(1, Math.round(scrollBox().scrollWidth / PAGE_WIDTH));
        return current + " / " + total;
      }
    };

    // ---- 형광펜 (Phase 5) ----
    // 하이라이트 위치는 wrapper(#__reader_content_wrap__)의 전체 텍스트를 처음부터
    // 이어붙였을 때의 "글자 몇 번째 ~ 몇 번째"라는 순수 문자 오프셋으로 저장/복원한다.
    // 폰트 크기/여백 등 설정이 바뀌어도 원본 HTML의 글자 자체는 그대로이므로 항상 유효하다.

    // Range 경계(container+offset)를 wrapper 시작부터의 문자 개수로 변환.
    function charOffsetOfBoundary(root, node, offset) {
      var r = document.createRange();
      r.selectNodeContents(root);
      try { r.setEnd(node, offset); } catch (e) { return 0; }
      return r.toString().length;
    }

    // 문자 개수(target)에 해당하는 실제 텍스트 노드+오프셋을 찾는다 (위 함수의 역변환).
    function pointForCharOffset(root, target) {
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var count = 0;
      var node;
      while ((node = walker.nextNode())) {
        var len = node.nodeValue.length;
        if (count + len >= target) {
          return { node: node, offset: Math.max(0, target - count) };
        }
        count += len;
      }
      if (node) return { node: node, offset: node.nodeValue.length };
      return null;
    }

    // Range의 경계를 텍스트 노드 경계에 정확히 맞춘다 (필요하면 텍스트 노드를 쪼갠다).
    // range.intersectsNode를 써서 "이 텍스트 노드가 Range와 겹치는지"를 판정하므로,
    // Range의 시작/끝 경계가 텍스트 노드 한가운데든, 엘리먼트 자식 인덱스(텍스트 노드가
    // 아닌 지점)로 표현되어 있든 상관없이 항상 정확하게 동작한다.
    // className/attrName/styleCss를 파라미터로 받아서 형광펜과 메모 둘 다에 재사용한다.
    function wrapRangeWithSpan(range, id, className, attrName, styleCss) {
      var rootEl = range.commonAncestorContainer;
      if (rootEl.nodeType === 3) rootEl = rootEl.parentNode;
      var walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT, null);
      var targets = [];
      var node;
      while ((node = walker.nextNode())) {
        if (range.intersectsNode(node)) targets.push(node);
      }
      // 뒤에서부터 처리한다: splitText가 뒤쪽에 새 형제 노드를 만들기 때문에,
      // 앞쪽 노드부터 처리하면 이후 인덱스가 가리키는 노드가 틀어질 수 있다.
      for (var i = targets.length - 1; i >= 0; i--) {
        var n = targets[i];
        if (!n.parentNode || !n.nodeValue) continue;
        var startLocal = (n === range.startContainer) ? range.startOffset : 0;
        var endLocal = (n === range.endContainer) ? range.endOffset : n.nodeValue.length;
        if (startLocal >= endLocal) continue; // 경계만 살짝 닿는 경우 (실제 겹치는 글자 없음)
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
      var start = pointForCharOffset(wrap, entry.start);
      var end = pointForCharOffset(wrap, entry.end);
      if (!start || !end) return;
      var range = document.createRange();
      try {
        range.setStart(start.node, start.offset);
        range.setEnd(end.node, end.offset);
      } catch (e) { return; }
      wrapRangeWithSpan(
        range, entry.id, "reader-highlight", "data-hl-id",
        "background-color:" + entry.color + ";border-radius:2px;"
      );
    }

    // 메모는 배경색 대신 은은한 점선 밑줄로만 표시한다 (형광펜과 시각적으로 구분되도록).
    function applyMemoEntry(entry) {
      var start = pointForCharOffset(wrap, entry.start);
      var end = pointForCharOffset(wrap, entry.end);
      if (!start || !end) return;
      var range = document.createRange();
      try {
        range.setStart(start.node, start.offset);
        range.setEnd(end.node, end.offset);
      } catch (e) { return; }
      wrapRangeWithSpan(
        range, entry.id, "reader-memo", "data-memo-id",
        "border-bottom:2px dashed rgba(255,145,0,0.85);"
      );
    }

    // 이 챕터 문서가 새로 로드된 뒤 딱 한 번만, 저장돼있던 하이라이트/메모를 그려 넣는다.
    // (설정 변경 등으로 스크립트가 재주입돼도 같은 document라면 다시 그리지 않아서
    // span이 중첩되어 겹치는 문제를 막는다.)
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
      var spans = document.querySelectorAll('.reader-highlight[data-hl-id="' + id + '"]');
      spans.forEach(function(span) {
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
      var spans = document.querySelectorAll('.reader-memo[data-memo-id="' + id + '"]');
      spans.forEach(function(span) {
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

    // 형광펜/메모 통합 목록 화면에서 항목을 탭했을 때, 그 span이 있는 페이지로 스크롤한다.
    window.__reader.scrollToSelector = function(selector) {
      var el = document.querySelector(selector);
      if (!el) return "not-found";
      var rect = el.getBoundingClientRect();
      var box = scrollBox();
      var absoluteX = rect.left + box.scrollLeft;
      var pageIndex = Math.max(0, Math.floor(absoluteX / PAGE_WIDTH));
      box.scrollLeft = Math.min(maxScrollLeft(), pageIndex * PAGE_WIDTH);
      return "ok";
    };

    // ---- 검색 (Phase 7) ----
    // Flutter(Dart)가 파일에서 직접 뽑아낸 평문으로 미리 찾아둔 occurrenceIndex번째
    // 일치 위치를, 실제로 브라우저가 렌더링한 이 문서 안에서 다시 찾아 그 페이지로 스크롤한다.
    // (Dart의 평문 추출이 브라우저 렌더링과 100% 똑같지 않을 수 있으니, 최종 위치 확정은
    // 항상 여기 이 실제 DOM 기준으로 한다.)
    window.__reader.findAndScrollTo = function(query, occurrenceIndex) {
      var walker = document.createTreeWalker(wrap, NodeFilter.SHOW_TEXT, null);
      var node;
      var fullText = "";
      var nodeRanges = [];
      while ((node = walker.nextNode())) {
        var start = fullText.length;
        fullText += node.nodeValue;
        nodeRanges.push({ node: node, start: start, end: fullText.length });
      }
      var lowerText = fullText.toLowerCase();
      var lowerQuery = String(query).toLowerCase();
      var idx = -1;
      var count = 0;
      var searchFrom = 0;
      while (true) {
        idx = lowerText.indexOf(lowerQuery, searchFrom);
        if (idx === -1) break;
        if (count === occurrenceIndex) break;
        count++;
        searchFrom = idx + 1;
      }
      if (idx === -1) return "not-found";

      var target = null;
      var localOffset = 0;
      for (var i = 0; i < nodeRanges.length; i++) {
        if (idx >= nodeRanges[i].start && idx < nodeRanges[i].end) {
          target = nodeRanges[i].node;
          localOffset = idx - nodeRanges[i].start;
          break;
        }
      }
      if (!target) return "not-found";

      var range = document.createRange();
      range.setStart(target, localOffset);
      range.setEnd(target, Math.min(target.nodeValue.length, localOffset + lowerQuery.length));

      // 이 순간의 스크롤 위치를 더해 "문서 전체 기준" 절대 x좌표를 구하고, (검색 이동용)
      // 그 좌표가 속한 페이지(컬럼)의 시작점으로 스크롤을 스냅한다.
      var rect = range.getBoundingClientRect();
      var box = scrollBox();
      var absoluteX = rect.left + box.scrollLeft;
      var pageIndex = Math.max(0, Math.floor(absoluteX / PAGE_WIDTH));
      box.scrollLeft = Math.min(maxScrollLeft(), pageIndex * PAGE_WIDTH);
      return "ok";
    };

    // ---- 커스텀 텍스트 선택 (Phase 5 개선) ----
    // 안드로이드 WebView의 기본 롱프레스 선택을 쓰면, 텍스트를 잡는 순간 시스템의
    // 복사/공유 툴바가 우리 형광펜 색상 팝업보다 먼저(또는 동시에) 떠서 서로 가리는
    // 문제가 있었다. webview_flutter는 이 시스템 툴바(Android ActionMode)를 끄는
    // API를 제공하지 않기 때문에, 애초에 네이티브 텍스트 선택 자체를 CSS로 꺼두고
    // (kPaginationCss의 user-select:none 참고) 롱프레스 감지부터 선택 영역 표시,
    // 드래그로 범위 조정까지 전부 이 JS가 직접 구현한다. window.getSelection()은
    // 전혀 쓰지 않으므로 시스템 액션바가 뜰 일이 아예 없다.
    if (!window.__readerCustomSelectionBound) {
      window.__readerCustomSelectionBound = true;

      var csel = { startNode: null, startOffset: 0, endNode: null, endOffset: 0, active: false };
      var overlayLayer = null;
      var startHandle = null;
      var endHandle = null;
      var longPressTimer = null;
      var longPressOrigin = null; // {x, y}
      var draggingHandle = null; // "start" | "end" | null
      var suppressNextClick = false;

      function ensureOverlayLayer() {
        if (overlayLayer && overlayLayer.isConnected) return overlayLayer;
        overlayLayer = document.createElement("div");
        overlayLayer.id = "__reader_selection_layer__";
        overlayLayer.style.cssText =
          "position:fixed;left:0;top:0;right:0;bottom:0;pointer-events:none;z-index:2147483000;";
        document.body.appendChild(overlayLayer);
        return overlayLayer;
      }

      function makeHandle(side) {
        var h = document.createElement("div");
        h.className = "__reader_sel_handle__";
        h.dataset.side = side;
        h.style.cssText =
          "position:fixed;width:28px;height:28px;pointer-events:auto;z-index:2147483001;touch-action:none;";
        h.innerHTML =
          '<svg width="28" height="28" viewBox="0 0 28 28" style="display:block;">' +
          '<circle cx="14" cy="14" r="8" fill="#4285F4"/></svg>';
        return h;
      }

      function currentRange() {
        if (!csel.startNode || !csel.endNode) return null;
        var r = document.createRange();
        try {
          r.setStart(csel.startNode, csel.startOffset);
          r.setEnd(csel.endNode, csel.endOffset);
        } catch (e) { return null; }
        if (r.collapsed) return null;
        return r;
      }

      // start가 end보다 문서상 뒤에 오게 됐으면(핸들을 반대로 넘겨 끈 경우) 서로 바꾼다.
      function normalizeOrder() {
        if (!csel.startNode || !csel.endNode) return;
        var r = document.createRange();
        r.setStart(csel.startNode, csel.startOffset);
        r.setEnd(csel.endNode, csel.endOffset);
        if (r.collapsed) {
          var tn = csel.startNode, to = csel.startOffset;
          csel.startNode = csel.endNode; csel.startOffset = csel.endOffset;
          csel.endNode = tn; csel.endOffset = to;
        }
      }

      function renderOverlay() {
        var range = currentRange();
        var layer = ensureOverlayLayer();
        var oldRects = layer.querySelectorAll(".__reader_sel_rect__");
        for (var i = 0; i < oldRects.length; i++) oldRects[i].remove();
        if (!range) {
          if (startHandle) { startHandle.remove(); startHandle = null; }
          if (endHandle) { endHandle.remove(); endHandle = null; }
          return;
        }
        var rects = range.getClientRects();
        for (var j = 0; j < rects.length; j++) {
          var r = rects[j];
          if (r.width <= 0 || r.height <= 0) continue;
          var box = document.createElement("div");
          box.className = "__reader_sel_rect__";
          box.style.cssText =
            "position:fixed;left:" + r.left + "px;top:" + r.top + "px;" +
            "width:" + r.width + "px;height:" + r.height + "px;" +
            "background:rgba(66,133,244,0.35);pointer-events:none;";
          layer.appendChild(box);
        }
        if (rects.length > 0) {
          var first = rects[0], last = rects[rects.length - 1];
          if (!startHandle) { startHandle = makeHandle("start"); layer.appendChild(startHandle); bindHandleEvents(startHandle); }
          if (!endHandle) { endHandle = makeHandle("end"); layer.appendChild(endHandle); bindHandleEvents(endHandle); }
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
        ReaderSelection.postMessage(JSON.stringify({
          text: text, start: start, end: end,
          left: rect.left, top: rect.top, width: rect.width, height: rect.height
        }));
      }

      function clearCustomSelection() {
        csel.active = false;
        csel.startNode = csel.endNode = null;
        if (overlayLayer) {
          var rects = overlayLayer.querySelectorAll(".__reader_sel_rect__");
          for (var i = 0; i < rects.length; i++) rects[i].remove();
        }
        if (startHandle) { startHandle.remove(); startHandle = null; }
        if (endHandle) { endHandle.remove(); endHandle = null; }
        if (window.ReaderSelection) ReaderSelection.postMessage("none");
      }
      window.__reader.clearCustomSelection = clearCustomSelection;

      // (x, y) 지점(뷰포트 좌표)이 걸쳐 있는 텍스트 노드+오프셋. 이미지 등 텍스트가
      // 아닌 지점을 짚으면 null.
      function caretAt(x, y) {
        if (!document.caretRangeFromPoint) return null;
        var r = document.caretRangeFromPoint(x, y);
        if (r && r.startContainer && r.startContainer.nodeType === 3) {
          return { node: r.startContainer, offset: r.startOffset };
        }
        return null;
      }

      // 캐럿이 속한 "단어" 하나의 시작/끝 오프셋. Intl.Segmenter가 있으면 한글 등
      // 공백 없는 언어도 자연스럽게 잡히고, 없으면 공백/구두점 기준으로 대략 흉내낸다.
      function wordBoundsAround(node, offset) {
        var text = node.nodeValue || "";
        if (window.Intl && Intl.Segmenter) {
          try {
            var segmenter = new Intl.Segmenter(undefined, { granularity: "word" });
            var segments = segmenter.segment(text);
            var iterator = segments[Symbol.iterator]();
            var item;
            while (!(item = iterator.next()).done) {
              var s = item.value;
              if (offset >= s.index && offset <= s.index + s.segment.length && s.segment.trim().length > 0) {
                return { start: s.index, end: s.index + s.segment.length };
              }
            }
          } catch (e) { /* Segmenter 미지원 브라우저는 아래 기본 로직으로 대체 */ }
        }
        var isBoundary = function(ch) { return /\\s/.test(ch); };
        var start = offset, end = offset;
        while (start > 0 && !isBoundary(text[start - 1])) start--;
        while (end < text.length && !isBoundary(text[end])) end++;
        if (start === end) { start = offset; end = Math.min(text.length, offset + 1); }
        return { start: start, end: end };
      }

      function bindHandleEvents(handle) {
        handle.addEventListener("touchstart", function(e) {
          e.preventDefault();
          e.stopPropagation();
          draggingHandle = handle.dataset.side;
        }, { passive: false });
        handle.addEventListener("touchmove", function(e) {
          if (!draggingHandle) return;
          e.preventDefault();
          e.stopPropagation();
          var t = e.touches[0];
          // 선택 핸들을 좌/우 가장자리로 끌면 페이지를 넘긴 뒤 같은 손가락 위치에서
          // 계속 범위를 잡는다. 일반 페이지 스와이프가 선택을 빼앗지 않게 이 핸들
          // 이벤트에서 preventDefault를 유지한다.
          var box = scrollBox();
          var edge = 22;
          var max = maxScrollLeft();
          if (t.clientX > PAGE_WIDTH - edge && box.scrollLeft < max - 1) {
            box.scrollLeft = Math.min(max, box.scrollLeft + PAGE_WIDTH);
            setTimeout(function() {
              if (!draggingHandle) return;
              var movedCaret = caretAt(PAGE_WIDTH - edge - 2, t.clientY);
              if (!movedCaret) return;
              if (draggingHandle === "start") { csel.startNode = movedCaret.node; csel.startOffset = movedCaret.offset; }
              else { csel.endNode = movedCaret.node; csel.endOffset = movedCaret.offset; }
              normalizeOrder(); renderOverlay(); reportSelection();
            }, 60);
            return;
          }
          if (t.clientX < edge && box.scrollLeft > 1) {
            box.scrollLeft = Math.max(0, box.scrollLeft - PAGE_WIDTH);
            setTimeout(function() {
              if (!draggingHandle) return;
              var movedCaret = caretAt(edge + 2, t.clientY);
              if (!movedCaret) return;
              if (draggingHandle === "start") { csel.startNode = movedCaret.node; csel.startOffset = movedCaret.offset; }
              else { csel.endNode = movedCaret.node; csel.endOffset = movedCaret.offset; }
              normalizeOrder(); renderOverlay(); reportSelection();
            }, 60);
            return;
          }
          var caret = caretAt(t.clientX, t.clientY);
          if (!caret) return;
          if (draggingHandle === "start") { csel.startNode = caret.node; csel.startOffset = caret.offset; }
          else { csel.endNode = caret.node; csel.endOffset = caret.offset; }
          normalizeOrder();
          renderOverlay();
        }, { passive: false });
        handle.addEventListener("touchend", function(e) {
          e.preventDefault();
          e.stopPropagation();
          draggingHandle = null;
          reportSelection();
        }, { passive: false });
      }

      document.body.addEventListener("touchstart", function(e) {
        if (draggingHandle) return;
        if (e.touches.length !== 1) return;
        var target = e.target;
        if (target.closest && target.closest(".reader-memo, .reader-highlight, a, .__reader_sel_handle__")) {
          longPressOrigin = null;
          return;
        }
        var t = e.touches[0];
        longPressOrigin = { x: t.clientX, y: t.clientY };
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
          suppressNextClick = true;
          renderOverlay();
          reportSelection();
          if (navigator.vibrate) navigator.vibrate(10);
        }, 380);
      }, { passive: true });

      document.body.addEventListener("touchmove", function(e) {
        if (!longPressTimer || !longPressOrigin) return;
        var t = e.touches[0];
        var dx = Math.abs(t.clientX - longPressOrigin.x);
        var dy = Math.abs(t.clientY - longPressOrigin.y);
        if (dx > 10 || dy > 10) { clearTimeout(longPressTimer); longPressTimer = null; }
      }, { passive: true });

      document.body.addEventListener("touchend", function() {
        if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; }
      }, { passive: true });
      document.body.addEventListener("touchcancel", function() {
        if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; }
      }, { passive: true });

      // 선택이 떠 있는 동안 바깥(핸들/오버레이가 아닌 곳)을 탭하면 페이지 넘김보다
      // 선택 해제를 우선한다. 롱프레스 직후에 뒤따라오는 합성 클릭도 걸러낸다.
      // capture 단계에서 먼저 가로채서, 기존 페이지 넘김/하이라이트-탭 click
      // 핸들러(버블 단계)까지 이벤트가 내려가지 않게 막는다.
      document.addEventListener("click", function(e) {
        if (suppressNextClick) {
          suppressNextClick = false;
          e.preventDefault();
          e.stopImmediatePropagation();
          return;
        }
        if (csel.active && !(e.target.closest && e.target.closest("#__reader_selection_layer__"))) {
          clearCustomSelection();
          e.preventDefault();
          e.stopImmediatePropagation();
        }
      }, true);
    }

    // 탭 위치로 좌(이전 페이지)/우(다음 페이지)/가운데(툴바 토글) 판정.
    // 링크(<a>) 클릭은 페이지 넘김으로 가로채지 않고 그대로 동작하게 둔다.
    // 하이라이트(.reader-highlight)/메모(.reader-memo) 탭은 페이지 넘김이 아니라
    // 각각의 관리 메뉴를 띄우는 데 쓴다.
    if (!window.__readerTapBound) {
      window.__readerTapBound = true;
      document.addEventListener("click", function(e) {
        var memo = e.target.closest(".reader-memo");
        if (memo) {
          if (window.ReaderMemoTap) ReaderMemoTap.postMessage(memo.getAttribute("data-memo-id"));
          return;
        }
        var hl = e.target.closest(".reader-highlight");
        if (hl) {
          if (window.ReaderHighlightTap) ReaderHighlightTap.postMessage(hl.getAttribute("data-hl-id"));
          return;
        }
        if (e.target.closest("a")) return;
        var x = e.clientX;
        var zone = x < PAGE_WIDTH * 0.3 ? "left" : (x > PAGE_WIDTH * 0.7 ? "right" : "center");
        if (window.ReaderTap) ReaderTap.postMessage(zone);
      });
    }

    // 손가락으로 드래그해서 자유롭게 스크롤할 수 있게 두고(overflow-x:scroll), 손을 뗀
    // 뒤(touchend) 스크롤이 멈추면 가장 가까운 페이지 경계로 자연스럽게 스냅시킨다.
    // 손가락이 화면에 붙어있는 동안은(isTouching) 절대 스냅하지 않는다.
    if (!window.__readerSnapBound) {
      window.__readerSnapBound = true;
      var isTouching = false;
      var snapTimer = null;

      function scheduleSnap() {
        if (snapTimer) clearTimeout(snapTimer);
        snapTimer = setTimeout(function() {
          if (isTouching) return;
          var box = scrollBox();
          var max = maxScrollLeft();
          var target = Math.max(0, Math.min(max, Math.round(box.scrollLeft / PAGE_WIDTH) * PAGE_WIDTH));
          if (Math.abs(box.scrollLeft - target) > 1) {
            box.scrollTo({ left: target, behavior: "smooth" });
          }
          if (window.ReaderTap) ReaderTap.postMessage("settled");
        }, 150);
      }

      document.body.addEventListener("touchstart", function() {
        isTouching = true;
        if (snapTimer) clearTimeout(snapTimer);
      }, { passive: true });
      document.body.addEventListener("touchend", function() {
        isTouching = false;
        scheduleSnap();
      }, { passive: true });
      document.body.addEventListener("touchcancel", function() {
        isTouching = false;
        scheduleSnap();
      }, { passive: true });
      document.body.addEventListener("scroll", scheduleSnap, { passive: true });
    }
  }

  // document.body/head가 아직 없을 수 있는 아주 이른 시점에 호출돼도 안전하게,
  // DOM 준비 상태에 따라 즉시 실행하거나 DOMContentLoaded를 기다린다.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", __readerBoot);
  } else {
    __readerBoot();
  }
})();
''';
