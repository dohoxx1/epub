import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database/app_database.dart';
import '../services/epub_repository.dart';
import '../services/library_scan_service.dart';
import 'reader_screen.dart';
import 'reading_calendar_screen.dart';
import 'reading_stats_screen.dart';

/// Personal bookshelf.
///
/// The library intentionally uses a snapshot rather than several nested live
/// Drift streams. Reading activity can update frequently; the bookshelf only
/// needs a refresh after an explicit action or after returning from the reader.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late final LibraryScanService _scanner;
  final _search = TextEditingController();

  List<LibraryBookRow> _books = const [];
  List<ShelfRow> _shelves = const [];
  List<TagRow> _tags = const [];
  List<LibraryFolderRow> _folders = const [];
  Map<int, ReadingProgressRow> _progress = const {};
  Map<int, BookReadingStateRow> _states = const {};

  bool _grid = true;
  bool _searching = false;
  bool _loading = true;
  bool _busy = false;
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

  Future<void> _refresh({bool showLoading = false}) async {
    if (showLoading && mounted) setState(() => _loading = true);
    final db = ref.read(appDatabaseProvider);
    try {
      final bookFuture = _shelfId != null
          ? db.watchBooksInShelf(_shelfId!).first
          : _tagId != null
              ? db.watchBooksWithTag(_tagId!).first
              : db.watchAllBooks().first;

      // These are independent, read-only snapshots. Unlike StreamBuilders,
      // they do not keep the whole library subscribed to every DB mutation.
      final results = await Future.wait<dynamic>([
        bookFuture,
        db.watchAllProgress().first,
        db.watchReadingStates().first,
        db.watchShelves().first,
        db.watchTags().first,
        db.watchFolders().first,
      ]);

      if (!mounted) return;
      setState(() {
        _books = results[0] as List<LibraryBookRow>;
        _progress = {
          for (final row in results[1] as List<ReadingProgressRow>)
            row.bookId: row,
        };
        _states = {
          for (final row in results[2] as List<BookReadingStateRow>)
            row.bookId: row,
        };
        _shelves = results[3] as List<ShelfRow>;
        _tags = results[4] as List<TagRow>;
        _folders = results[5] as List<LibraryFolderRow>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('서재를 불러오지 못했습니다: $e')),
      );
    }
  }

  List<LibraryBookRow> get _visibleBooks {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _books;
    return _books
        .where((book) =>
            book.title.toLowerCase().contains(q) ||
            (book.author ?? '').toLowerCase().contains(q))
        .toList(growable: false);
  }

  double _progress(ReadingProgressRow? row) =>
      row?.scrollFraction.clamp(0.0, 1.0) ?? 0.0;

  Future<void> _open(String path) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderScreen(epubPath: path)),
      );
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );
    final path = result?.files.single.path;
    if (path != null && mounted) await _open(path);
  }

  Future<void> _addFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'EPUB이 들어있는 폴더 선택',
    );
    if (!mounted || path == null) return;
    final db = ref.read(appDatabaseProvider);
    final id = await db.addFolderIfNew(path);
    await _scanFolder(id, path);
  }

  Future<void> _scanFolder(int id, String path) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _scanner.scanFolder(path);
      await ref.read(appDatabaseProvider).markFolderScanned(id);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${result.added}권을 서재에 추가했습니다.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('폴더를 스캔하지 못했습니다: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            const ListTile(
              title: Text('책 추가', style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text('원본 EPUB 파일은 이동하거나 복사하지 않습니다.'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('폴더에서 가져오기'),
              subtitle: const Text('폴더 안의 EPUB을 한 번에 등록'),
              onTap: () => Navigator.pop(sheetContext, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('EPUB 파일 열기'),
              subtitle: const Text('파일 하나를 바로 읽기'),
              onTap: () => Navigator.pop(sheetContext, 'file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'folder') await _addFolder();
    if (choice == 'file') await _addFile();
  }

  @override
  Widget build(BuildContext context) {
    final books = _visibleBooks;
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '제목 또는 작가 검색',
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _query = value),
              )
            : const Text('내 서재', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? '검색 닫기' : '책 검색',
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _query = '';
                  _search.clear();
                }
              });
            },
          ),
          IconButton(
            icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
            tooltip: '보기 전환',
            onPressed: () => setState(() => _grid = !_grid),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'calendar':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingCalendarScreen()));
                case 'stats':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingStatsScreen()));
                case 'tags':
                  _tagSheet();
                case 'folders':
                  _folderSheet();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'calendar', child: Text('독서 캘린더')),
              PopupMenuItem(value: 'stats', child: Text('독서 통계')),
              PopupMenuItem(value: 'tags', child: Text('태그 필터')),
              PopupMenuItem(value: 'folders', child: Text('서재 폴더')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addMenu,
        icon: const Icon(Icons.add),
        label: const Text('책 추가'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _header()),
                  if (_query.isEmpty && _shelfId == null && _tagId == null)
                    ..._continueReading(),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
                      child: Text(
                        '책 ${books.length}',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  if (books.isEmpty)
                    SliverFillRemaining(hasScrollBody: false, child: _empty())
                  else if (_grid)
                    _gridSliver(books)
                  else
                    _listSliver(books),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _shelfId == null && _tagId == null ? '전체 책' : '필터 결과',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (_shelfId != null || _tagId != null)
                TextButton(
                  onPressed: () async {
                    setState(() {
                      _shelfId = null;
                      _tagId = null;
                    });
                    await _refresh(showLoading: true);
                  },
                  child: const Text('해제'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip('전체', _shelfId == null && _tagId == null, () async {
                  setState(() {
                    _shelfId = null;
                    _tagId = null;
                  });
                  await _refresh(showLoading: true);
                }),
                for (final shelf in _shelves) ...[
                  const SizedBox(width: 8),
                  _chip(shelf.name, _shelfId == shelf.id, () async {
                    setState(() {
                      _shelfId = shelf.id;
                      _tagId = null;
                    });
                    await _refresh(showLoading: true);
                  }),
                ],
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 17),
                  label: const Text('책장'),
                  onPressed: _newShelf,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, bool selected, VoidCallback tap) =>
      FilterChip(label: Text(text), selected: selected, onSelected: (_) => tap());

  List<Widget> _continueReading() {
    final reading = _books
        .where((book) => _progress(_progress[book.id]) > 0)
        .take(6)
        .toList(growable: false);
    if (reading.isEmpty) return const [];
    return [
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 22, 20, 10),
          child: Text('계속 읽기', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 176,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: reading.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final book = reading[index];
              final value = _progress(_progress[book.id]);
              return SizedBox(
                width: 280,
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _open(book.originalUri),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox(width: 92, height: 140, child: _cover(book, 10, 92)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(book.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, height: 1.2)),
                                const SizedBox(height: 8),
                                Text(book.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                                const SizedBox(height: 16),
                                LinearProgressIndicator(value: value, minHeight: 5, borderRadius: BorderRadius.circular(5)),
                                const SizedBox(height: 6),
                                Text('${(value * 100).round()}% 읽음', style: Theme.of(context).textTheme.labelSmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ];
  }

  Widget _gridSliver(List<LibraryBookRow> books) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) => _gridBook(books[index]),
          childCount: books.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisExtent: 284,
          crossAxisSpacing: 18,
          mainAxisSpacing: 22,
        ),
      ),
    );
  }

  Widget _listSliver(List<LibraryBookRow> books) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (_, index) => _listBook(books[index]),
        childCount: books.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
      ),
    );
  }

  String _label(ReadingProgressRow? progress, BookReadingStateRow? state) {
    final percent = (_progress(progress) * 100).round();
    if (state?.completedAt != null) return '완독 · $percent%';
    if (percent == 0) return '읽지 않음';
    return '읽는 중 · $percent%';
  }

  Widget _gridBook(LibraryBookRow book) {
    final progress = _progress[_bookKey(book)];
    final state = _states[_bookKey(book)];
    final value = _progress(progress);
    return GestureDetector(
      onTap: () => _open(book.originalUri),
      onLongPress: () => _bookSheet(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _cover(book, 14, 190)),
                if (value > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
                      child: LinearProgressIndicator(value: value, minHeight: 5),
                    ),
                  ),
                if (state?.completedAt != null)
                  Positioned(top: 8, right: 8, child: _badge(Icons.check, '완독')),
              ],
            ),
          ),
          const SizedBox(height: 9),
          Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, height: 1.2)),
          const SizedBox(height: 3),
          Text(book.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 3),
          Text(_label(progress, state), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }

  int _bookKey(LibraryBookRow book) => book.id;

  Widget _listBook(LibraryBookRow book) {
    final progress = _progress[_bookKey(book)];
    final state = _states[_bookKey(book)];
    final value = _progress(progress);
    return InkWell(
      onTap: () => _open(book.originalUri),
      onLongPress: () => _bookSheet(book),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            SizedBox(width: 58, height: 82, child: _cover(book, 9, 58)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text(book.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 9),
                  LinearProgressIndicator(value: value, minHeight: 4, borderRadius: BorderRadius.circular(4)),
                  const SizedBox(height: 4),
                  Text(_label(progress, state), style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
            IconButton(icon: const Icon(Icons.more_horiz), onPressed: () => _bookSheet(book)),
          ],
        ),
      ),
    );
  }

  Widget _cover(LibraryBookRow book, double radius, double logicalWidth) {
    final path = book.coverImagePath;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (logicalWidth * dpr).round().clamp(96, 768);
    final image = path == null
        ? _coverFallback()
        : Image.file(
            File(path),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            cacheWidth: cacheWidth,
            errorBuilder: (_, __, ___) => _coverFallback(),
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SizedBox.expand(child: image),
      ),
    );
  }

  Widget _coverFallback() => Center(
        child: Icon(Icons.menu_book_outlined, size: 30, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );

  Widget _badge(IconData icon, String text) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: .94),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14), const SizedBox(width: 3), Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800))]),
        ),
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_query.isEmpty ? Icons.menu_book_outlined : Icons.search_off, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 14),
              Text(_query.isEmpty ? '아직 책이 없습니다' : '검색 결과가 없습니다', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(_query.isEmpty ? '책 추가에서 폴더나 EPUB 파일을 등록하세요.' : '다른 제목이나 작가 이름으로 검색해보세요.', textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Future<void> _newShelf() async {
    final controller = TextEditingController();
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('책장 추가', style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(hintText: '예: 읽는 중, 완독, 소설'),
              onSubmitted: (value) => Navigator.of(sheetContext).pop(value.trim()),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(sheetContext).pop(), child: const Text('취소')),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => Navigator.of(sheetContext).pop(controller.text.trim()), child: const Text('추가')),
              ],
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    await ref.read(appDatabaseProvider).addShelf(name);
    await _refresh();
  }

  void _tagSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _tags.isEmpty
              ? const Text('태그가 없습니다. 책 메뉴에서 추가할 수 있습니다.')
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in _tags)
                      FilterChip(
                        label: Text('#${tag.name}'),
                        selected: _tagId == tag.id,
                        onSelected: (_) async {
                          Navigator.pop(sheetContext);
                          setState(() {
                            _tagId = tag.id;
                            _shelfId = null;
                          });
                          await _refresh(showLoading: true);
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  void _folderSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .62,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Text('서재 폴더', style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _addFolder();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('추가'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _folders.isEmpty
                  ? const Center(child: Text('지정된 폴더가 없습니다.'))
                  : ListView.separated(
                      itemCount: _folders.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final folder = _folders[index];
                        return ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(folder.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(folder.lastScannedAt == null ? '스캔하지 않음' : '마지막 스캔 ${folder.lastScannedAt}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(icon: const Icon(Icons.refresh), onPressed: () => _scanFolder(folder.id, folder.path)),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  await ref.read(appDatabaseProvider).removeFolder(folder.id);
                                  if (mounted) {
                                    Navigator.pop(sheetContext);
                                    await _refresh();
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _bookSheet(LibraryBookRow book) async {
    final db = ref.read(appDatabaseProvider);
    final current = await db.watchShelfIdsForBook(book.id).first;
    final tags = await db.watchTagsForBook(book.id).first;
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            Row(
              children: [
                SizedBox(width: 58, height: 82, child: _cover(book, 9, 58)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      const SizedBox(height: 4),
                      Text(book.author ?? '작가 미상'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text('책장', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final shelf in _shelves)
                  FilterChip(
                    label: Text(shelf.name),
                    selected: current.contains(shelf.id),
                    onSelected: (value) async {
                      await db.setBookInShelf(book.id, shelf.id, value);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 22),
            const Text('태그', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (tags.isEmpty) const Text('태그가 없습니다.') else Wrap(
              spacing: 8,
              children: [
                for (final tag in tags)
                  InputChip(
                    label: Text('#${tag.name}'),
                    onDeleted: () => db.setBookTag(book.id, tag.id, false),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            FilledButton.tonalIcon(
              onPressed: () => _removeBook(book),
              icon: const Icon(Icons.delete_outline),
              label: const Text('서재에서 제거'),
            ),
          ],
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _removeBook(LibraryBookRow book) async {
    Navigator.pop(context);
    await ref.read(appDatabaseProvider).removeBook(book.id);
    await _refresh();
  }
}
