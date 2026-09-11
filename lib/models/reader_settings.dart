/// 배경색/글자색을 함께 묶은 "테마" 선택지.
/// original: 원본 CSS 그대로 (아무것도 override 안 함)
/// light / dark: 미리 정한 기본 라이트/다크 팔레트
/// custom: 사용자가 직접 고른 배경색+글자색
enum ReaderThemeMode { original, light, dark, custom }

const int kLightBackground = 0xFFF5F1E8;
const int kLightText = 0xFF282722;
const int kDarkBackground = 0xFF242421;
const int kDarkText = 0xFFE9E4D8;

/// 사용자가 고를 수 있는 배경색/글자색 팔레트 (커스텀 테마용).
const List<int> kBackgroundPalette = [
  0xFFF5F1E8, // 따뜻한 종이
  0xFFFFFFFF, // 흰색
  0xFFEFEFEF, // 연회색
  0xFFE3E8DE, // 세이지
  0xFF242421, // 잉크 블랙
  0xFF292C31, // 차콜 블루
];

const List<int> kTextPalette = [
  0xFF282722, // 잉크
  0xFF1A1A1A, // 검정
  0xFF4A4842, // 부드러운 회색
  0xFFE9E4D8, // 따뜻한 연회색
  0xFFFFFFFF, // 흰색
  0xFFB8AA8E, // 세피아
];

/// Android WebView가 항상 지원하는 CSS 제네릭 폰트 패밀리.
const List<(String label, String cssValue)> kFontChoices = [
  ('원본 폰트', ''),
  ('고딕(산세리프)', 'sans-serif'),
  ('명조(세리프)', 'serif'),
  ('고정폭', 'monospace'),
  ('필기체', 'cursive'),
];

class ReaderSettings {
  final String? fontFamily;
  final int? fontSizePercent;
  final double? horizontalMarginPx;
  final double? verticalMarginPx;
  final int? lineHeightPercent;
  final double? paragraphSpacingPx;
  final ReaderThemeMode themeMode;
  final int? customBackgroundColorValue;
  final int? customTextColorValue;

  const ReaderSettings({
    this.fontFamily,
    this.fontSizePercent,
    this.horizontalMarginPx,
    this.verticalMarginPx,
    this.lineHeightPercent,
    this.paragraphSpacingPx,
    this.themeMode = ReaderThemeMode.light,
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
