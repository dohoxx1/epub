import 'package:flutter/material.dart';
import '../models/epub_book.dart';

/// 목차 바텀시트.
/// - 접기/펼치기: 자식이 있는 항목은 화살표를 눌러서 펼치고 접을 수 있다.
/// - 현재 위치 표시: 지금 읽고 있는 챕터를 굵게/강조 색으로 표시한다.
/// - 검색: 제목에 검색어가 포함된 항목만 평평하게(depth 무시) 모아서 보여준다.
class ReaderTocSheet extends StatefulWidget {
  final List<EpubTocNode> nodes;
  final String currentHref; // 현재 챕터의 href (spine 기준, # 앵커 없는 절대경로)
  final void Function(String href) onSelect;

  const ReaderTocSheet({
    super.key,
    required this.nodes,
    required this.currentHref,
    required this.onSelect,
  });

  @override
  State<ReaderTocSheet> createState() => _ReaderTocSheetState();
}

class _ReaderTocSheetState extends State<ReaderTocSheet> {
  final _searchController = TextEditingController();
  String _query = '';
  final Set<EpubTocNode> _expanded = {};

  // 목차를 열자마자 현재 읽고 있는 챕터가 보이는 위치로 스크롤하기 위한 상태.
  // ListView(children:)는 Sliver 특성상 화면 밖 항목의 context가 아직 없을 수 있어서,
  // 1) 평균 행 높이로 대략적인 위치까지 먼저 점프하고
  // 2) 그 다음 프레임에 실제 위젯이 마운트되면 Scrollable.ensureVisible로 정확히 보정한다.
  static const double _estimatedRowHeight = 48.0;
  final GlobalKey _currentItemKey = GlobalKey();
  bool _didInitialScroll = false;

  @override
  void initState() {
    super.initState();
    // 현재 읽고 있는 챕터로 이어지는 경로는 처음부터 펼쳐서 보여준다.
    _autoExpandToCurrent(widget.nodes);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _clean(String href) => href.split('#').first;

  bool _autoExpandToCurrent(List<EpubTocNode> nodes) {
    var foundInSubtree = false;
    for (final node in nodes) {
      final selfMatch = _clean(node.href) == widget.currentHref;
      final childMatch = _autoExpandToCurrent(node.children);
      if (selfMatch || childMatch) {
        _expanded.add(node);
        foundInSubtree = true;
      }
    }
    return foundInSubtree;
  }

  /// 화면에 그릴 항목들(들여쓰기 포함, 접힌 항목은 제외)을 순서대로 평평하게 만들면서,
  /// 그중 현재 챕터의 인덱스를 함께 알아낸다. 대략적인 스크롤 위치 계산에 쓴다.
  int? _currentIndexIn(List<Widget> items) {
    for (var i = 0; i < items.length; i++) {
      final w = items[i];
      if (w is _TocRow && w.isCurrent) return i;
    }
    return null;
  }

  void _scheduleScrollToCurrent(ScrollController controller, int currentIndex) {
    if (_didInitialScroll) return;
    _didInitialScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      // 1단계: 평균 행 높이로 대략적인 위치까지 즉시 이동 (화면 상단에서 1/3 지점에 오도록).
      final target = (currentIndex * _estimatedRowHeight) - 100;
      final max = controller.position.maxScrollExtent;
      controller.jumpTo(target.clamp(0.0, max));

      // 2단계: 실제 항목이 마운트된 뒤, 정확한 위치로 미세 보정.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _currentItemKey.currentContext;
        if (ctx == null || !mounted) return;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 200),
        );
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        final items = _query.isEmpty
            ? _buildTree(widget.nodes, 0)
            : _buildSearchResults(widget.nodes);

        // 검색 중이 아닐 때만(=전체 트리 뷰) 현재 위치로 자동 스크롤한다.
        if (_query.isEmpty) {
          final currentIndex = _currentIndexIn(items);
          if (currentIndex != null && currentIndex > 0) {
            _scheduleScrollToCurrent(scrollController, currentIndex);
          }
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text('목차', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '목차 검색',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('검색 결과가 없습니다'))
                  : ListView(controller: scrollController, children: items),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildTree(List<EpubTocNode> nodes, int depth) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      final isCurrent = _clean(node.href) == widget.currentHref;
      final hasChildren = node.children.isNotEmpty;
      final expanded = hasChildren ? _expanded.contains(node) : null;
      widgets.add(_TocRow(
        key: isCurrent ? _currentItemKey : null,
        node: node,
        depth: depth,
        isCurrent: isCurrent,
        expanded: expanded,
        onSelect: () => widget.onSelect(node.href),
        onToggleExpand: hasChildren
            ? () => setState(() {
                  if (_expanded.contains(node)) {
                    _expanded.remove(node);
                  } else {
                    _expanded.add(node);
                  }
                })
            : null,
      ));
      if (hasChildren && expanded == true) {
        widgets.addAll(_buildTree(node.children, depth + 1));
      }
    }
    return widgets;
  }

  List<Widget> _buildSearchResults(List<EpubTocNode> nodes) {
    final matches = <(EpubTocNode, int)>[];
    final q = _query.toLowerCase();
    void walk(List<EpubTocNode> list, int depth) {
      for (final n in list) {
        if (n.title.toLowerCase().contains(q)) {
          matches.add((n, depth));
        }
        walk(n.children, depth + 1);
      }
    }

    walk(nodes, 0);

    return matches.map((m) {
      final (node, depth) = m;
      final isCurrent = _clean(node.href) == widget.currentHref;
      return _TocRow(
        node: node,
        depth: depth,
        isCurrent: isCurrent,
        expanded: null,
        onSelect: () => widget.onSelect(node.href),
        onToggleExpand: null,
      );
    }).toList();
  }
}

/// 목차 한 줄. 제목 영역을 탭하면 그 챕터로 이동하고, 자식이 있으면 오른쪽 화살표로
/// 펼치기/접기를 별도로 조작할 수 있다 (둘이 같은 탭 영역을 공유하지 않게 분리함).
class _TocRow extends StatelessWidget {
  final EpubTocNode node;
  final int depth;
  final bool isCurrent;
  final bool? expanded; // null = 자식 없는 항목(펼치기 화살표 없음)
  final VoidCallback onSelect;
  final VoidCallback? onToggleExpand;

  const _TocRow({
    super.key,
    required this.node,
    required this.depth,
    required this.isCurrent,
    required this.expanded,
    required this.onSelect,
    required this.onToggleExpand,
  });

  @override
  Widget build(BuildContext context) {
    final color = isCurrent ? Theme.of(context).colorScheme.primary : null;
    final weight = isCurrent ? FontWeight.bold : null;

    return InkWell(
      onTap: onSelect,
      child: Padding(
        padding: EdgeInsets.only(
            left: 16.0 + depth * 16, right: 4, top: 11, bottom: 11),
        child: Row(
          children: [
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.menu_book, size: 16, color: color),
              ),
            Expanded(
              child: Text(
                node.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontWeight: weight),
              ),
            ),
            if (expanded != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(expanded! ? Icons.expand_less : Icons.expand_more),
                onPressed: onToggleExpand,
              ),
          ],
        ),
      ),
    );
  }
}
