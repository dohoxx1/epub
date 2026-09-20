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

class _SelectionInfo {
  final String text;
  final int start;
  final int end;
  final double left;
  final double top;
  final double width;
  final double height;
  final bool atPageEnd;

  const _SelectionInfo({
    required this.text,
    required this.start,
    required this.end,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.atPageEnd,
  });

  factory _SelectionInfo.fromJson(Map<String, dynamic> j) => _SelectionInfo(
        text: j['text'] as String,
        start: (j['start'] as num).toInt(),
        end: (j['end'] as num).toInt(),
        left: (j['left'] as num).toDouble(),
        top: (j['top'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        atPageEnd: j['atPageEnd'] == true,
      );
}

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

  List<HighlightRow> _currentHighlights = [];
  _SelectionInfo? _activeSelection;
  List<MemoRow> _currentMemos = [];

  ({String matchText, int occurrenceIndex})? _pendingSearchJump;
  String? _pendingElementSelector;

  static const List<int> _highlightColorValues = [
    0xFFFFF59D,
    0xFFC5E1A5,
    0xFFB3E5FC,
    0xFFF8BBD0,
    0xFFFFCC80,
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

  Future<void> _loadCurrentChapter() async {
    final book = _book;
    if (book == null || book.spine.isEmpty) return;
    final chapterPath = book.spine[_spineIndex].href;

    if (_activeSelection != null) setState(() => _activeSelection = null);

    final bookId = _bookId;
    if (bookId == null) {
      _currentHighlights = [];
      _currentMemos = [];
    } else {
      final db = ref.read(appDatabaseProvider);
      _currentHighlights = await db.getHighlights(bookId, _spineIndex);
      _currentMemos = await db.getMemos(bookId, _spineIndex);
    }

    final (bg, _) = _settings.resolvedThemeColors;
    await _webController
        .setBackgroundColor(bg != null ? Color(bg) : Colors.transparent);

    await _webController.loadFile(chapterPath);
  }

  Future<void> _onPageStarted() async {
    try {
      await _injectReaderScript();
    } catch (_) {}
  }

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

  double get _pageWidthPx {
    final width = MediaQuery.sizeOf(context).width;
    return width > 0 ? width : 360.0;
  }

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
        _refreshPageLabelAndSave();
        break;
    }
  }

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
    } catch (_) {}
  }

  void _handleHighlightTapMessage(JavaScriptMessage msg) {
    final id = int.tryParse(msg.message);
    if (id != null) _confirmDeleteHighlight(id);
  }

  Future<void> _confirmDeleteHighlight(int id) async {
    final shouldDelete = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('형광펜 삭제'),
            onTap: () => Navigator.of(context).pop(true),
          ),
        ),
      ),
    );
    if (shouldDelete != true) return;
    await _webController.runJavaScript('window.__reader.removeHighlight($id);');
    await ref.read(appDatabaseProvider).deleteHighlight(id);
    if (mounted) {
      setState(() => _currentHighlights =
          _currentHighlights.where((h) => h.id != id).toList());
    }
  }

  Future<void> _continueHighlightSelection() async {
    final result = await _webController.runJavaScriptReturningResult(
      'window.__reader.continueSelection();',
    );
    if (result.toString().contains('chapter-end')) return;
    if (mounted) setState(() {});
  }

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

    if (!mounted) return;
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
                '“${memo.snippet}”',
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
    if (!mounted) return;
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
    if (mounted) {
      setState(
          () => _currentMemos = _currentMemos.where((m) => m.id != id).toList());
    }
  }

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
              '“${sel.text}”',
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
    if (content == null || content.isEmpty || !mounted) return;

    final newId = await ref.read(appDatabaseProvider).addMemo(
          bookId: bookId,
          spineIndex: _spineIndex,
          startOffset: sel.start,
          endOffset: sel.end,
          snippet: sel.text,
          content: content,
        );

    if (!mounted) return;
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

  Future<void> _addBookmarkHere() async {
    final bookId = _bookId;
    final book = _book;
    if (bookId == null || book == null) return;
    double fraction = 0.0;
    try {
      final raw = await _webController
          .runJavaScriptReturningResult('window.__reader.getFraction()');
      fraction = double.tryParse(raw.toString()) ?? 0.0;
    } catch (_) {}
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
    } catch (_) {}
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
    } catch (_) {}
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
    } catch (_) {}
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

  Future<void> _closeSelection() async {
    if (!mounted) return;
    setState(() => _activeSelection = null);
    await _webController.runJavaScript('window.__reader.clearSelection();');
  }

  void _openReaderMenu() {
    final book = _book;
    if (book == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _readerMenuTile(
                icon: Icons.collections_bookmark_outlined,
                title: '내 노트',
                subtitle: '형광펜 · 메모 · 책갈피',
                onTap: () {
                  Navigator.pop(context);
                  _openNotesSheet();
                },
              ),
              _readerMenuTile(
                icon: Icons.search,
                title: '본문 검색',
                subtitle: '이 책 전체에서 찾기',
                onTap: () {
                  Navigator.pop(context);
                  _openSearch();
                },
              ),
              _readerMenuTile(
                icon: Icons.text_fields,
                title: '읽기 설정',
                subtitle: '글꼴 · 크기 · 줄 간격 · 테마',
                onTap: () {
                  Navigator.pop(context);
                  _openSettingsSheet();
                },
              ),
              _readerMenuTile(
                icon: Icons.list_alt,
                title: '목차',
                subtitle: '챕터로 이동',
                onTap: () {
                  Navigator.pop(context);
                  _openTocSheet();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _readerMenuTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Icon(icon, size: 21),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final selectionToolbar = _buildSelectionToolbar(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody(book)),
          if (selectionToolbar != null) selectionToolbar,
          _buildReaderChrome(book),
        ],
      ),
    );
  }

  Widget _buildReaderChrome(EpubBook? book) {
    final visible = _chromeVisible || book == null;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: visible ? 1 : 0,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: _buildTopChrome(book),
                ),
              ),
            ),
            if (book != null)
              Positioned(
                left: 18,
                right: 18,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildBottomChrome(book),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopChrome(EpubBook? book) {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            spreadRadius: -8,
            color: Colors.black.withValues(alpha: 0.20),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '서재로',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book?.title ?? '읽는 중…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                  ),
                  if (book != null)
                    Text(
                      '${_spineIndex + 1}장  ·  $_pageLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
          ),
          if (book != null)
            IconButton(
              tooltip: '현재 위치 책갈피',
              onPressed: _addBookmarkHere,
              icon: const Icon(Icons.bookmark_border_rounded),
            ),
          IconButton(
            tooltip: '읽기 메뉴',
            onPressed: _openReaderMenu,
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomChrome(EpubBook book) {
    final overall = ((_spineIndex + 0.0) / book.spine.length).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            spreadRadius: -8,
            color: Colors.black.withValues(alpha: 0.20),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '${_spineIndex + 1}장',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value: overall,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: 0.35),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _pageLabel,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '내 노트',
                visualDensity: VisualDensity.compact,
                onPressed: () => _openNotesSheet(),
                icon: const Icon(Icons.collections_bookmark_outlined),
              ),
              IconButton(
                tooltip: '검색',
                visualDensity: VisualDensity.compact,
                onPressed: _openSearch,
                icon: const Icon(Icons.search_rounded),
              ),
              IconButton(
                tooltip: '읽기 설정',
                visualDensity: VisualDensity.compact,
                onPressed: _openSettingsSheet,
                icon: const Icon(Icons.text_fields_rounded),
              ),
              IconButton(
                tooltip: '목차',
                visualDensity: VisualDensity.compact,
                onPressed: _openTocSheet,
                icon: const Icon(Icons.menu_book_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget? _buildSelectionToolbar(BuildContext context) {
    final sel = _activeSelection;
    if (sel == null) return null;

    final screenSize = MediaQuery.sizeOf(context);
    const toolbarWidth = 276.0;
    const toolbarHeight = 54.0;

    var left = sel.left + sel.width / 2 - toolbarWidth / 2;
    left = left.clamp(10.0, (screenSize.width - toolbarWidth - 10).clamp(10.0, double.infinity));

    var top = sel.top - toolbarHeight - 14;
    if (top < 12) top = sel.top + sel.height + 14;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(17),
        child: Container(
          height: toolbarHeight,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sel.atPageEnd)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: TextButton.icon(
                    onPressed: _continueHighlightSelection,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('다음 페이지 이어서 칠하기'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                    ),
                  ),
                ),
              for (final colorValue in _highlightColorValues)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () => _createHighlight(colorValue),
                    child: Container(
                      width: 25,
                      height: 25,
                      decoration: BoxDecoration(
                        color: Color(colorValue),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black12),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 2),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '메모',
                onPressed: _createMemo,
                icon: const Icon(Icons.edit_note_rounded),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '선택 취소',
                onPressed: _closeSelection,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
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
              const Icon(Icons.error_outline, size: 48),
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
