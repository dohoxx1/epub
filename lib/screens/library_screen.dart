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

/// Personal bookshelf. EPUB files always remain at their original paths.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late final Stream<List<LibraryBookRow>> _allBooksStream;
  late final Stream<List<LibraryFolderRow>> _foldersStream;
  late final Stream<List<ShelfRow>> _shelvesStream;
  late final Stream<List<TagRow>> _tagsStream;
  late final LibraryScanService _scanService;

  bool _opening = false;
  bool _scanning = false;
  bool _gridView = true;
  int? _selectedShelfId;
  int? _selectedTagId;

  Stream<List<LibraryBookRow>>? _cachedBooksStream;
  int? _cachedShelfId;
  int? _cachedTagId;

  @override
  void initState() {
    super.initState();
    final db = ref.read(appDatabaseProvider);
    _allBooksStream = db.watchAllBooks();
    _foldersStream = db.watchFolders();
    _shelvesStream = db.watchShelves();
    _tagsStream = db.watchTags();
    _scanService = LibraryScanService(EpubRepository(), db);
  }

  Stream<List<LibraryBookRow>> get _currentBooksStream {
    if (_cachedBooksStream != null &&
        _cachedShelfId == _selectedShelfId &&
        _cachedTagId == _selectedTagId) {
      return _cachedBooksStream!;
    }
    final db = ref.read(appDatabaseProvider);
    final stream = _selectedShelfId != null
        ? db.watchBooksInShelf(_selectedShelfId!)
        : _selectedTagId != null
            ? db.watchBooksWithTag(_selectedTagId!)
            : _allBooksStream;
    _cachedBooksStream = stream;
    _cachedShelfId = _selectedShelfId;
    _cachedTagId = _selectedTagId;
    return stream;
  }

  Future<void> _openPath(String path) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderScreen(epubPath: path)),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _pickAndOpenSingleFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );
    final path = result?.files.single.path;
    if (path != null) await _openPath(path);
  }

  Future<void> _pickAndAddFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'EPUB이 들어있는 폴더 선택',
    );
    if (path == null) return;
    final db = ref.read(appDatabaseProvider);
    final folderId = await db.addFolderIfNew(path);
    await _scanFolder(folderId, path);
  }

  Future<void> _scanFolder(int folderId, String path) async {
    setState(() => _scanning = true);
    final db = ref.read(appDatabaseProvider);
    try {
      final result = await _scanService.scanFolder(path);
      await db.markFolderScanned(folderId);
      if (!mounted) return;
      final message = result.failedPaths.isEmpty
          ? '${result.added}권을 서재에 추가했습니다.'
          : '${result.added}권을 찾았습니다. ${result.failedPaths.length}권은 읽지 못했습니다.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('폴더를 스캔하지 못했습니다: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _showAddMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('책 추가', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('원본 EPUB 파일은 이동하거나 복사하지 않습니다.'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('폴더 지정해서 한 번에 등록'),
              subtitle: const Text('폴더 안의 EPUB을 서재에 추가합니다'),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('EPUB 파일 하나 열기'),
              subtitle: const Text('파일을 바로 읽고 서재에 기록합니다'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'folder') await _pickAndAddFolder();
    if (choice == 'file') await _pickAndOpenSingleFile();
  }

  Future<void> _addShelfDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('책장 추가'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '예: 읽는 중, 완독, 소설'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('추가')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await ref.read(appDatabaseProvider).addShelf(name);
    }
  }

  Future<void> _confirmDeleteShelf(ShelfRow shelf) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('책장 삭제'),
        content: Text('“${shelf.name}” 책장을 삭제할까요? 책은 삭제되지 않습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('삭제')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appDatabaseProvider).deleteShelf(shelf.id);
      if (_selectedShelfId == shelf.id && mounted) setState(() => _selectedShelfId = null);
    }
  }

  void _openTagFilterSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: StreamBuilder<List<TagRow>>(
          stream: _tagsStream,
          builder: (context, snapshot) {
            final tags = snapshot.data ?? const [];
            if (tags.isEmpty) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 32),
                child: Text('아직 태그가 없습니다. 책의 메뉴에서 태그를 추가할 수 있습니다.'),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in tags)
                    FilterChip(
                      label: Text('#${tag.name}'),
                      selected: _selectedTagId == tag.id,
                      onSelected: (_) {
                        setState(() {
                          _selectedTagId = tag.id;
                          _selectedShelfId = null;
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

  void _openFolderManageSheet() {
    showModalBottomSheet(
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
                  Text('서재 폴더', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _pickAndAddFolder();
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
                stream: _foldersStream,
                builder: (context, snapshot) {
                  final folders = snapshot.data ?? const [];
                  if (folders.isEmpty) return const Center(child: Text('지정된 폴더가 없습니다.'));
                  return ListView.separated(
                    controller: controller,
                    itemCount: folders.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final folder = folders[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(folder.lastScannedAt == null ? '아직 스캔하지 않음' : '마지막 스캔 ${folder.lastScannedAt}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(icon: const Icon(Icons.refresh), tooltip: '다시 스캔', onPressed: () => _scanFolder(folder.id, folder.path)),
                            IconButton(icon: const Icon(Icons.delete_outline), tooltip: '폴더 제거', onPressed: () => ref.read(appDatabaseProvider).removeFolder(folder.id)),
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

  void _openBookManageSheet(LibraryBookRow book) {
    final db = ref.read(appDatabaseProvider);
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .62,
        maxChildSize: .9,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            Text(book.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            if (book.author != null) ...[
              const SizedBox(height: 4),
              Text(book.author!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            const SizedBox(height: 24),
            Text('책장', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            StreamBuilder<List<ShelfRow>>(
              stream: _shelvesStream,
              builder: (context, shelfSnap) => StreamBuilder<Set<int>>(
                stream: db.watchShelfIdsForBook(book.id),
                builder: (context, currentSnap) {
                  final shelves = shelfSnap.data ?? const [];
                  final current = currentSnap.data ?? const <int>{};
                  if (shelves.isEmpty) return const Text('책장을 먼저 만들어 주세요.');
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final shelf in shelves)
                        FilterChip(label: Text(shelf.name), selected: current.contains(shelf.id), onSelected: (v) => db.setBookInShelf(book.id, shelf.id, v)),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
            Text('태그', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            StreamBuilder<List<TagRow>>(
              stream: db.watchTagsForBook(book.id),
              builder: (context, snapshot) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final tag in snapshot.data ?? const []) InputChip(label: Text('#${tag.name}'), onDeleted: () => db.setBookTag(book.id, tag.id, false))],
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: '새 태그', hintText: '태그 입력 후 추가', suffixIcon: Icon(Icons.add)),
              onSubmitted: (value) => _addTag(db, book.id, controller, value),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _confirmRemoveBook(book);
              },
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('서재에서 제거'),
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _addTag(AppDatabase db, int bookId, TextEditingController controller, String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    final id = await db.addTagIfNew(name);
    await db.setBookTag(bookId, id, true);
    controller.clear();
  }

  Future<void> _confirmRemoveBook(LibraryBookRow book) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('서재에서 제거'),
        content: Text('“${book.title}”을(를) 서재에서 제거할까요?\n원본 EPUB 파일은 삭제되지 않습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('제거')),
        ],
      ),
    );
    if (remove == true) await ref.read(appDatabaseProvider).removeBook(book.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 서재', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(icon: Icon(_gridView ? Icons.view_list_outlined : Icons.grid_view_outlined), tooltip: '보기 전환', onPressed: () => setState(() => _gridView = !_gridView)),
          IconButton(icon: const Icon(Icons.search_outlined), tooltip: '검색', onPressed: () => _showSearchHint()),
          PopupMenuButton<String>(
            tooltip: '더보기',
            onSelected: (value) {
              if (value == 'calendar') Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingCalendarScreen()));
              if (value == 'stats') Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingStatsScreen()));
              if (value == 'tag') _openTagFilterSheet();
              if (value == 'folder') _openFolderManageSheet();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'calendar', child: ListTile(leading: Icon(Icons.calendar_month_outlined), title: Text('독서 캘린더'), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'stats', child: ListTile(leading: Icon(Icons.insights_outlined), title: Text('독서 통계'), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'tag', child: ListTile(leading: Icon(Icons.sell_outlined), title: Text('태그 필터'), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'folder', child: ListTile(leading: Icon(Icons.folder_outlined), title: Text('서재 폴더'), contentPadding: EdgeInsets.zero)),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_opening || _scanning) ? null : _showAddMenu,
        icon: const Icon(Icons.add),
        label: const Text('책 추가'),
      ),
      body: StreamBuilder<List<ShelfRow>>(
        stream: _shelvesStream,
        builder: (context, snapshot) => Column(
          children: [
            _buildHeader(scheme, snapshot.data ?? const []),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme, List<ShelfRow> shelves) {
    final hasFilter = _selectedShelfId != null || _selectedTagId != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_selectedShelfId == null && _selectedTagId == null ? '전체 책' : '필터링된 책', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (hasFilter) TextButton(onPressed: () => setState(() { _selectedShelfId = null; _selectedTagId = null; }), child: const Text('필터 해제')),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip('전체', _selectedShelfId == null && _selectedTagId == null, () => setState(() { _selectedShelfId = null; _selectedTagId = null; })),
                for (final shelf in shelves) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onLongPress: () => _confirmDeleteShelf(shelf),
                    child: _filterChip(shelf.name, _selectedShelfId == shelf.id, () => setState(() { _selectedShelfId = shelf.id; _selectedTagId = null; })),
                  ),
                ],
                const SizedBox(width: 8),
                ActionChip(avatar: const Icon(Icons.add, size: 17), label: const Text('책장'), onPressed: _addShelfDialog),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) => FilterChip(label: Text(label), selected: selected, onSelected: (_) => onTap());

  Widget _buildBody() {
    if (_opening || _scanning) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(height: 14), Text(_scanning ? '서재를 스캔하는 중…' : '책을 여는 중…')]));
    }
    return StreamBuilder<List<LibraryBookRow>>(
      stream: _currentBooksStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final books = snapshot.data!;
        if (books.isEmpty) return _emptyState();
        return StreamBuilder<List<ReadingProgressRow>>(
          stream: ref.read(appDatabaseProvider).watchAllProgress(),
          builder: (context, progressSnapshot) => StreamBuilder<List<BookReadingStateRow>>(
            stream: ref.read(appDatabaseProvider).watchReadingStates(),
            builder: (context, stateSnapshot) => StreamBuilder<List<ReadingSessionRow>>(
              stream: ref.read(appDatabaseProvider).watchAllReadingSessions(),
              builder: (context, sessionSnapshot) {
                final progress = {for (final r in progressSnapshot.data ?? const <ReadingProgressRow>[]) r.bookId: r};
                final states = {for (final r in stateSnapshot.data ?? const <BookReadingStateRow>[]) r.bookId: r};
                final seconds = <int, int>{};
                for (final s in sessionSnapshot.data ?? const <ReadingSessionRow>[]) seconds[s.bookId] = (seconds[s.bookId] ?? 0) + s.activeSeconds;
                return _gridView ? _buildGrid(books, progress, states, seconds) : _buildList(books, progress, states, seconds);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.menu_book_outlined, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 18),
            Text('아직 책이 없습니다', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('EPUB 폴더를 지정하거나 파일 하나를 열어\n나만의 서재를 시작하세요.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: _showAddMenu, icon: const Icon(Icons.add), label: const Text('책 추가')),
          ]),
        ),
      );

  Widget _buildGrid(List<LibraryBookRow> books, Map<int, ReadingProgressRow> progress, Map<int, BookReadingStateRow> states, Map<int, int> seconds) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 190, childAspectRatio: .61, crossAxisSpacing: 18, mainAxisSpacing: 22),
        itemCount: books.length,
        itemBuilder: (_, index) {
          final book = books[index];
          return _gridBook(book, progress[book.id], states[book.id], seconds[book.id] ?? 0);
        },
      );

  Widget _gridBook(LibraryBookRow book, ReadingProgressRow? progress, BookReadingStateRow? state, int seconds) {
    final fraction = _progress(progress);
    return GestureDetector(
      onTap: () => _openPath(book.originalUri),
      onLongPress: () => _openBookManageSheet(book),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: _cover(book, 14)),
            if (fraction > 0) Positioned(left: 0, right: 0, bottom: 0, child: ClipRRect(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)), child: LinearProgressIndicator(value: fraction, minHeight: 4))),
            if (state?.completedAt != null) Positioned(top: 9, right: 9, child: _statusBadge(Icons.check, '완독')),
          ]),
        ),
        const SizedBox(height: 9),
        Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, height: 1.25)),
        const SizedBox(height: 3),
        Text(book.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(_readingLabel(progress, state, seconds), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
      ]),
    );
  }

  Widget _statusBadge(IconData icon, String label) => DecoratedBox(
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface.withValues(alpha: .92), borderRadius: BorderRadius.circular(20)),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14), const SizedBox(width: 3), Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))])),
      );

  Widget _buildList(List<LibraryBookRow> books, Map<int, ReadingProgressRow> progress, Map<int, BookReadingStateRow> states, Map<int, int> seconds) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 100),
        itemCount: books.length,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (_, index) {
          final book = books[index];
          return _listBook(book, progress[book.id], states[book.id], seconds[book.id] ?? 0);
        },
      );

  Widget _listBook(LibraryBookRow book, ReadingProgressRow? progress, BookReadingStateRow? state, int seconds) {
    final fraction = _progress(progress);
    final exists = File(book.originalUri).existsSync();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openPath(book.originalUri),
        onLongPress: () => _openBookManageSheet(book),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(children: [
            SizedBox(width: 54, height: 78, child: _cover(book, 9)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(exists ? (book.author ?? '작가 미상') : '파일을 찾을 수 없음', maxLines: 1, overflow: TextOverflow.ellipsis, style: exists ? null : TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 9),
              LinearProgressIndicator(value: fraction, minHeight: 4, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 4),
              Text(_readingLabel(progress, state, seconds), style: Theme.of(context).textTheme.labelSmall),
            ])),
            IconButton(icon: const Icon(Icons.more_horiz), tooltip: '책 관리', onPressed: () => _openBookManageSheet(book)),
          ]),
        ),
      ),
    );
  }

  Widget _cover(LibraryBookRow book, double radius) {
    final path = book.coverImagePath;
    final image = path != null && File(path).existsSync()
        ? Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _coverFallback())
        : _coverFallback();
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: SizedBox.expand(child: image)));
  }

  Widget _coverFallback() => Center(child: Icon(Icons.menu_book_outlined, size: 28, color: Theme.of(context).colorScheme.onSurfaceVariant));

  double _progress(ReadingProgressRow? row) => row == null ? 0 : row.scrollFraction.clamp(0.0, 1.0);

  String _readingLabel(ReadingProgressRow? progress, BookReadingStateRow? state, int seconds) {
    final percent = (_progress(progress) * 100).round();
    final time = seconds >= 3600 ? '${seconds ~/ 3600}시간 ${(seconds % 3600) ~/ 60}분' : '${seconds ~/ 60}분';
    if (state?.completedAt != null) return '완독 · $percent% · $time';
    if (percent == 0) return '읽지 않음';
    return '읽는 중 · $percent% · $time';
  }

  void _showSearchHint() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('책을 열고 검색 버튼을 사용하면 본문을 검색할 수 있습니다.')));
  }
}
