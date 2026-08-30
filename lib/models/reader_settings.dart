/// 배경색/글자색을 함께 묶은 "테마" 선택지.
/// original: 원본 CSS 그대로 (아무것도 override 안 함)
/// light / dark: 미리 정한 기본 라이트/다크 팔레트
/// custom: 사용자가 직접 고른 배경색+글자색
enum ReaderThemeMode { original, light, dark, custom }

const int kLightBackground = 0xFFFFFFFF;
const int kLightText = 0xFF1A1A1A;
const int kDarkBackground = 0xFF121212;
const int kDarkText = 0xFFE0E0E0;

/// 사용자가 고를 수 있는 배경색/글자색 팔레트 (커스텀 테마용).
/// 색상 선택기 없이 미리 정한 팔레트에서 고르는 방식으로 단순하게 구현.
const List<int> kBackgroundPalette = [
  0xFFFFFFFF, // 흰색
  0xFFF5F0E6, // 아이보리(종이 느낌)
  0xFFEFEFEF, // 연회색
  0xFFD9E8D8, // 연두(눈 편함)
  0xFF121212, // 검정
  0xFF1E1E2E, // 다크 네이비
];

const List<int> kTextPalette = [
  0xFF000000, // 검정
  0xFF1A1A1A, // 진회색
  0xFF3B3B3B, // 회색
  0xFFE0E0E0, // 연회색(다크 배경용)
  0xFFFFFFFF, // 흰색(다크 배경용)
  0xFFC9A26D, // 세피아 톤
];

/// Android WebView가 항상 지원하는 CSS 제네릭 폰트 패밀리.
/// (특정 폰트 파일을 앱에 내장하지 않아도 기기에 상관없이 안전하게 동작함)
const List<(String label, String cssValue)> kFontChoices = [
  ('원본 폰트', ''), // UI 표시용, 실제로는 fontFamily=null 처리
  ('고딕(산세리프)', 'sans-serif'),
  ('명조(세리프)', 'serif'),
  ('고정폭', 'monospace'),
  ('필기체', 'cursive'),
];

class ReaderSettings {
  /// null이면 "원본 폰트 사용". 아니면 CSS font-family 값 (예: 'serif').
  final String? fontFamily;

  /// null이면 "원본 크기 사용". 아니면 원본 대비 퍼센트 (예: 130 = 130%). 범위 70~250.
  final int? fontSizePercent;

  /// null이면 "원본 여백 사용". 아니면 좌우 여백(px). 범위 0~48.
  final double? horizontalMarginPx;

  /// null이면 "원본 여백 사용". 아니면 상하 여백(px). 범위 0~64.
  final double? verticalMarginPx;

  /// null이면 "원본 줄간격 사용". 아니면 퍼센트 (예: 150 = 1.5줄간격). 범위 100~250.
  final int? lineHeightPercent;

  /// null이면 "원본 문단간격 사용". 아니면 문단 사이 여백(px). 범위 0~32.
  final double? paragraphSpacingPx;

  final ReaderThemeMode themeMode;
  final int? customBackgroundColorValue; // ARGB int, themeMode==custom일 때만 사용
  final int? customTextColorValue;

  const ReaderSettings({
    this.fontFamily,
    this.fontSizePercent,
    this.horizontalMarginPx,
    this.verticalMarginPx,
    this.lineHeightPercent,
    this.paragraphSpacingPx,
    this.themeMode = ReaderThemeMode.original,
    this.customBackgroundColorValue,
    this.customTextColorValue,
  });

  factory ReaderSettings.defaults() => const ReaderSettings();

  ReaderSettings copyWith({
    String? Function()? fontFamily,
    int? Function()? fontSizePercent,
    double? Function()? horizontalMarginPx,
    double? Function()? verticalMarginPx,
    int? Function()? lineHeightPercent,
    double? Function()? paragraphSpacingPx,
    ReaderThemeMode? themeMode,
    int? Function()? customBackgroundColorValue,
    int? Function()? customTextColorValue,
  }) {
    return ReaderSettings(
      fontFamily: fontFamily != null ? fontFamily() : this.fontFamily,
      fontSizePercent:
          fontSizePercent != null ? fontSizePercent() : this.fontSizePercent,
      horizontalMarginPx: horizontalMarginPx != null
          ? horizontalMarginPx()
          : this.horizontalMarginPx,
      verticalMarginPx:
          verticalMarginPx != null ? verticalMarginPx() : this.verticalMarginPx,
      lineHeightPercent: lineHeightPercent != null
          ? lineHeightPercent()
          : this.lineHeightPercent,
      paragraphSpacingPx: paragraphSpacingPx != null
          ? paragraphSpacingPx()
          : this.paragraphSpacingPx,
      themeMode: themeMode ?? this.themeMode,
      customBackgroundColorValue: customBackgroundColorValue != null
          ? customBackgroundColorValue()
          : this.customBackgroundColorValue,
      customTextColorValue: customTextColorValue != null
          ? customTextColorValue()
          : this.customTextColorValue,
    );
  }

  /// 현재 테마 설정에 따라 실제로 적용할 배경색/글자색 (ARGB int).
  /// 원본 모드면 (null, null) → CSS에서 색상 override를 아예 안 함.
  (int?, int?) get resolvedThemeColors {
    switch (themeMode) {
      case ReaderThemeMode.original:
        return (null, null);
      case ReaderThemeMode.light:
        return (kLightBackground, kLightText);
      case ReaderThemeMode.dark:
        return (kDarkBackground, kDarkText);
      case ReaderThemeMode.custom:
        return (customBackgroundColorValue, customTextColorValue);
    }
  }
}
