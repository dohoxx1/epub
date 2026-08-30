import '../models/reader_settings.dart';

/// 사용자 설정에 따라 책의 원본 CSS 위에 덧씌울 override CSS를 만든다.
/// 항목별로 값이 null이면(= "원본 사용") 그 항목에 대한 규칙은 아예 생성하지 않는다.
///
/// 폰트 크기는 표준 font-size 대신 `zoom`을 사용한다. EPUB 안에는 px/pt로
/// 고정된 글자 크기가 많아서 font-size % 조정만으로는 반영이 안 되는 경우가 많고,
/// zoom은 레이아웃 전체(이미지 포함)를 비율대로 키워줘서 브라우저 확대와 동일하게 동작한다.
String buildReaderOverrideCss(ReaderSettings s) {
  final buffer = StringBuffer();
  final (bg, text) = s.resolvedThemeColors;

  if (bg != null) {
    buffer.writeln('html, body { background-color: ${_hex(bg)} !important; }');
  }
  if (text != null) {
    buffer.writeln('body, body * { color: ${_hex(text)} !important; }');
  }
  if (s.fontFamily != null && s.fontFamily!.isNotEmpty) {
    buffer.writeln(
        "body, body * { font-family: ${s.fontFamily}, sans-serif !important; }");
  }
  if (s.fontSizePercent != null) {
    // body가 아니라 wrapper(#__reader_content_wrap__)에 zoom을 건다. body는
    // 컬럼(페이지) 폭 계산 기준이 되는 요소라서, 여기에 zoom을 직접 걸면 실제
    // 렌더링되는 컬럼 폭이 window.innerWidth와 어긋나 탭으로 넘길 때 페이지
    // 사이에 어중간하게 걸치는 문제가 생긴다(실제 겪은 버그). wrapper에만 걸면
    // 컬럼 경계(body 기준)는 그대로 두고 그 안의 내용만 확대/축소된다.
    buffer.writeln(
        '#__reader_content_wrap__ { zoom: ${s.fontSizePercent}% !important; }');
  }
  if (s.horizontalMarginPx != null) {
    final px = s.horizontalMarginPx!.toStringAsFixed(0);
    // body가 아니라 JS가 만든 wrapper(#__reader_content_wrap__)에 여백을 준다.
    // body에 직접 padding을 주면 컬럼(페이지) 폭 계산과 서로 간섭하는 문제가 있어서
    // 컬럼 계산 기준(body)과 여백 적용 대상(wrapper)을 완전히 분리했다.
    buffer.writeln(
        '#__reader_content_wrap__ { padding-left: ${px}px !important; padding-right: ${px}px !important; }');
  }
  if (s.verticalMarginPx != null) {
    final px = s.verticalMarginPx!.toStringAsFixed(0);
    // 마찬가지로 wrapper에만 적용. box-decoration-break:clone(kPaginationCss에서 설정)
    // 덕분에 이 여백이 첫/마지막 페이지뿐 아니라 모든 페이지 상하에 똑같이 반복된다.
    buffer.writeln(
        '#__reader_content_wrap__ { padding-top: ${px}px !important; padding-bottom: ${px}px !important; }');
  }
  if (s.lineHeightPercent != null) {
    buffer.writeln(
        'body, body * { line-height: ${s.lineHeightPercent}% !important; }');
  }
  if (s.paragraphSpacingPx != null) {
    final px = s.paragraphSpacingPx!.toStringAsFixed(0);
    buffer.writeln(
        'p { margin-top: 0 !important; margin-bottom: ${px}px !important; }');
  }
  return buffer.toString();
}

String _hex(int argb) {
  final rgb = argb & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}
