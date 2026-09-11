import '../models/reader_settings.dart';

/// 사용자 설정에 따라 책의 원본 CSS 위에 덧씌울 override CSS를 만든다.
/// 항목별로 값이 null이면(= "원본 사용") 그 항목에 대한 규칙은 아예 생성하지 않는다.
///
/// 리더에는 전자잉크 화면의 종이 같은 입자감을 흉내 내는 아주 미세한
/// monochrome grain을 별도의 overlay로 추가한다. 본문 자체에 filter를 거는 대신
/// pointer-events:none인 pseudo-element를 사용해 텍스트 선명도와 선택 UX를 보존한다.
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
    buffer.writeln(
        '#__reader_content_wrap__ { zoom: ${s.fontSizePercent}% !important; }');
  }
  if (s.horizontalMarginPx != null) {
    final px = s.horizontalMarginPx!.toStringAsFixed(0);
    buffer.writeln(
        '#__reader_content_wrap__ { padding-left: ${px}px !important; padding-right: ${px}px !important; }');
  }
  if (s.verticalMarginPx != null) {
    final px = s.verticalMarginPx!.toStringAsFixed(0);
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

  // A very light monochrome grain gives the paper surface a low-frequency
  // e-ink texture without applying CSS filters to the actual text.
  // It is deliberately disabled in original-theme mode so EPUBs that provide
  // their own visual treatment remain untouched.
  if (bg != null) {
    final dark = _relativeLuminance(bg) < 0.25;
    final opacity = dark ? '0.020' : '0.030';
    final blend = dark ? 'screen' : 'multiply';
    buffer.writeln('''
#__reader_content_wrap__::after {
  content: "" !important;
  position: fixed !important;
  inset: 0 !important;
  width: 100vw !important;
  height: 100vh !important;
  pointer-events: none !important;
  z-index: 2147483647 !important;
  opacity: $opacity !important;
  mix-blend-mode: $blend !important;
  background-image: url("$_grainDataUri") !important;
  background-repeat: repeat !important;
  background-size: 180px 180px !important;
}
''');
  }

  return buffer.toString();
}

const _grainDataUri =
    'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22180%22 height=%22180%22%3E%3Cfilter id=%22n%22 x=%220%22 y=%220%22 width=%22100%25%22 height=%22100%25%22%3E%3CfeTurbulence type=%22fractalNoise%22 baseFrequency=%220.72%22 numOctaves=%223%22 stitchTiles=%22stitch%22/%3E%3C/filter%3E%3Crect width=%22100%25%22 height=%22100%25%22 filter=%22url(%23n)%22 opacity=%220.72%22/%3E%3C/svg%3E';

String _hex(int argb) {
  final rgb = argb & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}

double _relativeLuminance(int argb) {
  final r = ((argb >> 16) & 0xFF) / 255.0;
  final g = ((argb >> 8) & 0xFF) / 255.0;
  final b = (argb & 0xFF) / 255.0;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
