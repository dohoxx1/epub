import 'package:flutter_test/flutter_test.dart';
import 'package:epub_reader/main.dart';

void main() {
  testWidgets('app root builds', (tester) async {
    await tester.pumpWidget(const EpubReaderApp());
    expect(find.text('내 서재'), findsOneWidget);
  });
}
