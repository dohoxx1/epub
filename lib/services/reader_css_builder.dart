import '../models/reader_settings.dart';

/// 사용자 설정에 따라 책의 원본 CSS 위에 덧씌울 override CSS를 만든다.
/// 항목별로 값이 null이면(= "원본 사용") 그 항목에 대한 규칙은 아예 생성하지 않는다.
String buildReaderOverrideCss(ReaderSettings s) {
  final buffer = StringBuffer();
  final (bg, text) = s.resolvedThemeColors;
  final adjustedBg = bg == null ? null : _reduceWhitePoint(bg, s.whitePointReductionPercent);

  if (adjustedBg != null) {
    buffer.writeln('html, body { background-color: ${_hex(adjustedBg)} !important; }');
  }
  if (text != null) {
    buffer.writeln('body, body * { color: ${_hex(text)} !important; }');
  }
  if (s.fontFamily != null && s.fontFamily!.isNotEmpty) {
    buffer.writeln("body, body * { font-family: ${s.fontFamily}, sans-serif !important; }");
  }
  if (s.fontSizePercent != null) {
    buffer.writeln('#__reader_content_wrap__ { zoom: ${s.fontSizePercent}% !important; }');
  }
  if (s.horizontalMarginPx != null) {
    final px = s.horizontalMarginPx!.toStringAsFixed(0);
    buffer.writeln('#__reader_content_wrap__ { padding-left: ${px}px !important; padding-right: ${px}px !important; }');
  }
  if (s.verticalMarginPx != null) {
    final px = s.verticalMarginPx!.toStringAsFixed(0);
    buffer.writeln('#__reader_content_wrap__ { padding-top: ${px}px !important; padding-bottom: ${px}px !important; }');
  }
  if (s.lineHeightPercent != null) {
    buffer.writeln('body, body * { line-height: ${s.lineHeightPercent}% !important; }');
  }
  if (s.paragraphSpacingPx != null) {
    final px = s.paragraphSpacingPx!.toStringAsFixed(0);
    buffer.writeln('p { margin-top: 0 !important; margin-bottom: ${px}px !important; }');
  }

  // 실제 텍스트에는 filter를 적용하지 않고, 화면 전체에만 미세한 흑백 입자를 얹는다.
  // 전자잉크 패널의 종이 같은 표면감을 흉내 내며 선택 UX에도 영향을 주지 않는다.
  if (bg != null && s.eInkGrainEnabled) {
    final dark = _relativeLuminance(bg) < 0.25;
    final opacity = dark ? '0.022' : '0.032';
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
  background-size: 128px 128px !important;
}
''');
  }

  return buffer.toString();
}

const _grainDataUri =
    'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22128%22 height=%22128%22%3E%3Cfilter id=%22n%22 x=%220%22 y=%220%22 width=%22100%25%22 height=%22100%25%22%3E%3CfeTurbulence type=%22fractalNoise%22 baseFrequency=%220.82%22 numOctaves=%223%22 stitchTiles=%22stitch%22/%3E%3C/filter%3E%3Crect width=%22100%25%22 height=%22100%25%22 filter=%22url(%23n)%22 opacity=%220.72%22/%3E%3C/svg%3E';

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

int _reduceWhitePoint(int argb, int percent) {
  final p = percent.clamp(0, 40) / 100.0;
  final r = ((argb >> 16) & 0xFF) * (1.0 - p);
  final g = ((argb >> 8) & 0xFF) * (1.0 - p);
  final b = (argb & 0xFF) * (1.0 - p);
  return 0xFF000000 |
      (r.round() << 16) |
      (g.round() << 8) |
      b.round();
}
