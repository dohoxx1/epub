import 'package:flutter_test/flutter_test.dart';
import 'package:epub_reader/main.dart';

void main() {
  test('app root can be constructed', () {
    const app = EpubReaderApp();
    expect(app, isA<EpubReaderApp>());
  });
}
