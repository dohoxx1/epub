import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/android_saf_service.dart';
import '../services/database/app_database.dart';
import '../services/epub_repository.dart';
import '../services/library_scan_service.dart';
import 'reader_screen.dart';
import 'reading_calendar_screen.dart';
import 'reading_stats_screen.dart';

class RedesignedLibraryScreen extends ConsumerStatefulWidget {
  const RedesignedLibraryScreen({super.key});

  @override
  ConsumerState<RedesignedLibraryScreen> createState() => _RedesignedLibraryScreenState();
}

class _RedesignedLibraryScreenState extends ConsumerState<RedesignedLibraryScreen> {
  late final LibraryScanService _scanner;
  final _search = TextEditingController();
  final _repo = EpubRepository();

  List<LibraryBookRow> _books = const [];
  List<ShelfRow> _shelves = const [];
  List<TagRow> _tags = const [];
  List<LibraryFolderRow> _folders = const [];
  Map<int, ReadingProgressRow> _progress = const {};
  Map<int, BookReadingStateRow> _states = const {};
  final Map<int, int> _spineCounts = {};
  final Set<int> _spineLoading = {};

  bool _loading = true;
  bool _busy = false;
  bool _searching = false;
  int? _shelfId;
  int? _tagId;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final db = ref.read(appDatabaseProvider);
    _scanner = LibraryScanService(EpubRepository(), db);
    _refresh();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool loading = false}) async {
    if (loading && mounted) setState(() => _loading = true);
    final db = ref.read(appDatabaseProvider);
    try {
      final books = _shelfId != null
          ? db.watchBooksInShelf(_shelfId!).first
          : _tagId != null
              ? db.watchBooksWithTag(_tagId!).first
              : db.watchAllBooks().first;
      final result = await Future.wait<dynamic>([
        books,
        db.watchAllProgress().first,
        db.watchReadingStates().first,
        db.watchShelves().first,
        db.watchTags().first,
        db.watchFolders().first,
      ]);
      if (!mounted) return;
      setState(() {
        _books = result[0] as List<LibraryBookRow>;
        _progress = {for (final p in result[1] as List<ReadingProgressRow>) p.bookId: p};
        _states = {for (final s in result[2] as List<BookReadingStateRow>) s.bookId: s};
        _shelves = result[3] as List<ShelfRow>;
        _tags = result[4] as List<TagRow>;
        _folders = result[5] as List<LibraryFolderRow>;
        _loading = false;
      });
      _warmSpineCounts();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('서재를 불러오지 못했습니다: $e')));
    }
  }

  Future<void> _warmSpineCounts() async {
    final targets = _books.where((b) => _progress[b.id] != null).take(24).toList(growable: false);
    for (final book in targets) {
      if (_spineCounts.containsKey(book.id) || _spineLoading.contains(book.id)) continue;
      _spineLoading.add(book.id);
      try {
        final epub = await _repo.openBook(book.originalUri);
        if (mounted && epub.spine.isNotEmpty) {
          setState(() => _spineCounts[book.id] = epub.spine.length);
        }
      } catch (_) {
      } finally {
        _spineLoading.remove(book.id);
      }
    }
  }

  double _value(LibraryBookRow book) {
    final p = _progress[book.id];
    if (p == null) return 0;
    final count = _spineCounts[book.id];
    if (count == null || count <= 0) return p.scrollFraction.clamp(0.0, 1.0);
    return ((p.spineIndex + p.scrollFraction) / count).clamp(0.0, 1.0);
  }

  LibraryBookRow? get _lastRead {
    LibraryBookRow? result;
    DateTime? latest;
    for (final book in _books) {
      final date = _states[book.id]?.lastReadAt;
      if (date != null && (latest == null || date.isAfter(latest))) {
        latest = date;
        result = book;
      }
    }
    return result;
  }

  List<LibraryBookRow> get _visibleBooks {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _books;
    return _books.where((b) => b.title.toLowerCase().contains(q) || (b.author ?? '').toLowerCase().contains(q)).toList(growable: false);
  }

  Future<void> _open(String path) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(epubPath: path)));
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFile() async {
    if (_busy) return;
    final uri = await AndroidSafService.pickEpubFile();
    if (!mounted || uri == null) return;
    await _open(uri);
  }

  Future<void> _addFolder() async {
    if (_busy) return;
    final uri = await AndroidSafService.pickFolder();
    if (!mounted || uri == null) return;
    final db = ref.read(appDatabaseProvider);
    final id = await db.addFolderIfNew(uri);
    await _scanFolder(id, uri);
  }

  Future<void> _scanFolder(int id, String path) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _scanner.scanFolder(path);
      await ref.read(appDatabaseProvider).markFolderScanned(id);
      await _refresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result.added}권을 서재에 추가했습니다.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('폴더를 스캔하지 못했습니다: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _importSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(leading: const Icon(Icons.menu_book_outlined), title: const Text('파일 추가'), subtitle: const Text('EPUB 한 권 선택'), onTap: () { Navigator.pop(ctx); _addFile(); }),
            ListTile(leading: const Icon(Icons.folder_outlined), title: const Text('폴더 추가'), subtitle: const Text('폴더 안의 EPUB을 모두 가져오기'), onTap: () { Navigator.pop(ctx); _addFolder(); }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final books = _visibleBooks;
    final last = _lastRead;
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(controller: _search, autofocus: true, decoration: const InputDecoration(hintText: '제목 또는 작가 검색', border: InputBorder.none), onChanged: (v) => setState(() => _query = v))
            : const Text('내 서재'),
        actions: [
          IconButton(icon: Icon(_searching ? Icons.close : Icons.search), onPressed: () => setState(() { _searching = !_searching; if (!_searching) { _query = ''; _search.clear(); } })),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'calendar': Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingCalendarScreen()));
                case 'stats': Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingStatsScreen()));
                case 'folders': _folderSheet();
                case 'tags': _tagSheet();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'calendar', child: Text('독서 캘린더')),
              PopupMenuItem(value: 'stats', child: Text('독서 통계')),
              PopupMenuItem(value: 'folders', child: Text('서재 폴더')),
              PopupMenuItem(value: 'tags', child: Text('태그 필터')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _busy ? null : _importSheet, icon: const Icon(Icons.add), label: const Text('책 추가')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _header()),
                  if (_query.isEmpty && _shelfId == null && _tagId == null && last != null) SliverToBoxAdapter(child: _continueCard(last)),
                  SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 12), child: Text('책 ${books.length}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)))),
                  if (books.isEmpty)
                    SliverFillRemaining(hasScrollBody: false, child: _empty())
                  else
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverGrid(
                        delegate: SliverChildBuilderDelegate((_, i) => _bookCard(books[i]), childCount: books.length, addAutomaticKeepAlives: false, addRepaintBoundaries: true),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 12, mainAxisSpacing: 22, childAspectRatio: .50),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _chip('전체', _shelfId == null && _tagId == null, () async { setState(() { _shelfId = null; _tagId = null; }); await _refresh(loading: true); }),
            for (final shelf in _shelves) ...[
              const SizedBox(width: 8),
              _chip(shelf.name, _shelfId == shelf.id, () async { setState(() { _shelfId = shelf.id; _tagId = null; }); await _refresh(loading: true); }),
            ],
            const SizedBox(width: 8),
            ActionChip(avatar: const Icon(Icons.add, size: 16), label: const Text('책장'), onPressed: _newShelf),
          ]),
        ),
      );

  Widget _chip(String text, bool selected, VoidCallback onTap) => FilterChip(label: Text(text), selected: selected, onSelected: (_) => onTap());

  Widget _continueCard(LibraryBookRow book) {
    final value = _value(book);
    return Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 0), child: Material(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .5), borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => _open(book.originalUri), child: SizedBox(height: 82, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), child: Row(children: [SizedBox(width: 43, height: 64, child: _cover(book, 7, 43)), const SizedBox(width: 12), Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text('계속 읽기', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)), const SizedBox(height: 2), Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 7), ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: value, minHeight: 3))])), const SizedBox(width: 10), Text('${(value * 100).round()}%', style: Theme.of(context).textTheme.labelSmall), const SizedBox(width: 2), const Icon(Icons.chevron_right, size: 20)]))))));
  }

  Widget _bookCard(LibraryBookRow book) {
    final value = _value(book);
    final state = _states[book.id];
    return GestureDetector(onTap: () => _open(book.originalUri), onLongPress: () => _bookSheet(book), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Stack(children: [Positioned.fill(child: _cover(book, 9, 108)), if (value > 0) Positioned(left: 0, right: 0, bottom: 0, child: ClipRRect(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(9)), child: LinearProgressIndicator(value: value, minHeight: 3))), if (state?.completedAt != null) const Positioned(top: 6, right: 6, child: Icon(Icons.check_circle, size: 19))])), const SizedBox(height: 7), Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, height: 1.15)), const SizedBox(height: 2), Text(book.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall)]));
  }

  Widget _cover(LibraryBookRow book, double radius, double width) {
    final path = book.coverImagePath;
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round().clamp(72, 512);
    final image = path == null ? _coverFallback() : Image.file(File(path), fit: BoxFit.cover, cacheWidth: cacheWidth, filterQuality: FilterQuality.low, errorBuilder: (_, __, ___) => _coverFallback());
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: SizedBox.expand(child: image)));
  }

  Widget _coverFallback() => Center(child: Icon(Icons.menu_book_outlined, size: 24, color: Theme.of(context).colorScheme.onSurfaceVariant));

  Widget _empty() => Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_query.isEmpty ? '아직 책이 없습니다.\n책 추가에서 EPUB 파일 또는 폴더를 등록하세요.' : '검색 결과가 없습니다.', textAlign: TextAlign.center)));

  Future<void> _newShelf() async {
    final c = TextEditingController();
    final name = await showModalBottomSheet<String>(context: context, isScrollControlled: true, showDragHandle: true, builder: (ctx) => Padding(padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom), child: Column(mainAxisSize: MainAxisSize.min, children: [Text('책장 추가', style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)), const SizedBox(height: 14), TextField(controller: c, textInputAction: TextInputAction.done, decoration: const InputDecoration(hintText: '예: 읽는 중, 완독, 소설'), onSubmitted: (v) => Navigator.pop(ctx, v.trim())), const SizedBox(height: 12), Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('추가')))])));
    c.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    await ref.read(appDatabaseProvider).addShelf(name);
    await _refresh();
  }

  void _tagSheet() {
    showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Wrap(spacing: 8, runSpacing: 8, children: [for (final tag in _tags) FilterChip(label: Text('#${tag.name}'), selected: _tagId == tag.id, onSelected: (_) async { Navigator.pop(ctx); setState(() { _tagId = tag.id; _shelfId = null; }); await _refresh(loading: true); })]))));
  }

  void _folderSheet() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * .6, child: ListView(children: [Padding(padding: const EdgeInsets.fromLTRB(20, 0, 12, 8), child: Row(children: [Text('서재 폴더', style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)), const Spacer(), TextButton(onPressed: () { Navigator.pop(ctx); _addFolder(); }, child: const Text('추가'))])), const Divider(height: 1), for (final f in _folders) ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(f.lastScannedAt == null ? '스캔하지 않음' : '스캔 완료'), trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: () => _scanFolder(f.id, f.path)))])));
  }

  Future<void> _bookSheet(LibraryBookRow book) async {
    final db = ref.read(appDatabaseProvider);
    final shelves = await db.watchShelfIdsForBook(book.id).first;
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (ctx) => SafeArea(child: ListView(padding: const EdgeInsets.all(20), shrinkWrap: true, children: [Row(children: [SizedBox(width: 50, height: 72, child: _cover(book, 7, 50)), const SizedBox(width: 12), Expanded(child: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)))]), const SizedBox(height: 20), const Text('책장', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)), const SizedBox(height: 8), Wrap(spacing: 8, children: [for (final shelf in _shelves) FilterChip(label: Text(shelf.name), selected: shelves.contains(shelf.id), onSelected: (v) => db.setBookInShelf(book.id, shelf.id, v))]), const SizedBox(height: 20), FilledButton.tonalIcon(onPressed: () async { Navigator.pop(ctx); await db.removeBook(book.id); await _refresh(); }, icon: const Icon(Icons.delete_outline), label: const Text('서재에서 제거'))])));
    await _refresh();
  }
}
