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
  void dispose() { _search.dispose(); super.dispose(); }

  Stream<List<LibraryBookRow>> get _visibleBooks {
    if (_shelfId != null) return ref.read(appDatabaseProvider).watchBooksInShelf(_shelfId!);
    if (_tagId != null) return ref.read(appDatabaseProvider).watchBooksWithTag(_tagId!);
    return _allBooks;
  }

  Future<void> _open(String path) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(epubPath: path))); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _addFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['epub']);
    final path = result?.files.single.path;
    if (path != null) await _open(path);
  }

  Future<void> _scanFolder(int id, String path) async {
    setState(() => _busy = true);
    try {
      final result = await _scanner.scanFolder(path);
      await ref.read(appDatabaseProvider).markFolderScanned(id);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result.added}권을 서재에 추가했습니다.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('폴더를 스캔하지 못했습니다: $e')));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _addFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'EPUB이 들어있는 폴더 선택');
    if (path == null) return;
    final id = await ref.read(appDatabaseProvider).addFolderIfNew(path);
    await _scanFolder(id, path);
  }

  Future<void> _addMenu() async {
    final choice = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: Wrap(children: [
      const ListTile(title: Text('책 추가', style: TextStyle(fontWeight: FontWeight.w800)), subtitle: Text('원본 EPUB 파일은 이동하거나 복사하지 않습니다.')),
      ListTile(leading: const Icon(Icons.folder_outlined), title: const Text('폴더에서 가져오기'), subtitle: const Text('폴더 안의 EPUB을 한 번에 등록'), onTap: () => Navigator.pop(context, 'folder')),
      ListTile(leading: const Icon(Icons.menu_book_outlined), title: const Text('EPUB 파일 열기'), subtitle: const Text('파일 하나를 바로 읽기'), onTap: () => Navigator.pop(context, 'file')),
      const SizedBox(height: 8),
    ])));
    if (choice == 'folder') await _addFolder();
    if (choice == 'file') await _addFile();
  }

  double _progress(ReadingProgressRow? p) => p == null ? 0 : p.scrollFraction.clamp(0.0, 1.0);
  String _label(ReadingProgressRow? p, BookReadingStateRow? s, int seconds) {
    final percent = (_progress(p) * 100).round();
    if (s?.completedAt != null) return '완독 · $percent%';
    if (percent == 0) return seconds > 0 ? '읽음 · ${seconds ~/ 60}분' : '읽지 않음';
    return '읽는 중 · $percent%';
  }

  List<LibraryBookRow> _searchBooks(List<LibraryBookRow> books) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return books;
    return books.where((b) => b.title.toLowerCase().contains(q) || (b.author ?? '').toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(controller: _search, autofocus: true, decoration: const InputDecoration(hintText: '제목 또는 작가 검색', border: InputBorder.none), onChanged: (v) => setState(() => _query = v))
            : const Text('내 서재', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(icon: Icon(_searching ? Icons.close : Icons.search), tooltip: _searching ? '검색 닫기' : '책 검색', onPressed: () { setState(() { _searching = !_searching; if (!_searching) { _query = ''; _search.clear(); } }); }),
          IconButton(icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined), tooltip: '보기 전환', onPressed: () => setState(() => _grid = !_grid)),
          PopupMenuButton<String>(onSelected: (v) { if (v == 'calendar') Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingCalendarScreen())); if (v == 'stats') Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingStatsScreen())); if (v == 'tags') _tagSheet(); if (v == 'folders') _folderSheet(); }, itemBuilder: (_) => const [PopupMenuItem(value: 'calendar', child: Text('독서 캘린더')), PopupMenuItem(value: 'stats', child: Text('독서 통계')), PopupMenuItem(value: 'tags', child: Text('태그 필터')), PopupMenuItem(value: 'folders', child: Text('서재 폴더'))]),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _busy ? null : _addMenu, icon: const Icon(Icons.add), label: const Text('책 추가')),
      body: StreamBuilder<List<ShelfRow>>(stream: _shelves, builder: (context, shelfSnap) => StreamBuilder<List<LibraryBookRow>>(stream: _visibleBooks, builder: (context, bookSnap) {
        if (!bookSnap.hasData) return const Center(child: CircularProgressIndicator());
        final books = _searchBooks(bookSnap.data!);
        return StreamBuilder<List<ReadingProgressRow>>(stream: ref.read(appDatabaseProvider).watchAllProgress(), builder: (context, progressSnap) => StreamBuilder<List<BookReadingStateRow>>(stream: ref.read(appDatabaseProvider).watchReadingStates(), builder: (context, stateSnap) => StreamBuilder<List<ReadingSessionRow>>(stream: ref.read(appDatabaseProvider).watchAllReadingSessions(), builder: (context, sessionSnap) {
          final progress = {for (final x in progressSnap.data ?? const <ReadingProgressRow>[]) x.bookId: x};
          final states = {for (final x in stateSnap.data ?? const <BookReadingStateRow>[]) x.bookId: x};
          final seconds = <int, int>{};
          for (final x in sessionSnap.data ?? const <ReadingSessionRow>[]) { seconds[x.bookId] = (seconds[x.bookId] ?? 0) + x.activeSeconds; }
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(child: _header(shelfSnap.data ?? const [])),
            if (_query.isEmpty && _shelfId == null && _tagId == null) ..._continueReading(bookSnap.data!, progress),
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 10), child: Text('책 ${books.length}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)))),
            if (books.isEmpty) SliverFillRemaining(hasScrollBody: false, child: _empty()) else if (_grid) _gridSliver(books, progress, states, seconds) else _listSliver(books, progress, states, seconds),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ]);
        }))));
      })),
    );
  }

  Widget _header(List<ShelfRow> shelves) => Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 2), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [Text(_shelfId == null && _tagId == null ? '전체 책' : '필터 결과', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)), const Spacer(), if (_shelfId != null || _tagId != null) TextButton(onPressed: () => setState(() { _shelfId = null; _tagId = null; }), child: const Text('해제'))]),
    const SizedBox(height: 8),
    SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
      _chip('전체', _shelfId == null && _tagId == null, () => setState(() { _shelfId = null; _tagId = null; })),
      for (final shelf in shelves) ...[const SizedBox(width: 8), _chip(shelf.name, _shelfId == shelf.id, () => setState(() { _shelfId = shelf.id; _tagId = null; }))],
      const SizedBox(width: 8), ActionChip(avatar: const Icon(Icons.add, size: 17), label: const Text('책장'), onPressed: _newShelf),
    ])),
  ]));

  Widget _chip(String text, bool selected, VoidCallback tap) => FilterChip(label: Text(text), selected: selected, onSelected: (_) => tap());

  List<Widget> _continueReading(List<LibraryBookRow> books, Map<int, ReadingProgressRow> progress) {
    final reading = books.where((b) => _progress(progress[b.id]) > 0).take(6).toList();
    if (reading.isEmpty) return const [];
    return [const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(20, 22, 20, 10), child: Text('계속 읽기', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)))), SliverToBoxAdapter(child: SizedBox(height: 176, child: ListView.separated(padding: const EdgeInsets.symmetric(horizontal: 20), scrollDirection: Axis.horizontal, itemCount: reading.length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (_, i) { final b = reading[i]; final p = _progress(progress[b.id]); return SizedBox(width: 280, child: Material(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .55), borderRadius: BorderRadius.circular(18), child: InkWell(borderRadius: BorderRadius.circular(18), onTap: () => _open(b.originalUri), child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [SizedBox(width: 92, height: 140, child: _cover(b, 10)), const SizedBox(width: 14), Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(b.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, height: 1.2)), const SizedBox(height: 8), Text(b.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 16), LinearProgressIndicator(value: p, minHeight: 5, borderRadius: BorderRadius.circular(5)), const SizedBox(height: 6), Text('${(p * 100).round()}% 읽음', style: Theme.of(context).textTheme.labelSmall)]))])))); })))];
  }

  SliverGrid _gridSliver(List<LibraryBookRow> books, Map<int, ReadingProgressRow> progress, Map<int, BookReadingStateRow> states, Map<int, int> seconds) => SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 20), sliver: SliverGrid(delegate: SliverChildBuilderDelegate((_, i) { final b = books[i]; return _gridBook(b, progress[b.id], states[b.id], seconds[b.id] ?? 0); }, childCount: books.length), gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 190, mainAxisExtent: 284, crossAxisSpacing: 18, mainAxisSpacing: 22)));

  SliverList _listSliver(List<LibraryBookRow> books, Map<int, ReadingProgressRow> progress, Map<int, BookReadingStateRow> states, Map<int, int> seconds) => SliverList(delegate: SliverChildBuilderDelegate((_, i) { final b = books[i]; return _listBook(b, progress[b.id], states[b.id], seconds[b.id] ?? 0); }, childCount: books.length));

  Widget _gridBook(LibraryBookRow b, ReadingProgressRow? p, BookReadingStateRow? s, int seconds) { final value = _progress(p); return GestureDetector(onTap: () => _open(b.originalUri), onLongPress: () => _bookSheet(b), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Stack(children: [Positioned.fill(child: _cover(b, 14)), if (value > 0) Positioned(left: 0, right: 0, bottom: 0, child: ClipRRect(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)), child: LinearProgressIndicator(value: value, minHeight: 5))), if (s?.completedAt != null) Positioned(top: 8, right: 8, child: _badge(Icons.check, '완독'))])), const SizedBox(height: 9), Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, height: 1.2)), const SizedBox(height: 3), Text(b.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 3), Text(_label(p, s, seconds), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall)])); }

  Widget _listBook(LibraryBookRow b, ReadingProgressRow? p, BookReadingStateRow? s, int seconds) { final value = _progress(p); return InkWell(onTap: () => _open(b.originalUri), onLongPress: () => _bookSheet(b), child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 12, 8), child: Row(children: [SizedBox(width: 58, height: 82, child: _cover(b, 9)), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 3), Text(b.author ?? '작가 미상', maxLines: 1, overflow: TextOverflow.ellipsis), const SizedBox(height: 9), LinearProgressIndicator(value: value, minHeight: 4, borderRadius: BorderRadius.circular(4)), const SizedBox(height: 4), Text(_label(p, s, seconds), style: Theme.of(context).textTheme.labelSmall)])), IconButton(icon: const Icon(Icons.more_horiz), onPressed: () => _bookSheet(b))]))); }

  Widget _cover(LibraryBookRow b, double radius) { final path = b.coverImagePath; final image = path == null ? _coverFallback() : Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _coverFallback()); return ClipRRect(borderRadius: BorderRadius.circular(radius), child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: SizedBox.expand(child: image))); }
  Widget _coverFallback() => Center(child: Icon(Icons.menu_book_outlined, size: 30, color: Theme.of(context).colorScheme.onSurfaceVariant));
  Widget _badge(IconData icon, String text) => DecoratedBox(decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface.withValues(alpha: .94), borderRadius: BorderRadius.circular(18)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14), const SizedBox(width: 3), Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800))])));
  Widget _empty() => Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(_query.isEmpty ? Icons.menu_book_outlined : Icons.search_off, size: 56, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 14), Text(_query.isEmpty ? '아직 책이 없습니다' : '검색 결과가 없습니다', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)), const SizedBox(height: 8), Text(_query.isEmpty ? '책 추가에서 폴더나 EPUB 파일을 등록하세요.' : '다른 제목이나 작가 이름으로 검색해보세요.', textAlign: TextAlign.center)])));

  Future<void> _newShelf() async { final c = TextEditingController(); final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(title: const Text('책장 추가'), content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: '예: 읽는 중, 완독, 소설')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')), FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('추가'))])); c.dispose(); if (name != null && name.isNotEmpty) await ref.read(appDatabaseProvider).addShelf(name); }

  void _tagSheet() { showModalBottomSheet(context: context, showDragHandle: true, builder: (context) => SafeArea(child: StreamBuilder<List<TagRow>>(stream: _tags, builder: (context, snap) { final tags = snap.data ?? const []; if (tags.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Text('태그가 없습니다. 책 메뉴에서 추가할 수 있습니다.')); return Padding(padding: const EdgeInsets.all(20), child: Wrap(spacing: 8, runSpacing: 8, children: [for (final tag in tags) FilterChip(label: Text('#${tag.name}'), selected: _tagId == tag.id, onSelected: (_) { setState(() { _tagId = tag.id; _shelfId = null; }); Navigator.pop(context); })])); })));
  }

  void _folderSheet() { showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (context) => DraggableScrollableSheet(expand: false, initialChildSize: .55, maxChildSize: .85, builder: (context, controller) => Column(children: [Padding(padding: const EdgeInsets.fromLTRB(20, 0, 12, 8), child: Row(children: [Text('서재 폴더', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)), const Spacer(), TextButton.icon(onPressed: () { Navigator.pop(context); _addFolder(); }, icon: const Icon(Icons.add), label: const Text('추가'))])), const Divider(height: 1), Expanded(child: StreamBuilder<List<LibraryFolderRow>>(stream: _folders, builder: (context, snap) { final folders = snap.data ?? const []; if (folders.isEmpty) return const Center(child: Text('지정된 폴더가 없습니다.')); return ListView.separated(controller: controller, itemCount: folders.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (_, i) { final f = folders[i]; return ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(f.lastScannedAt == null ? '스캔하지 않음' : '마지막 스캔 ${f.lastScannedAt}'), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => _scanFolder(f.id, f.path)), IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => ref.read(appDatabaseProvider).removeFolder(f.id))])); }); }))]))); }

  void _bookSheet(LibraryBookRow book) { final db = ref.read(appDatabaseProvider); showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (context) => SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), shrinkWrap: true, children: [Text(book.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)), if (book.author != null) Text(book.author!), const SizedBox(height: 22), Text('책장', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)), const SizedBox(height: 8), StreamBuilder<List<ShelfRow>>(stream: _shelves, builder: (context, shelfSnap) => StreamBuilder<Set<int>>(stream: db.watchShelfIdsForBook(book.id), builder: (context, currentSnap) { final current = currentSnap.data ?? const <int>{}; return Wrap(spacing: 8, runSpacing: 8, children: [for (final shelf in shelfSnap.data ?? const []) FilterChip(label: Text(shelf.name), selected: current.contains(shelf.id), onSelected: (v) => db.setBookInShelf(book.id, shelf.id, v))]); })), const SizedBox(height: 22), Text('태그', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)), const SizedBox(height: 8), StreamBuilder<List<TagRow>>(stream: db.watchTagsForBook(book.id), builder: (context, snap) => Wrap(spacing: 8, children: [for (final tag in snap.data ?? const []) InputChip(label: Text('#${tag.name}'), onDeleted: () => db.setBookTag(book.id, tag.id, false))])), const SizedBox(height: 10), TextField(decoration: const InputDecoration(labelText: '새 태그', hintText: '입력 후 완료'), onSubmitted: (v) async { final n = v.trim(); if (n.isEmpty) return; final id = await db.addTagIfNew(n); await db.setBookTag(book.id, id, true); }), const SizedBox(height: 22), OutlinedButton.icon(onPressed: () async { Navigator.pop(context); final ok = await showDialog<bool>(context: this.context, builder: (context) => AlertDialog(title: const Text('서재에서 제거'), content: Text('“${book.title}”을(를) 서재에서 제거할까요? 원본 EPUB은 삭제되지 않습니다.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('제거'))])); if (ok == true) await db.removeBook(book.id); }, icon: const Icon(Icons.remove_circle_outline), label: const Text('서재에서 제거'))]))); }
}
