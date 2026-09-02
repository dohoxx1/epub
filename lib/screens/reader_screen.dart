import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../models/epub_book.dart';
import '../models/reader_settings.dart';
import '../services/database/app_database.dart';
import '../services/epub_repository.dart';
import '../services/reader_css_builder.dart';
import '../services/reader_pagination_js.dart';
import '../services/reader_search_service.dart';
import 'reader_notes_sheet.dart';
import 'reader_search_screen.dart';
import 'reader_settings_sheet.dart';
import 'reader_toc_sheet.dart';

/// JS에서 window.ReaderSelection.postMessage(...)로 넘어온 현재 텍스트 선택 정보.
/// left/top/width/height는 WebView 뷰포트 기준 CSS px (뷰포트를 device-width로
/// 고정해뒀으므로 Flutter의 논리 픽셀과 1:1로 대응한다).
class _SelectionInfo {
  final String text;
  final int start;
  final int end;
  final double left;
  final double top;
  final double width;
  final double height;

  const _SelectionInfo({
    required this.text,
    required this.start,
    required this.end,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory _SelectionInfo.fromJson(Map<String, dynamic> j) => _SelectionInfo(
        text: j['text'] as String,
        start: (j['start'] as num).toInt(),
        end: (j['end'] as num).toInt(),
        left: (j['left'] as num).toDouble(),
        top: (j['top'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
      );
}

/// 챕터를 새로 로드했을 때 어느 위치에서 시작할지.
sealed class _PagePosition {
  const _PagePosition();
}

class _PageStart extends _PagePosition {
  const _PageStart();
}

class _PageEnd extends _PagePosition {
  const _PageEnd();
}

class _PageFraction extends _PagePosition {
  final double fraction;
  const _PageFraction(this.fraction);
}

class ReaderScreen extends ConsumerStatefulWidget {
  final String epubPath;
  const ReaderScreen({super.key, required this.epubPath});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver {
  final _repo = EpubRepository();
  late final WebViewController _webController;

  EpubBook? _book;
  int? _bookId;
  int _spineIndex = 0;
  String _pageLabel = '1 / 1';
  _PagePosition _pendingPosition = const _PageStart();
  ReaderSettings _settings = ReaderSettings.defaults();

  // Phase 5: 형광펜. 현재 챕터에 저장된 하이라이트 목록과, 지금 사용자가 드래그로
  // 선택 중인 텍스트(있다면) 정보. 선택 중일 때만 색상 선택 팝업을 띄운다.
  List<HighlightRow> _currentHighlights = [];
  _SelectionInfo? _activeSelection;

  // Phase 6: 메모. 현재 챕터에 저장된 메모 목록.
  List<MemoRow> _currentMemos = [];

  // Phase 7: 검색. 검색 결과를 탭해서 다른 챕터로 이동한 경우, 그 챕터 로딩이
  // 끝난 직후(_onPageFinished) 실제 DOM에서 다시 찾아 스크롤할 목표.
  ({String matchText, int occurrenceIndex})? _pendingSearchJump;

  // "내 노트"(형광펜/메모/책갈피 통합 목록)에서 다른 챕터에 있는 항목을 탭해서 이동한
  // 경우, 그 챕터 로딩이 끝난 직후 이 선택자로 실제 위치를 찾아 스크롤한다.
  String? _pendingElementSelector;

  // Color.value/.red/.green/.blue 같은 getter는 Flutter 버전에 따라 변경/폐지될 수 있어서
  // 애초에 Color 객체가 아니라 raw ARGB int(0xAARRGGBB)로만 다룬다. UI에 그릴 때만 Color(...)로 감싼다.
  static const List<int> _highlightColorValues = [
    0xFFFFF59D, // 노랑
    0xFFC5E1A5, // 초록
    0xFFB3E5FC, // 파랑
    0xFFF8BBD0, // 분홍
    0xFFFFCC80, // 주황
  ];

  bool _loading = true;
  String? _error;
  bool _chromeVisible = false;

  Timer? _settingsSaveDebounce;
  Timer? _readingTimer;
  int? _readingSessionId;
  DateTime? _lastReadingTick;
  DateTime? _lastReaderInteraction;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('ReaderTap',
          onMessageReceived: (msg) => _handleTap(msg.message))
      ..addJavaScriptChannel('ReaderSelection',
          onMessageReceived: _handleSelectionMessage)
      ..addJavaScriptChannel('ReaderHighlightTap',
          onMessageReceived: _handleHighlightTapMessage)
      ..addJavaScriptChannel('ReaderMemoTap',
          onMessageReceived: _handleMemoTapMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _onPageStarted(),
          onPageFinished: (_) => _onPageFinished(),
        ),
      );

    _open();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settingsSaveDebounce?.cancel();
    _readingTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 화면을 나갈 때 마지막으로 한 번 더 저장 (완료를 기다리지 않고 최선을 다해 시도)
    _saveCurrentPosition();
    _finishReadingSession();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _saveCurrentPosition();
      _finishReadingSession();
    } else if (state == AppLifecycleState.resumed) {
      _beginReadingSession();
    }
  }

  Future<void> _open() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = ref.read(appDatabaseProvider);
      final settings = await db.loadSettings();
      final book = await _repo.openBook(widget.epubPath);
      final bookId = await db.getOrCreateBook(
        originalUri: widget.epubPath,
        title: book.title,
        author: book.author,
        coverImagePath: book.coverImagePath,
      );
      final progress = await db.getProgress(bookId);

      setState(() {
        _settings = settings;
        _book = book;
        _bookId = bookId;
        _spineIndex = progress?.spineIndex ?? 0;
        _loading = false;
      });

      _pendingPosition = _PageFraction(progress?.scrollFraction ?? 0.0);
      await _loadCurrentChapter();
      await _beginReadingSession(
          initialFraction: progress?.scrollFraction ?? 0.0);
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 챕터를 로드한다. (loadHtmlString+baseUrl 방식은 Android WebView에서 file://
  /// 리소스(이미지, 원본 CSS) 접근이 제한되는 문제가 있어서 loadFile로 되돌렸다.)
  Future<void> _loadCurrentChapter() async {
    final book = _book;
    if (book == null || book.spine.isEmpty) return;
    final chapterPath = book.spine[_spineIndex].href;

    // 새 챕터로 넘어가면 이전 챕터에서 뜨던 선택/색상팝업은 의미가 없으므로 닫는다.
    if (_activeSelection != null) setState(() => _activeSelection = null);

    // 이 챕터에 저장된 형광펜/메모를 미리 가져와둔다. _onPageFinished에서 스크립트를
    // 주입할 때 이 목록을 함께 넘겨서 재렌더링 시 그대로 복원되게 한다.
    final bookId = _bookId;
    if (bookId == null) {
      _currentHighlights = [];
      _currentMemos = [];
    } else {
      final db = ref.read(appDatabaseProvider);
      _currentHighlights = await db.getHighlights(bookId, _spineIndex);
      _currentMemos = await db.getMemos(bookId, _spineIndex);
    }

    // 배경색은 로드 전에 먼저 맞춰서 흰 화면 깜빡임을 최대한 줄인다.
    final (bg, _) = _settings.resolvedThemeColors;
    await _webController
        .setBackgroundColor(bg != null ? Color(bg) : Colors.transparent);

    await _webController.loadFile(chapterPath);
  }

  /// 페이지 로딩이 막 시작됐을 때 최선을 다해 한 번 더 스타일을 적용해본다.
  /// 이 시점엔 document.head가 아직 없을 수도 있어서 실패할 수 있는데, 그래도 괜찮다
  /// (onPageFinished에서 확실하게 다시 적용되므로 이건 어디까지나 깜빡임을 줄이기 위한 보너스).
  Future<void> _onPageStarted() async {
    try {
      await _injectReaderScript();
    } catch (_) {
      // 아직 문서가 준비 안 됐으면 조용히 무시.
    }
  }

  /// 챕터 로딩이 끝난 직후 호출됨. 스타일/스크립트를 확실하게 (다시) 주입하고,
  /// 목표 위치(처음/끝/비율)로 이동한 뒤, 페이지 라벨을 갱신 + 저장한다.
  Future<void> _onPageFinished() async {
    await _injectReaderScript();

    switch (_pendingPosition) {
      case _PageStart():
        await _webController.runJavaScript('window.__reader.goToStart();');
      case _PageEnd():
        await _webController.runJavaScript('window.__reader.goToEnd();');
      case _PageFraction(fraction: final f):
        await _webController.runJavaScript('window.__reader.goToFraction($f);');
    }
    _pendingPosition = const _PageStart();

    final searchJump = _pendingSearchJump;
    if (searchJump != null) {
      _pendingSearchJump = null;
      await _webController.runJavaScript(
        'window.__reader.findAndScrollTo(${jsonEncode(searchJump.matchText)}, ${searchJump.occurrenceIndex});',
      );
    }

    final elementSelector = _pendingElementSelector;
    if (elementSelector != null) {
      _pendingElementSelector = null;
      await _webController.runJavaScript(
        'window.__reader.scrollToSelector(${jsonEncode(elementSelector)});',
      );
    }

    await _refreshPageLabelAndSave();
  }

  /// Flutter가 실측한 화면 폭(논리 픽셀, WebView 렌더링 폭과 1:1로 대응).
  /// 이 값을 CSS의 column-width와 JS의 페이지 이동 거리 양쪽에 동일하게 박아 넣어서,
  /// WebView 내부에서 독자적으로 폭을 계산하다가 어긋나는 문제를 원천 차단한다.
  double get _pageWidthPx {
    final width = MediaQuery.sizeOf(context).width;
    return width > 0 ? width : 360.0;
  }

  /// 페이지네이션 CSS + 사용자 설정 CSS + 탭 판별 스크립트 + 저장된 형광펜을 한 번에 주입한다.
  /// 여러 번 호출돼도 안전하다 (탭/선택 리스너와 형광펜 복원은 JS 쪽에서 중복 실행 방지).
  Future<void> _injectReaderScript() async {
    final pageWidthStr = _pageWidthPx.toStringAsFixed(2);
    final paginationCss =
        kPaginationCss.replaceAll('%PAGE_WIDTH_PX%', pageWidthStr);
    final css = paginationCss + buildReaderOverrideCss(_settings);
    final highlightsJson = jsonEncode(_currentHighlights
        .map((h) => {
              'id': h.id,
              'start': h.startOffset,
              'end': h.endOffset,
              'color': _cssColor(h.colorValue),
            })
        .toList());
    final memosJson = jsonEncode(_currentMemos
        .map((m) => {
              'id': m.id,
              'start': m.startOffset,
              'end': m.endOffset,
            })
        .toList());
    final js = kReaderInitJsTemplate
        .replaceFirst('%CSS%', jsonEncode(css))
        .replaceFirst('%HIGHLIGHTS_JSON%', highlightsJson)
        .replaceFirst('%MEMOS_JSON%', memosJson)
        .replaceAll('%PAGE_WIDTH_PX%', pageWidthStr);
    await _webController.runJavaScript(js);

    final (bg, _) = _settings.resolvedThemeColors;
    await _webController
        .setBackgroundColor(bg != null ? Color(bg) : Colors.transparent);
  }

  /// ARGB int(0xAARRGGBB)를 JS에 넘길 CSS 색상 문자열로 변환한다.
  /// Color.red/green/blue 같은 getter에 의존하지 않고 직접 비트 연산한다
  /// (Flutter 버전이 올라가도 항상 안전하게 동작하도록).
  String _cssColor(int argb) {
    final a = (argb >> 24) & 0xFF;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return 'rgba($r, $g, $b, ${(a / 255).toStringAsFixed(3)})';
  }

  void _handleTap(String zone) {
    _markReadingActivity();
    switch (zone) {
      case 'left':
        _prevPage();
        break;
      case 'right':
        _nextPage();
        break;
      case 'center':
        _toggleChrome();
        break;
      case 'settled':
        // 손가락으로 드래그해서 스크롤한 뒤 페이지 경계에 스냅된 시점.
        _refreshPageLabelAndSave();
        break;
    }
  }

  /// JS의 selectionchange 리스너가 (디바운스해서) 보내주는 현재 텍스트 선택 정보.
  /// "none"이면 선택이 사라진 것이므로 색상 팝업을 닫는다.
  void _handleSelectionMessage(JavaScriptMessage msg) {
    _markReadingActivity();
    final raw = msg.message;
    if (raw == 'none') {
      if (_activeSelection != null) setState(() => _activeSelection = null);
      return;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final info = _SelectionInfo.fromJson(json);
      if (info.text.trim().isEmpty) {
        if (_activeSelection != null) setState(() => _activeSelection = null);
        return;
      }
      setState(() => _activeSelection = info);
    } catch (_) {
      // 파싱 실패는 조용히 무시 (다음 selectionchange에서 다시 시도됨).
    }
  }

  /// 이미 만들어진 형광펜 영역을 탭했을 때: 삭제 여부를 묻는 시트를 띄운다.
  void _handleHighlightTapMessage(JavaScriptMessage msg) {
    final id = int.tryParse(msg.message);
    if (id != null) _confirmDeleteHighlight(id);
  }

  Future<void> _confirmDeleteHighlight(int id) async {
    final shouldDelete = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('형광펜 삭제'),
              onTap: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );
    if (shouldDelete != true) return;
    await _webController.runJavaScript('window.__reader.removeHighlight($id);');
    await ref.read(appDatabaseProvider).deleteHighlight(id);
    setState(() => _currentHighlights =
        _currentHighlights.where((h) => h.id != id).toList());
  }

  /// 색상 팝업에서 색을 고르면: DB에 먼저 저장해 id를 발급받고, 그 id로 WebView 안의
  /// 실제 선택 영역을 즉시 하이라이트로 감싼다 (전체 스크립트 재주입 없이 바로 반영).
  Future<void> _createHighlight(int colorValue) async {
    final sel = _activeSelection;
    final bookId = _bookId;
    if (sel == null || bookId == null) return;
    setState(() => _activeSelection = null);

    final newId = await ref.read(appDatabaseProvider).addHighlight(
          bookId: bookId,
          spineIndex: _spineIndex,
          startOffset: sel.start,
          endOffset: sel.end,
          snippet: sel.text,
          colorValue: colorValue,
        );

    setState(() {
      _currentHighlights = [
        ..._currentHighlights,
        HighlightRow(
          id: newId,
          bookId: bookId,
          spineIndex: _spineIndex,
          startOffset: sel.start,
          endOffset: sel.end,
          snippet: sel.text,
          colorValue: colorValue,
          createdAt: DateTime.now(),
        ),
      ];
    });

    final colorCss = _cssColor(colorValue);
    await _webController.runJavaScript(
      'window.__reader.addHighlight($newId, ${sel.start}, ${sel.end}, ${jsonEncode(colorCss)});',
    );
  }

  // ---- 메모 (Phase 6) ----

  /// 메모(밑줄) 영역을 탭했을 때: 내용을 보여주고 수정/삭제할 수 있는 시트를 띄운다.
  void _handleMemoTapMessage(JavaScriptMessage msg) {
    final id = int.tryParse(msg.message);
    if (id == null) return;
    MemoRow? memo;
    for (final m in _currentMemos) {
      if (m.id == id) {
        memo = m;
        break;
      }
    }
    if (memo != null) _openMemoSheet(memo);
  }

  Future<void> _openMemoSheet(MemoRow memo) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"${memo.snippet}"',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Text(memo.content, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop('edit'),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('수정'),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop('delete'),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('삭제'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (action == 'edit') {
      await _editMemo(memo);
    } else if (action == 'delete') {
      await _deleteMemo(memo.id);
    }
  }

