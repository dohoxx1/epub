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

/// Personal bookshelf. EPUB source files always remain at their original paths.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late final Stream<List<LibraryBookRow>> _allBooks;
  late final Stream<List<LibraryFolderRow>> _folders;
  late final Stream<List<ShelfRow>> _shelves;
  late final Stream<List<TagRow>> _tags;
  late final LibraryScanService _scanner;

  bool _grid = true;
  bool _searching = false;
  bool _busy = false;
  int? _shelfId;
  int? _tagId;
  String _query = '';
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    final db = ref.read(appDatabaseProvider);
    _allBooks = db.watchAllBooks();
    _folders = db.watchFolders();
    _shelves = db.watchShelves();
    _tags = db.watchTags();
    _scanner = LibraryScanService(EpubRepository(), db);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Stream<List<LibraryBookRow>> get _visibleBooks {
    if (_shelfId != null) {
      return ref.read(appDatabaseProvider).watchBooksInShelf(_shelfId!);
    }
    if (_tagId != null) {
      return ref.read(appDatabaseProvider).watchBooksWithTag(_tagId!);
    }
    return _allBooks;
  }

  Future<void> _open(String path) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderScreen(epubPath: path)),
      );
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

  Future<void> _scanFolder(int id, String path) async {
    setState(() => _busy = true);
    try {
      final result = await _scanner.scanFolder(path);
      await ref.read(appDatabaseProvider).markFolderScanned(id);
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

  Future<void> _addFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'EPUB이 들어있는 폴더 선택',
    );
    if (!mounted || path == null) return;
    final id = await ref.read(appDatabaseProvider).addFolderIfNew(path);
    if (mounted) await _scanFolder(id, path);
  }

  Future<void> _addMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            const ListTile(
              title: Text(
                '책 추가',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text('원본 EPUB 파일은 이동하거나 복사하지 않습니다.'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('폴더에서 가져오기'),
              subtitle: const Text('폴더 안의 EPUB을 한 번에 등록'),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('EPUB 파일 열기'),
              subtitle: const Text('파일 하나를 바로 읽기'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (choice == 'folder') await _addFolder();
    if (choice == 'file') await _addFile();
  }

  double _progress(ReadingProgressRow? progress) {
    if (progress == null) return 0;
    return progress.scrollFraction.clamp(0.0, 1.0);
  }

  String _label(
    ReadingProgressRow? progress,
    BookReadingStateRow? state,
    int seconds,
  ) {
    final percent = (_progress(progress) * 100).round();
    if (state?.completedAt != null) return '완독 · $percent%';
    if (percent == 0) {
      return seconds > 0 ? '읽음 · ${seconds ~/ 60}분' : '읽지 않음';
    }
    return '읽는 중 · $percent%';
  }

  List<LibraryBookRow> _searchBooks(List<LibraryBookRow> books) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return books;
    return books
        .where(
          (book) =>
              book.title.toLowerCase().contains(q) ||
              (book.author ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(appDatabaseProvider);

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
            : const Text(
                '내 서재',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
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
            icon: Icon(
              _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
            ),
            tooltip: '보기 전환',
            onPressed: () => setState(() => _grid = !_grid),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'calendar') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ReadingCalendarScreen(),
                  ),
                );
              }
              if (value == 'stats') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ReadingStatsScreen(),
                  ),
                );
              }
              if (value == 'tags') _tagSheet();
              if (value == 'folders') _folderSheet();
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
      body: StreamBuilder<List<ShelfRow>>(
        stream: _shelves,
        builder: (context, shelfSnap) => StreamBuilder<List<LibraryBookRow>>(
          stream: _visibleBooks,
          builder: (context, bookSnap) {
            if (!bookSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final books = _searchBooks(bookSnap.data!);
            return StreamBuilder<List<ReadingProgressRow>>(
              stream: db.watchAllProgress(),
              builder: (context, progressSnap) =>
                  StreamBuilder<List<BookReadingStateRow>>(
                stream: db.watchReadingStates(),
                builder: (context, stateSnap) =>
                    StreamBuilder<List<ReadingSessionRow>>(
                  stream: db.watchAllReadingSessions(),
                  builder: (context, sessionSnap) {
                    final progress = {
                      for (final x
                          in progressSnap.data ??
                              const <ReadingProgressRow>[])
                        x.bookId: x,
                    };
                    final states = {
                      for (final x
                          in stateSnap.data ??
                              const <BookReadingStateRow>[])
                        x.bookId: x,
                    };
                    final seconds = <int, int>{};
                    for (final x
                        in sessionSnap.data ?? const <ReadingSessionRow>[]) {
                      seconds[x.bookId] =
                          (seconds[x.bookId] ?? 0) + x.activeSeconds;
                    }

                    return CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: _header(shelfSnap.data ?? const []),
                        ),
                        if (_query.isEmpty &&
                            _shelfId == null &&
                            _tagId == null)
                          ..._continueReading(bookSnap.data!, progress),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
                            child: Text(
                              '책 ${books.length}',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                        if (books.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _empty(),
                          )
                        else if (_grid)
                          _gridSliver(books, progress, states, seconds)
                        else
                          _listSliver(books, progress, states, seconds),
                        const SliverToBoxAdapter(
                          child: SizedBox(height: 100),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header(List<ShelfRow> shelves) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _shelfId == null && _tagId == null ? '전체 책' : '필터 결과',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (_shelfId != null || _tagId != null)
                TextButton(
                  onPressed: () => setState(() {
                    _shelfId = null;
                    _tagId = null;
                  }),
                  child: const Text('해제'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip(
                  '전체',
                  _shelfId == null && _tagId == null,
                  () => setState(() {
                    _shelfId = null;
                    _tagId = null;
                  }),
                ),
                for (final shelf in shelves) ...[
                  const SizedBox(width: 8),
                  _chip(
                    shelf.name,
                    _shelfId == shelf.id,
                    () => setState(() {
                      _shelfId = shelf.id;
                      _tagId = null;
                    }),
                  ),
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

  Widget _chip(String text, bool selected, VoidCallback tap) {
    return FilterChip(
      label: Text(text),
      selected: selected,
      onSelected: (_) => tap(),
    );
  }

  List<Widget> _continueReading(
    List<LibraryBookRow> books,
    Map<int, ReadingProgressRow> progress,
  ) {
    final reading = books
        .where((book) => _progress(progress[book.id]) > 0)
        .take(6)
        .toList();
    if (reading.isEmpty) return const [];

    return [
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 22, 20, 10),
          child: Text(
            '계속 읽기',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
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
              final value = _progress(progress[book.id]);
              return SizedBox(
                width: 280,
                child: Material(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _open(book.originalUri),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 92,
                            height: 140,
                            child: _cover(book, 10),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  book.title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    height: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  book.author ?? '작가 미상',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 16),
                                LinearProgressIndicator(
                                  value: value,
                                  minHeight: 5,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${(value * 100).round()}% 읽음',
                                  style:
                                      Theme.of(context).textTheme.labelSmall,
                                ),
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

  Widget _gridSliver(
    List<LibraryBookRow> books,
    Map<int, ReadingProgressRow> progress,
    Map<int, BookReadingStateRow> states,
    Map<int, int> seconds,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, index) {
            final book = books[index];
            return _gridBook(
              book,
              progress[book.id],
              states[book.id],
              seconds[book.id] ?? 0,
            );
          },
          childCount: books.length,
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

  Widget _listSliver(
    List<LibraryBookRow> books,
    Map<int, ReadingProgressRow> progress,
    Map<int, BookReadingStateRow> states,
    Map<int, int> seconds,
  ) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (_, index) {
          final book = books[index];
          return _listBook(
            book,
            progress[book.id],
            states[book.id],
            seconds[book.id] ?? 0,
          );
        },
        childCount: books.length,
      ),
    );
  }

  Widget _gridBook(
    LibraryBookRow book,
    ReadingProgressRow? progress,
    BookReadingStateRow? state,
    int seconds,
  ) {
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
                Positioned.fill(child: _cover(book, 14)),
                if (value > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(14),
                      ),
                      child: LinearProgressIndicator(
                        value: value,
                        minHeight: 5,
                      ),
                    ),
                  ),
                if (state?.completedAt != null)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _badge(Icons.check, '완독'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 9),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, height: 1.2),
          ),
          const SizedBox(height: 3),
          Text(
            book.author ?? '작가 미상',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 3),
          Text(
            _label(progress, state, seconds),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Widget _listBook(
    LibraryBookRow book,
    ReadingProgressRow? progress,
    BookReadingStateRow? state,
    int seconds,
  ) {
    final value = _progress(progress);
    return InkWell(
      onTap: () => _open(book.originalUri),
      onLongPress: () => _bookSheet(book),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            SizedBox(width: 58, height: 82, child: _cover(book, 9)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    book.author ?? '작가 미상',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 9),
                  LinearProgressIndicator(
                    value: value,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _label(progress, state, seconds),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_horiz),
              onPressed: () => _bookSheet(book),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(LibraryBookRow book, double radius) {
    final path = book.coverImagePath;
    final image = path == null
        ? _coverFallback()
        : Image.file(
            File(path),
            fit: BoxFit.cover,
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

  Widget _coverFallback() {
    return Center(
      child: Icon(
        Icons.menu_book_outlined,
        size: 30,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _badge(IconData icon, String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14),
            const SizedBox(width: 3),
            Text(
              text,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _query.isEmpty ? Icons.menu_book_outlined : Icons.search_off,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              _query.isEmpty ? '아직 책이 없습니다' : '검색 결과가 없습니다',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              _query.isEmpty
                  ? '책 추가에서 폴더나 EPUB 파일을 등록하세요.'
                  : '다른 제목이나 작가 이름으로 검색해보세요.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _newShelf() async {
    final controller = TextEditingController();
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '책장 추가',
                style: Theme.of(sheetContext)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: '예: 읽는 중, 완독, 소설',
                ),
                onSubmitted: (value) => Navigator.of(
                  sheetContext,
                ).pop(value.trim()),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(
                      controller.text.trim(),
                    ),
                    child: const Text('추가'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();

    if (!mounted || name == null || name.isEmpty) return;
    await ref.read(appDatabaseProvider).addShelf(name);
  }

  void _tagSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: StreamBuilder<List<TagRow>>(
          stream: _tags,
          builder: (context, snap) {
            final tags = snap.data ?? const <TagRow>[];
            if (tags.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('태그가 없습니다. 책 메뉴에서 추가할 수 있습니다.'),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in tags)
                    FilterChip(
                      label: Text('#${tag.name}'),
                      selected: _tagId == tag.id,
                      onSelected: (_) {
                        setState(() {
                          _tagId = tag.id;
                          _shelfId = null;
                        });
                        Navigator.pop(context);
                      },
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _folderSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .55,
        maxChildSize: .85,
        builder: (context, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  Text(
                    '서재 폴더',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
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
              child: StreamBuilder<List<LibraryFolderRow>>(
                stream: _folders,
                builder: (context, snap) {
                  final folders = snap.data ?? const <LibraryFolderRow>[];
                  if (folders.isEmpty) {
                    return const Center(child: Text('지정된 폴더가 없습니다.'));
                  }
                  return ListView.separated(
                    controller: controller,
                    itemCount: folders.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final folder = folders[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          folder.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          folder.lastScannedAt == null
                              ? '스캔하지 않음'
                              : '마지막 스캔 ${folder.lastScannedAt}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              onPressed: () =>
                                  _scanFolder(folder.id, folder.path),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => ref
                                  .read(appDatabaseProvider)
                                  .removeFolder(folder.id),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _bookSheet(LibraryBookRow book) {
    final db = ref.read(appDatabaseProvider);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          shrinkWrap: true,
          children: [
            Text(
              book.title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (book.author != null) Text(book.author!),
            const SizedBox(height: 22),
            Text(
              '책장',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            StreamBuilder<List<ShelfRow>>(
              stream: _shelves,
              builder: (context, shelfSnap) => StreamBuilder<Set<int>>(
                stream: db.watchShelfIdsForBook(book.id),
                builder: (context, currentSnap) {
                  final current = currentSnap.data ?? const <int>{};
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final shelf
                          in shelfSnap.data ?? const <ShelfRow>[]) 
                        FilterChip(
                          label: Text(shelf.name),
                          selected: current.contains(shelf.id),
                          onSelected: (value) =>
                              db.setBookInShelf(book.id, shelf.id, value),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 22),
            Text(
              '태그',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            StreamBuilder<List<TagRow>>(
              stream: db.watchTagsForBook(book.id),
              builder: (context, snap) => Wrap(
                spacing: 8,
                children: [
                  for (final tag in snap.data ?? const <TagRow>[])
                    InputChip(
                      label: Text('#${tag.name}'),
                      onDeleted: () => db.setBookTag(book.id, tag.id, false),
                    ),
                ],
              ),
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
  }

  Future<void> _removeBook(LibraryBookRow book) async {
    Navigator.pop(context);
    await ref.read(appDatabaseProvider).removeBook(book.id);
  }
}
