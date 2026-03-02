import 'package:flutter_test/flutter_test.dart';

import 'package:ztrans/main.dart';
import 'package:ztrans/src/settings/settings_provider.dart';

void main() {
  testWidgets('App builds without error', (WidgetTester tester) async {
    await tester.pumpWidget(ZTransApp(settings: SettingsProvider()));
    expect(find.text('翻译结果将显示在此处'), findsOneWidget);
  });
}