  Future<void> _editMemo(MemoRow memo) async {
    final controller = TextEditingController(text: memo.content);
    final newContent = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('메모 수정'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          autofocus: true,
          decoration: const InputDecoration(hintText: '메모 내용을 입력하세요'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (newContent == null || newContent.isEmpty) return;
    await ref.read(appDatabaseProvider).updateMemoContent(memo.id, newContent);
    setState(() {
      _currentMemos = _currentMemos
          .map((m) => m.id == memo.id
              ? MemoRow(
                  id: m.id,
                  bookId: m.bookId,
                  spineIndex: m.spineIndex,
                  startOffset: m.startOffset,
                  endOffset: m.endOffset,
                  snippet: m.snippet,
                  content: newContent,
                  createdAt: m.createdAt,
                  updatedAt: DateTime.now(),
                )
              : m)
          .toList();
    });
  }

  Future<void> _deleteMemo(int id) async {
    await _webController.runJavaScript('window.__reader.removeMemo($id);');
    await ref.read(appDatabaseProvider).deleteMemo(id);
    setState(
        () => _currentMemos = _currentMemos.where((m) => m.id != id).toList());
  }

  /// 선택 툴바에서 "메모" 아이콘을 누르면: 먼저 내용을 입력받고, 그 다음 저장+반영한다.
  Future<void> _createMemo() async {
    final sel = _activeSelection;
    final bookId = _bookId;
    if (sel == null || bookId == null) return;
    setState(() => _activeSelection = null);
    await _webController.runJavaScript('window.__reader.clearSelection();');

    final controller = TextEditingController();
    final content = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('메모 추가'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '"${sel.text}"',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontStyle: FontStyle.italic),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(hintText: '메모 내용을 입력하세요'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (content == null || content.isEmpty) return;

    final newId = await ref.read(appDatabaseProvider).addMemo(
          bookId: bookId,
          spineIndex: _spineIndex,
          startOffset: sel.start,
          endOffset: sel.end,
          snippet: sel.text,
          content: content,
        );

    setState(() {
      _currentMemos = [
        ..._currentMemos,
        MemoRow(
          id: newId,
          bookId: bookId,
          spineIndex: _spineIndex,
          startOffset: sel.start,
          endOffset: sel.end,
          snippet: sel.text,
          content: content,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
    });

    await _webController.runJavaScript(
        'window.__reader.addMemo($newId, ${sel.start}, ${sel.end});');
  }

  // ---- 책갈피 (Phase 6) ----

  /// 현재 읽고 있는 위치를 책갈피로 저장한다.
  Future<void> _addBookmarkHere() async {
    final bookId = _bookId;
    final book = _book;
    if (bookId == null || book == null) return;
    double fraction = 0.0;
    try {
      final raw = await _webController
          .runJavaScriptReturningResult('window.__reader.getFraction()');
      fraction = double.tryParse(raw.toString()) ?? 0.0;
    } catch (_) {
      // WebView가 아직 준비되지 않은 경우 0.0으로 저장.
    }
    await ref.read(appDatabaseProvider).addBookmark(
          bookId: bookId,
          spineIndex: _spineIndex,
          scrollFraction: fraction,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('책갈피에 추가했습니다'), duration: Duration(seconds: 1)),
    );
  }

  /// 이미 로드된 챕터 안이면 바로 스크롤하고, 다른 챕터면 그 챕터로 이동한 뒤
  /// 로딩이 끝나는 대로(_onPageFinished) 스크롤한다.
  Future<void> _jumpToSpan(int spineIndex, String selector) async {
    if (spineIndex == _spineIndex) {
      await _webController.runJavaScript(
          'window.__reader.scrollToSelector(${jsonEncode(selector)});');
      await _refreshPageLabelAndSave();
    } else {
      _pendingElementSelector = selector;
      await _goToSpineIndex(spineIndex, entry: const _PageStart());
    }
  }

  /// 형광펜/메모/책갈피를 한 화면에서 모아 볼 수 있는 "내 노트" 시트.
  void _openNotesSheet({int initialTab = 0}) {
    final bookId = _bookId;
    final book = _book;
    if (bookId == null || book == null) return;
    final db = ref.read(appDatabaseProvider);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => ReaderNotesSheet(
        initialTabIndex: initialTab,
        highlightsStream: db.watchAllHighlights(bookId),
        memosStream: db.watchAllMemos(bookId),
        bookmarksStream: db.watchBookmarks(bookId),
        onSelectHighlight: (highlight) {
          Navigator.of(context).pop();
          _jumpToSpan(highlight.spineIndex,
              '.reader-highlight[data-hl-id="${highlight.id}"]');
        },
        onDeleteHighlight: (id) async {
          await _webController
              .runJavaScript('window.__reader.removeHighlight($id);');
          await db.deleteHighlight(id);
          if (mounted) {
            setState(() => _currentHighlights =
                _currentHighlights.where((h) => h.id != id).toList());
          }
        },
        onSelectMemo: (memo) {
          Navigator.of(context).pop();
          _jumpToSpan(
              memo.spineIndex, '.reader-memo[data-memo-id="${memo.id}"]');
        },
        onEditMemo: (memo) async {
          Navigator.of(context).pop();
          await _editMemo(memo);
        },
        onDeleteMemo: (id) => _deleteMemo(id),
        onSelectBookmark: (bookmark) {
          Navigator.of(context).pop();
          _goToSpineIndex(bookmark.spineIndex,
              entry: _PageFraction(bookmark.scrollFraction));
        },
        onDeleteBookmark: (id) => db.deleteBookmark(id),
      ),
    );
  }

  // ---- 검색 (Phase 7) ----

  Future<void> _openSearch() async {
    final book = _book;
    if (book == null) return;

    final result = await Navigator.of(context).push<SearchResult>(
      MaterialPageRoute(
        builder: (context) => ReaderSearchScreen(
          chapterPaths: [for (final s in book.spine) s.href],
          chapterLabels: [
            for (var i = 0; i < book.spine.length; i++) '${i + 1}장'
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;

    _pendingSearchJump =
        (matchText: result.matchText, occurrenceIndex: result.occurrenceIndex);
    await _goToSpineIndex(result.spineIndex, entry: const _PageStart());
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
  }

  Future<void> _nextPage() async {
    final raw = await _webController
        .runJavaScriptReturningResult('window.__reader.nextPage()');
    final result = _jsString(raw);
    if (result == 'chapter-end') {
      final book = _book;
      if (book != null && _spineIndex < book.spine.length - 1) {
        await _goToSpineIndex(_spineIndex + 1, entry: const _PageStart());
      }
      return;
    }
    await _refreshPageLabelAndSave();
  }

  Future<void> _prevPage() async {
    final raw = await _webController
        .runJavaScriptReturningResult('window.__reader.prevPage()');
    final result = _jsString(raw);
    if (result == 'chapter-start') {
      if (_spineIndex > 0) {
        await _goToSpineIndex(_spineIndex - 1, entry: const _PageEnd());
      }
      return;
    }
    await _refreshPageLabelAndSave();
  }

  Future<void> _goToSpineIndex(int index,
      {_PagePosition entry = const _PageStart()}) async {
    final book = _book;
    if (book == null) return;
    if (index < 0 || index >= book.spine.length) return;
    setState(() => _spineIndex = index);
    _pendingPosition = entry;
    await _loadCurrentChapter();
  }

  Future<void> _refreshPageLabelAndSave() async {
    final labelRaw = await _webController
        .runJavaScriptReturningResult('window.__reader.getPageLabel()');
    final fractionRaw = await _webController
        .runJavaScriptReturningResult('window.__reader.getFraction()');
    final label = _jsString(labelRaw);
    final fraction = double.tryParse(fractionRaw.toString()) ?? 0.0;
    if (mounted) setState(() => _pageLabel = label);
    await _saveProgress(fraction: fraction);
  }

  Future<void> _saveCurrentPosition() async {
    try {
      final fractionRaw = await _webController
          .runJavaScriptReturningResult('window.__reader.getFraction()');
      final fraction = double.tryParse(fractionRaw.toString()) ?? 0.0;
      await _saveProgress(fraction: fraction);
    } catch (_) {
      // 화면 전환 중 WebView가 이미 해제된 경우 등은 조용히 무시.
    }
  }

  Future<void> _saveProgress({required double fraction}) async {
    final bookId = _bookId;
    final book = _book;
    if (bookId == null || book == null) return;
    final safeFraction = fraction.clamp(0.0, 1.0);
    await ref.read(appDatabaseProvider).saveProgress(
          bookId: bookId,
          spineIndex: _spineIndex,
          scrollFraction: safeFraction,
        );
    final overall =
        ((_spineIndex + safeFraction) / book.spine.length).clamp(0.0, 1.0);
    await ref.read(appDatabaseProvider).updateReadingState(
          bookId: bookId,
          overallProgress: overall,
          isAtBookEnd:
              _spineIndex == book.spine.length - 1 && safeFraction >= 0.995,
        );
  }

  // ---- 독서 시간 (Phase 10) ----

  /// 탭/페이지 넘김/텍스트 선택은 사용자가 실제로 읽고 있다는 강한 신호다.
  /// 타이머는 이 신호가 최근에 있었던 시간만 세션에 더하므로, 앱을 켜 둔 채
  /// 자리를 비운 시간은 통계에 들어가지 않는다.
  void _markReadingActivity() {
    _lastReaderInteraction = DateTime.now();
  }

  Future<void> _beginReadingSession({double initialFraction = 0.0}) async {
    final bookId = _bookId;
    if (bookId == null || _readingSessionId != null) return;
    _lastReaderInteraction = DateTime.now();
    _lastReadingTick = DateTime.now();
    _readingSessionId = await ref.read(appDatabaseProvider).startReadingSession(
          bookId: bookId,
          progressStart: initialFraction,
        );
    _readingTimer?.cancel();
    _readingTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _recordActiveReadingTime());
  }

  Future<void> _recordActiveReadingTime() async {
    final sessionId = _readingSessionId;
    final lastTick = _lastReadingTick;
    if (sessionId == null || lastTick == null) return;
    final now = DateTime.now();
    _lastReadingTick = now;
    final lastInteraction = _lastReaderInteraction;
    // 마지막 조작 후 75초까지는 한 페이지를 읽는 시간으로 인정한다.
    if (lastInteraction == null ||
        now.difference(lastInteraction).inSeconds > 75) return;
    try {
      final raw = await _webController
          .runJavaScriptReturningResult('window.__reader.getFraction()');
      final fraction = double.tryParse(raw.toString()) ?? 0.0;
      await ref.read(appDatabaseProvider).addActiveSeconds(
            sessionId: sessionId,
            seconds: now.difference(lastTick).inSeconds,
            progressEnd: fraction,
          );
    } catch (_) {
      // WebView 전환 중이면 다음 주기에 다시 시도한다.
    }
  }

  Future<void> _finishReadingSession() async {
    final sessionId = _readingSessionId;
    if (sessionId == null) return;
    _readingTimer?.cancel();
    await _recordActiveReadingTime();
    _readingSessionId = null;
    try {
      final raw = await _webController
          .runJavaScriptReturningResult('window.__reader.getFraction()');
      final fraction = double.tryParse(raw.toString()) ?? 0.0;
      await ref.read(appDatabaseProvider).finishReadingSession(
            sessionId: sessionId,
            progressEnd: fraction,
          );
    } catch (_) {
      // 종료 시 WebView가 이미 해제됐어도 세션 자체는 남겨 둔다.
    }
  }

  String _jsString(Object? raw) {
    final s = raw.toString();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  void _openTocSheet() {
    final book = _book;
    if (book == null) return;
    final currentHref = book.spine[_spineIndex].href;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => ReaderTocSheet(
        nodes: book.toc,
        currentHref: currentHref,
        onSelect: (href) {
          final cleanHref = href.split('#').first;
          final idx = book.spine.indexWhere((s) => s.href == cleanHref);
          Navigator.of(context).pop();
          if (idx != -1) _goToSpineIndex(idx);
        },
      ),
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 뒤쪽 페이지가 어두워지지 않게 해서, 설정을 조절하면서 바로 반영된 화면을
      // 실시간으로 확인할 수 있게 한다.
      barrierColor: Colors.transparent,
      builder: (context) => ReaderSettingsSheet(
        initial: _settings,
        onChanged: (newSettings) {
          setState(() => _settings = newSettings);
          _applySettingsLive();
          _debounceSaveSettings();
        },
      ),
    );
  }

  /// 설정 시트에서 값이 바뀔 때마다: 스타일 재주입 → 레이아웃이 바뀌었을 수 있으니
  /// 현재 스크롤 위치를 페이지 경계에 맞게 다시 스냅 → 라벨 갱신.
  Future<void> _applySettingsLive() async {
    await _injectReaderScript();
    await _webController.runJavaScript('window.__reader.clampPosition();');
    await _refreshPageLabelAndSave();
  }

  void _debounceSaveSettings() {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = Timer(const Duration(milliseconds: 400), () {
      ref.read(appDatabaseProvider).saveSettings(_settings);
    });
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final selectionToolbar = _buildSelectionToolbar(context);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody(book)),
          if (selectionToolbar != null) selectionToolbar,
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            bottom: (_chromeVisible || book == null) ? 0 : -140,
            left: 0,
            right: 0,
            child: SafeArea(top: false, child: _buildBottomBar(book)),
          ),
        ],
      ),
    );
  }

  /// 텍스트를 드래그로 선택하면 그 위(또는 화면 위쪽에 걸리면 아래)에 뜨는 색상 선택 팝업.
  /// 선택 영역의 뷰포트 좌표(_activeSelection)를 그대로 Positioned 좌표로 쓴다
  /// (뷰포트를 device-width로 고정해뒀으므로 WebView CSS px == Flutter 논리 픽셀).
  Widget? _buildSelectionToolbar(BuildContext context) {
    final sel = _activeSelection;
    if (sel == null) return null;

    final screenSize = MediaQuery.sizeOf(context);
    const toolbarWidth = 284.0;
    const toolbarHeight = 52.0;

    var left = sel.left + sel.width / 2 - toolbarWidth / 2;
    left = left.clamp(
        8.0, (screenSize.width - toolbarWidth - 8).clamp(8.0, double.infinity));

    var top = sel.top - toolbarHeight - 12;
    if (top < 8) {
      // 선택 영역이 화면 맨 위쪽에 걸려있어 위로 띄울 공간이 없으면 아래로 띄운다.
      top = sel.top + sel.height + 12;
    }

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(26),
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final colorValue in _highlightColorValues)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: GestureDetector(
                    onTap: () => _createHighlight(colorValue),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Color(colorValue),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black12),
                      ),
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.edit_note),
                tooltip: '메모',
                onPressed: _createMemo,
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: '취소',
                onPressed: () async {
                  setState(() => _activeSelection = null);
                  await _webController
                      .runJavaScript('window.__reader.clearSelection();');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 뒤로가기/제목/설정("Aa")/목차/현재 페이지 표시를 전부 이 하단바 하나에 모았다.
  /// 화면 중앙을 탭하면 이 바가 나타났다 사라진다 (로딩/에러 중에는 뒤로가기를 위해 항상 표시).
  Widget _buildBottomBar(EpubBook? book) {
    return Material(
      elevation: 2,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    book?.title ?? '읽는 중...',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (book != null)
                  // 아이콘이 많아져도(형광펜/메모/책갈피/검색/설정/목차) 좁은 화면에서
                  // 잘리지 않도록 이 구간만 가로 스크롤 가능하게 둔다.
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.bookmark_add_outlined),
                          tooltip: '책갈피 추가',
                          onPressed: _addBookmarkHere,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.collections_bookmark_outlined),
                          tooltip: '내 노트 (형광펜·메모·책갈피)',
                          onPressed: () => _openNotesSheet(),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.search),
                          tooltip: '검색',
                          onPressed: _openSearch,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.text_fields),
                          tooltip: '읽기 설정',
                          onPressed: _openSettingsSheet,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.list),
                          tooltip: '목차',
                          onPressed: _openTocSheet,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (book != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '${_spineIndex + 1}/${book.spine.length}장 · $_pageLabel',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(EpubBook? book) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text('EPUB을 여는 중 오류가 발생했습니다.\n$_error',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _open, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }
    if (book == null || book.spine.isEmpty) {
      return const Center(child: Text('이 EPUB에는 표시할 챕터가 없습니다.'));
    }

    return WebViewWidget(controller: _webController);
  }
}
