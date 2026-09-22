import 'dart:io';

/// 검색 결과 하나. 실제 위치로 이동할 때는 spineIndex(몇 번째 챕터)와
/// matchText+occurrenceIndex(그 챕터 안에서 몇 번째로 나온 이 문자열인지)를 그대로
/// WebView의 window.__reader.findAndScrollTo(...)에 넘겨서, 브라우저가 실제로
/// 렌더링한 DOM 안에서 다시 찾아 스크롤하게 한다. (미리 계산해둔 문자 오프셋에
/// 의존하지 않으므로, 평문 추출이 브라우저 렌더링과 100% 똑같지 않아도 안전하다.)
class SearchResult {
  final int spineIndex;
  final int occurrenceIndex;
  final String snippetBefore;
  final String matchText;
  final String snippetAfter;

  const SearchResult({
    required this.spineIndex,
    required this.occurrenceIndex,
    required this.snippetBefore,
    required this.matchText,
    required this.snippetAfter,
  });
}

/// 챕터 HTML에서 태그를 걷어내고 사람이 읽는 순서 그대로의 평문을 뽑아낸다.
/// 브라우저의 실제 렌더링 결과와 완벽히 똑같지는 않지만(예: 일부 CSS로 숨겨진
/// 텍스트도 포함될 수 있음), 검색 미리보기와 "몇 번째로 나온 단어인지" 세는
/// 용도로는 충분히 정확하다.
String stripHtmlToText(String html) {
  var s = html;
  s = s.replaceAll(
      RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ');
  s = s.replaceAll(
      RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ');
  // 태그 자체는 전부 지우되, 블록/줄바꿈 성격의 태그 자리에는 공백을 하나 남겨서
  // "</p><p>" 처럼 붙어있던 두 단어가 서로 이어져 붙어버리지 않게 한다.
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  s = s.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
  return s;
}

class ReaderSearchService {
  /// 책 전체 챕터(spine 순서대로)에서 query를 찾아 결과 목록을 만든다.
  /// 결과가 매우 많아질 수 있는 흔한 단어 검색을 대비해, 챕터당 최대
  /// [maxResultsPerChapter]개까지만 담는다 (미리보기 목적이라 이 정도면 충분).
  Future<List<SearchResult>> search({
    required List<String> chapterPaths,
    List<int>? spineIndices,
    required String query,
    bool caseSensitive = false,
    int maxResultsPerChapter = 50,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];
    final results = <SearchResult>[];
    final indices = spineIndices ?? [for (var i = 0; i < chapterPaths.length; i++) i];
    for (var chapterIndex = 0; chapterIndex < chapterPaths.length; chapterIndex++) {
      final spineIndex = chapterIndex < indices.length ? indices[chapterIndex] : chapterIndex;
      String raw;
      try {
        raw = await File(chapterPaths[chapterIndex]).readAsString();
      } catch (_) {
        continue; // 파일을 못 읽으면 그 챕터는 건너뛴다.
      }

      final text = stripHtmlToText(raw);
      final haystack = caseSensitive ? text : text.toLowerCase();
      final needle = caseSensitive ? trimmed : trimmed.toLowerCase();

      var searchFrom = 0;
      var occurrence = 0;
      while (occurrence < maxResultsPerChapter) {
        final idx = haystack.indexOf(needle, searchFrom);
        if (idx == -1) break;

        final ctxStart = (idx - 24).clamp(0, text.length);
        final ctxEnd = (idx + needle.length + 24).clamp(0, text.length);
        results.add(SearchResult(
          spineIndex: spineIndex,
          occurrenceIndex: occurrence,
          snippetBefore: text.substring(ctxStart, idx).trimLeft(),
          matchText: text.substring(idx, idx + needle.length),
          snippetAfter: text.substring(idx + needle.length, ctxEnd).trimRight(),
        ));

        occurrence++;
        searchFrom = idx + needle.length;
      }
    }
    return results;
  }
}
