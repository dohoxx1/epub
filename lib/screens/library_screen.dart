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

/// Phase 8: "폴더 지정 + 자동 스캔" 방식의 서재 화면.
///
/// 두 가지 방법으로 책을 라이브러리에 넣을 수 있다:
/// 1) 폴더 지정 → 그 안의 모든 .epub을 한 번에 스캔/등록 (Calibre처럼)
/// 2) 파일 하나 열기 → 기존 Phase 1/2 방식 그대로 (폴더를 안 쓰고 싶을 때 대비)
///
/// 원본 EPUB 파일은 어떤 경우에도 옮기거나 복사하지 않는다. 폴더 경로만
/// LibraryFolders 테이블에 기억해뒀다가, 스캔할 때마다 그 경로를 다시 읽는다.
/// (참고: 안드로이드에서는 시스템이 폴더 접근 권한을 회수할 수도 있는데,
/// 그런 경우엔 스캔 시도 시 에러를 보여주고 폴더를 다시 지정하면 된다.)
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
  bool _gridView = false;

  // 책장/태그 필터는 동시에 하나만 적용한다 (책장 고르면 태그 필터는 풀리고, 반대도 마찬가지).
  int? _selectedShelfId;
  int? _selectedTagId;

  @override
  void initState() {
    super.initState();
    final db = ref.read(appDatabaseProvider);
    _allBooksStream = db.watchAllBooks();
    _foldersStream = db.watchFolders();
    _shelvesStream = db.watchShelves();
    _tagsStream = db.watchTags();
    // Riverpod이 관리하는 DB 인스턴스를 그대로 재사용한다 (새 커넥션을 따로 열지 않는다).
    _scanService = LibraryScanService(EpubRepository(), db);
  }

  Stream<List<LibraryBookRow>>? _cachedBooksStream;
  int? _cachedForShelfId;
  int? _cachedForTagId;

  /// _selectedShelfId/_selectedTagId가 실제로 바뀔 때만 새 스트림을 만든다.
  /// (매번 새 Stream 인스턴스를 만들면 관련 없는 rebuild 때마다 StreamBuilder가
  /// 재구독하면서 로딩 인디케이터가 잠깐씩 깜빡이게 된다.)
  Stream<List<LibraryBookRow>> get _currentBooksStream {
    if (_cachedBooksStream != null &&
        _cachedForShelfId == _selectedShelfId &&
        _cachedForTagId == _selectedTagId) {
      return _cachedBooksStream!;
    }
    final db = ref.read(appDatabaseProvider);
    final stream = _selectedShelfId != null
        ? db.watchBooksInShelf(_selectedShelfId!)
        : _selectedTagId != null
            ? db.watchBooksWithTag(_selectedTagId!)
            : _allBooksStream;
    _cachedBooksStream = stream;
    _cachedForShelfId = _selectedShelfId;
    _cachedForTagId = _selectedTagId;
    return stream;
  }

  Future<void> _pickAndOpenSingleFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );
    if (result == null || result.files.single.path == null) return;
    await _openPath(result.files.single.path!);
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
          ? '${result.added}권을 찾았습니다.'
          : '${result.added}권을 찾았습니다. (${result.failedPaths.length}권은 열지 못했습니다)';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('폴더를 스캔하지 못했습니다: $e')),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _removeFolder(int id) async {
    await ref.read(appDatabaseProvider).removeFolder(id);
  }

  Future<void> _openPath(String path) async {
    setState(() => _opening = true);
    try {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderScreen(epubPath: path)),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _confirmRemoveBook(LibraryBookRow book) async {
    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('라이브러리에서 제거'),
        content: Text('"${book.title}"을(를) 라이브러리에서 제거할까요?\n'
            '(원본 EPUB 파일은 지워지지 않습니다. 형광펜/메모/책갈피 등 이 책의 기록만 함께 삭제됩니다.)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('제거'),
          ),
        ],
      ),
    );
    if (shouldRemove == true) {
      await ref.read(appDatabaseProvider).removeBook(book.id);
    }
  }

  void _openFolderManageSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text('서재 폴더', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _pickAndAddFolder();
                    },
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('폴더 추가'),
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
                  if (folders.isEmpty) {
                    return const Center(child: Text('지정된 폴더가 없습니다.'));
                  }
                  return ListView.separated(
                    controller: scrollController,
                    itemCount: folders.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final folder = folders[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.path,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          folder.lastScannedAt == null
                              ? '아직 스캔 안 함'
                              : '스캔 완료: ${folder.lastScannedAt}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              tooltip: '다시 스캔',
                              onPressed: () =>
                                  _scanFolder(folder.id, folder.path),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: '폴더 제거',
                              onPressed: () => _removeFolder(folder.id),
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

  // ---- 책장/태그 (Phase 9) ----

  Future<void> _addShelfDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('책장 추가'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '예: 완독, 읽는 중, 소설'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('추가'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref.read(appDatabaseProvider).addShelf(name);
  }

  Future<void> _confirmDeleteShelf(ShelfRow shelf) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('책장 삭제'),
        content: Text('"${shelf.name}" 책장을 삭제할까요? (책 자체는 지워지지 않습니다)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appDatabaseProvider).deleteShelf(shelf.id);
      if (_selectedShelfId == shelf.id) setState(() => _selectedShelfId = null);
    }
  }

  void _openTagFilterSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: StreamBuilder<List<TagRow>>(
          stream: _tagsStream,
          builder: (context, snapshot) {
            final tagList = snapshot.data ?? const [];
            if (tagList.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('아직 만들어진 태그가 없습니다. 책 목록에서 각 책의 ⋮ 메뉴로 태그를 추가해보세요.'),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in tagList)
                    ActionChip(
                      label: Text('#${tag.name}'),
                      onPressed: () {
                        setState(() {
                          _selectedTagId = tag.id;
                          _selectedShelfId = null;
                        });
                        Navigator.of(context).pop();
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

  /// 책 한 권의 책장 소속/태그를 관리하는 시트.
  void _openBookManageSheet(LibraryBookRow book) {
    final db = ref.read(appDatabaseProvider);
    final tagInputController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          children: [
            Text(book.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('책장', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            StreamBuilder<List<ShelfRow>>(
              stream: _shelvesStream,
              builder: (context, shelfSnap) {
                final shelfList = shelfSnap.data ?? const [];
                return StreamBuilder<Set<int>>(
                  stream: db.watchShelfIdsForBook(book.id),
                  builder: (context, currentSnap) {
                    final current = currentSnap.data ?? const <int>{};
                    if (shelfList.isEmpty) {
                      return const Text('아직 만들어진 책장이 없습니다.');
                    }
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final shelf in shelfList)
                          FilterChip(
                            label: Text(shelf.name),
                            selected: current.contains(shelf.id),
                            onSelected: (selected) =>
                                db.setBookInShelf(book.id, shelf.id, selected),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 24),
            Text('태그', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            StreamBuilder<List<TagRow>>(
              stream: db.watchTagsForBook(book.id),
              builder: (context, snapshot) {
                final bookTags = snapshot.data ?? const [];
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in bookTags)
                      InputChip(
                        label: Text('#${tag.name}'),
                        onDeleted: () => db.setBookTag(book.id, tag.id, false),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tagInputController,
              decoration: InputDecoration(
                hintText: '태그 입력 후 추가',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () async {
                    final name = tagInputController.text.trim();
                    if (name.isEmpty) return;
                    final tagId = await db.addTagIfNew(name);
                    await db.setBookTag(book.id, tagId, true);
                    tagInputController.clear();
                  },
                ),
              ),
              onSubmitted: (name) async {
                if (name.trim().isEmpty) return;
                final tagId = await db.addTagIfNew(name.trim());
                await db.setBookTag(book.id, tagId, true);
                tagInputController.clear();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 서재'),
        actions: [
          IconButton(
            icon: Icon(_gridView
                ? Icons.view_list_outlined
                : Icons.grid_view_outlined),
            tooltip: _gridView ? '리스트로 보기' : '표지 그리드로 보기',
            onPressed: () => setState(() => _gridView = !_gridView),
          ),
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: '독서 캘린더',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReadingCalendarScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.insights_outlined),
            tooltip: '독서 통계',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReadingStatsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.sell_outlined),
            tooltip: '태그로 보기',
            onPressed: _openTagFilterSheet,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: '서재 폴더 관리',
            onPressed: _openFolderManageSheet,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_opening || _scanning) ? null : _showAddMenu,
        icon: const Icon(Icons.add),
        label: const Text('책 추가'),
      ),
      body: Column(
        children: [
          _buildShelfChips(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildShelfChips() {
    return StreamBuilder<List<ShelfRow>>(
      stream: _shelvesStream,
      builder: (context, snapshot) {
        final shelfList = snapshot.data ?? const [];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: const Text('전체'),
                    selected:
                        _selectedShelfId == null && _selectedTagId == null,
                    onSelected: (_) => setState(() {
                      _selectedShelfId = null;
                      _selectedTagId = null;
                    }),
                  ),
                ),
                for (final shelf in shelfList)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onLongPress: () => _confirmDeleteShelf(shelf),
                      child: ChoiceChip(
                        label: Text(shelf.name),
                        selected: _selectedShelfId == shelf.id,
                        onSelected: (_) => setState(() {
                          _selectedShelfId = shelf.id;
                          _selectedTagId = null;
                        }),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('책장 추가'),
                    onPressed: _addShelfDialog,
                  ),
                ),
                if (_selectedTagId != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Chip(
                      label: const Text('태그 필터 적용됨'),
                      onDeleted: () => setState(() => _selectedTagId = null),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showAddMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('폴더 지정해서 한 번에 등록'),
              onTap: () => Navigator.of(context).pop('folder'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('EPUB 파일 하나 열기'),
              onTap: () => Navigator.of(context).pop('file'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'folder') {
      await _pickAndAddFolder();
    } else if (choice == 'file') {
      await _pickAndOpenSingleFile();
    }
  }

  Widget _buildBody() {
    if (_opening || _scanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_scanning ? '폴더를 스캔하는 중...' : '여는 중...'),
          ],
        ),
      );
    }
    return StreamBuilder<List<LibraryBookRow>>(
      stream: _currentBooksStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final books = snapshot.data!;
        if (books.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '아직 등록된 책이 없습니다.\n오른쪽 아래 버튼으로 폴더를 지정하거나 EPUB을 열어보세요.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return StreamBuilder<List<ReadingProgressRow>>(
          stream: ref.read(appDatabaseProvider).watchAllProgress(),
          builder: (context, progressSnapshot) =>
              StreamBuilder<List<BookReadingStateRow>>(
            stream: ref.read(appDatabaseProvider).watchReadingStates(),
            builder: (context, stateSnapshot) =>
                StreamBuilder<List<ReadingSessionRow>>(
              stream: ref.read(appDatabaseProvider).watchAllReadingSessions(),
              builder: (context, sessionSnapshot) {
                final progress = {
                  for (final row
                      in progressSnapshot.data ?? const <ReadingProgressRow>[])
                    row.bookId: row
                };
                final states = {
                  for (final row
                      in stateSnapshot.data ?? const <BookReadingStateRow>[])
                    row.bookId: row
                };
                final seconds = <int, int>{};
                for (final session
                    in sessionSnapshot.data ?? const <ReadingSessionRow>[]) {
                  seconds[session.bookId] =
                      (seconds[session.bookId] ?? 0) + session.activeSeconds;
                }
                return _gridView
                    ? _buildBookGrid(books, progress, states, seconds)
                    : _buildBookList(books, progress, states, seconds);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildBookList(
    List<LibraryBookRow> books,
    Map<int, ReadingProgressRow> progress,
    Map<int, BookReadingStateRow> states,
    Map<int, int> seconds,
  ) =>
      ListView.builder(
        itemCount: books.length,
        itemBuilder: (context, index) => _bookListTile(
            books[index],
            progress[books[index].id],
            states[books[index].id],
            seconds[books[index].id] ?? 0),
      );

  Widget _buildBookGrid(
    List<LibraryBookRow> books,
    Map<int, ReadingProgressRow> progress,
    Map<int, BookReadingStateRow> states,
    Map<int, int> seconds,
  ) =>
      GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: .55,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: books.length,
        itemBuilder: (context, index) {
          final book = books[index];
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openPath(book.originalUri),
            onLongPress: () => _confirmRemoveBook(book),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _cover(book, borderRadius: 12)),
              const SizedBox(height: 6),
              Text(book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                  _readingLabel(progress[book.id], states[book.id],
                      seconds[book.id] ?? 0),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          );
        },
      );

  Widget _bookListTile(LibraryBookRow book, ReadingProgressRow? progress,
      BookReadingStateRow? state, int seconds) {
    final fileExists = File(book.originalUri).existsSync();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading:
          SizedBox(width: 48, height: 68, child: _cover(book, borderRadius: 6)),
      title: Text(book.title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(fileExists ? (book.author ?? '작가 미상') : '파일을 찾을 수 없음',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: fileExists
                ? null
                : TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 4),
        LinearProgressIndicator(
            value: _overallProgress(progress),
            minHeight: 4,
            borderRadius: BorderRadius.circular(4)),
        const SizedBox(height: 3),
        Text(_readingLabel(progress, state, seconds),
            style: Theme.of(context).textTheme.bodySmall),
      ]),
      trailing: IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: '책장/태그 관리',
          onPressed: () => _openBookManageSheet(book)),
      onTap: () => _openPath(book.originalUri),
      onLongPress: () => _confirmRemoveBook(book),
    );
  }

  Widget _cover(LibraryBookRow book, {required double borderRadius}) {
    final path = book.coverImagePath;
    final image = path != null && File(path).existsSync()
        ? Image.file(File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.menu_book_outlined))
        : const Center(child: Icon(Icons.menu_book_outlined));
    return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: SizedBox.expand(child: image)));
  }

  double _overallProgress(ReadingProgressRow? row) =>
      row == null ? 0 : row.scrollFraction.clamp(0.0, 1.0);

  String _readingLabel(
      ReadingProgressRow? progress, BookReadingStateRow? state, int seconds) {
    final percent = (_overallProgress(progress) * 100).round();
    final time = seconds >= 3600
        ? '${seconds ~/ 3600}시간 ${(seconds % 3600) ~/ 60}분'
        : '${seconds ~/ 60}분';
    if (state?.completedAt != null) return '완독 · $percent% · $time';
    return '읽는 중 · $percent% · $time';
  }
}
