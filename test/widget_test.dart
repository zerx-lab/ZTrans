import 'package:flutter_test/flutter_test.dart';

import 'package:ztrans/main.dart';

void main() {
  testWidgets('App builds without error', (WidgetTester tester) async {
    await tester.pumpWidget(const ZTransApp());
    expect(find.text('翻译结果将显示在此处'), findsOneWidget);
  });
}
