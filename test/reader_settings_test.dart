import 'package:flutter_test/flutter_test.dart';
import 'package:epub_reader/models/reader_settings.dart';

void main() {
  test('기본 읽기 설정은 EPUB 원본 CSS를 보존한다', () {
    final settings = ReaderSettings.defaults();

    expect(settings.fontFamily, isNull);
    expect(settings.fontSizePercent, isNull);
    expect(settings.horizontalMarginPx, isNull);
    expect(settings.themeMode, ReaderThemeMode.original);
  });
}
