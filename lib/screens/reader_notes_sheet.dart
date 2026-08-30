import 'package:flutter/material.dart';
import '../services/database/app_database.dart';

/// 형광펜/메모/책갈피를 한 화면에서 모아 볼 수 있는 통합 목록 시트.
/// 세 탭으로 나뉘어 있고, 각 항목을 탭하면 해당 위치로 이동한다.
class ReaderNotesSheet extends StatelessWidget {
  final Stream<List<HighlightRow>> highlightsStream;
  final Stream<List<MemoRow>> memosStream;
  final Stream<List<BookmarkRow>> bookmarksStream;

  final ValueChanged<HighlightRow> onSelectHighlight;
  final Future<void> Function(int id) onDeleteHighlight;

  final ValueChanged<MemoRow> onSelectMemo;
  final Future<void> Function(MemoRow memo) onEditMemo;
  final Future<void> Function(int id) onDeleteMemo;

  final ValueChanged<BookmarkRow> onSelectBookmark;
  final Future<void> Function(int id) onDeleteBookmark;

  /// 시트를 처음 열 때 보여줄 탭 (예: 하이라이트를 탭해서 만든 직후엔 형광펜 탭).
  final int initialTabIndex;

  const ReaderNotesSheet({
    super.key,
    required this.highlightsStream,
    required this.memosStream,
    required this.bookmarksStream,
    required this.onSelectHighlight,
    required this.onDeleteHighlight,
    required this.onSelectMemo,
    required this.onEditMemo,
    required this.onDeleteMemo,
    required this.onSelectBookmark,
    required this.onDeleteBookmark,
    this.initialTabIndex = 0,
  });

  static String _dateLabel(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}.${two(dt.month)}.${two(dt.day)}';
  }

  static Color _highlightColor(int argb) => Color(argb);

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTabIndex,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    Text('내 노트', style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '형광펜'),
                  Tab(text: '메모'),
                  Tab(text: '책갈피'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _HighlightsTab(
                      stream: highlightsStream,
                      scrollController: scrollController,
                      onSelect: onSelectHighlight,
                      onDelete: onDeleteHighlight,
                    ),
                    _MemosTab(
                      stream: memosStream,
                      scrollController: scrollController,
                      onSelect: onSelectMemo,
                      onEdit: onEditMemo,
                      onDelete: onDeleteMemo,
                    ),
                    _BookmarksTab(
                      stream: bookmarksStream,
                      scrollController: scrollController,
                      onSelect: onSelectBookmark,
                      onDelete: onDeleteBookmark,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HighlightsTab extends StatelessWidget {
  final Stream<List<HighlightRow>> stream;
  final ScrollController scrollController;
  final ValueChanged<HighlightRow> onSelect;
  final Future<void> Function(int id) onDelete;

  const _HighlightsTab({
    required this.stream,
    required this.scrollController,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<HighlightRow>>(
      stream: stream,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return const Center(child: Text('아직 형광펜이 없습니다.'));
        }
        return ListView.separated(
          controller: scrollController,
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              leading: CircleAvatar(
                radius: 10,
                backgroundColor:
                    ReaderNotesSheet._highlightColor(item.colorValue),
              ),
              title: Text(
                item.snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                  '${item.spineIndex + 1}장 · ${ReaderNotesSheet._dateLabel(item.createdAt)}'),
              onTap: () => onSelect(item),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => onDelete(item.id),
              ),
            );
          },
        );
      },
    );
  }
}

class _MemosTab extends StatelessWidget {
  final Stream<List<MemoRow>> stream;
  final ScrollController scrollController;
  final ValueChanged<MemoRow> onSelect;
  final Future<void> Function(MemoRow memo) onEdit;
  final Future<void> Function(int id) onDelete;

  const _MemosTab({
    required this.stream,
    required this.scrollController,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MemoRow>>(
      stream: stream,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return const Center(child: Text('아직 메모가 없습니다.'));
        }
        return ListView.separated(
          controller: scrollController,
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text(
                item.content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '"${item.snippet}" · ${item.spineIndex + 1}장 · ${ReaderNotesSheet._dateLabel(item.createdAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelect(item),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => onEdit(item),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onDelete(item.id),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _BookmarksTab extends StatelessWidget {
  final Stream<List<BookmarkRow>> stream;
  final ScrollController scrollController;
  final ValueChanged<BookmarkRow> onSelect;
  final Future<void> Function(int id) onDelete;

  const _BookmarksTab({
    required this.stream,
    required this.scrollController,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<BookmarkRow>>(
      stream: stream,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return const Center(child: Text('아직 책갈피가 없습니다.'));
        }
        return ListView.separated(
          controller: scrollController,
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];
            final percent = (item.scrollFraction * 100).round();
            final label = (item.label != null && item.label!.isNotEmpty)
                ? item.label!
                : '${item.spineIndex + 1}장 · $percent%';
            return ListTile(
              leading: const Icon(Icons.bookmark),
              title: Text(label),
              subtitle: Text(ReaderNotesSheet._dateLabel(item.createdAt)),
              onTap: () => onSelect(item),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => onDelete(item.id),
              ),
            );
          },
        );
      },
    );
  }
}
