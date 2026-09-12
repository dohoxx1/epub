/// 배경색/글자색을 함께 묶은 "테마" 선택지.
/// original: 원본 CSS 그대로 (아무것도 override 안 함)
/// light / dark: 미리 정한 기본 라이트/다크 팔레트
/// custom: 사용자가 직접 고른 배경색+글자색
enum ReaderThemeMode { original, light, dark, custom }

const int kLightBackground = 0xFFF5F1E8;
const int kLightText = 0xFF282722;
const int kDarkBackground = 0xFF242421;
const int kDarkText = 0xFFE9E4D8;

const List<int> kBackgroundPalette = [
  0xFFF5F1E8,
  0xFFFFFFFF,
  0xFFEFEFEF,
  0xFFE3E8DE,
  0xFF242421,
  0xFF292C31,
];

const List<int> kTextPalette = [
  0xFF282722,
  0xFF1A1A1A,
  0xFF4A4842,
  0xFFE9E4D8,
  0xFFFFFFFF,
  0xFFB8AA8E,
];

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
  final bool eInkGrainEnabled;
  final int whitePointReductionPercent;

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
    this.eInkGrainEnabled = true,
    this.whitePointReductionPercent = 12,
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
    bool? eInkGrainEnabled,
    int? whitePointReductionPercent,
  }) {
    return ReaderSettings(
      fontFamily: fontFamily != null ? fontFamily() : this.fontFamily,
      fontSizePercent: fontSizePercent != null ? fontSizePercent() : this.fontSizePercent,
      horizontalMarginPx: horizontalMarginPx != null ? horizontalMarginPx() : this.horizontalMarginPx,
      verticalMarginPx: verticalMarginPx != null ? verticalMarginPx() : this.verticalMarginPx,
      lineHeightPercent: lineHeightPercent != null ? lineHeightPercent() : this.lineHeightPercent,
      paragraphSpacingPx: paragraphSpacingPx != null ? paragraphSpacingPx() : this.paragraphSpacingPx,
      themeMode: themeMode ?? this.themeMode,
      customBackgroundColorValue: customBackgroundColorValue != null ? customBackgroundColorValue() : this.customBackgroundColorValue,
      customTextColorValue: customTextColorValue != null ? customTextColorValue() : this.customTextColorValue,
      eInkGrainEnabled: eInkGrainEnabled ?? this.eInkGrainEnabled,
      whitePointReductionPercent: whitePointReductionPercent ?? this.whitePointReductionPercent,
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
