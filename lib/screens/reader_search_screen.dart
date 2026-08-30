import 'dart:async';

import 'package:flutter/material.dart';
import '../services/reader_search_service.dart';

/// 현재 책 전체를 대상으로 하는 검색 화면.
/// 결과를 탭하면 그 SearchResult를 그대로 pop해서, 리더 화면이 해당 위치로 이동한다.
class ReaderSearchScreen extends StatefulWidget {
  final List<String> chapterPaths;
  final List<String> chapterLabels;

  const ReaderSearchScreen({
    super.key,
    required this.chapterPaths,
    required this.chapterLabels,
  });

  @override
  State<ReaderSearchScreen> createState() => _ReaderSearchScreenState();
}

class _ReaderSearchScreenState extends State<ReaderSearchScreen> {
  final _service = ReaderSearchService();
  final _controller = TextEditingController();
  Timer? _debounce;

  bool _caseSensitive = false;
  bool _searching = false;
  List<SearchResult> _results = const [];
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
        _lastQuery = '';
      });
      return;
    }
    setState(() => _searching = true);
    final results = await _service.search(
      chapterPaths: widget.chapterPaths,
      query: query,
      caseSensitive: _caseSensitive,
    );
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _lastQuery = query;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '책 내용 검색',
            border: InputBorder.none,
          ),
          onChanged: _onQueryChanged,
          onSubmitted: _runSearch,
        ),
        actions: [
          IconButton(
            tooltip: '대소문자 구분',
            icon: Icon(
              Icons.text_fields,
              color:
                  _caseSensitive ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: () {
              setState(() => _caseSensitive = !_caseSensitive);
              if (_controller.text.isNotEmpty) _runSearch(_controller.text);
            },
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_lastQuery.isEmpty) {
      return const Center(child: Text('검색어를 입력하세요.'));
    }
    if (_results.isEmpty) {
      return Center(child: Text('"$_lastQuery"에 대한 검색 결과가 없습니다.'));
    }

    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final r = _results[index];
        final chapterLabel =
            (r.spineIndex >= 0 && r.spineIndex < widget.chapterLabels.length)
                ? widget.chapterLabels[r.spineIndex]
                : '${r.spineIndex + 1}장';
        return ListTile(
          title: RichText(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: DefaultTextStyle.of(context).style,
              children: [
                TextSpan(text: r.snippetBefore),
                TextSpan(
                  text: r.matchText,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                  ),
                ),
                TextSpan(text: r.snippetAfter),
              ],
            ),
          ),
          subtitle:
              Text(chapterLabel, style: Theme.of(context).textTheme.bodySmall),
          onTap: () => Navigator.of(context).pop(r),
        );
      },
    );
  }
}
