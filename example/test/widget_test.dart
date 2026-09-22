import 'package:flutter_test/flutter_test.dart';
import 'package:web_update_guard_example/main.dart';

void main() {
  testWidgets('demo renders and reports unsupported off the web', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DemoApp());
    await tester.pumpAndSettle();
    expect(find.text('unsupported'), findsOneWidget);
    expect(find.text('Check now'), findsOneWidget);
    await tester.tap(find.text('whenIdle'));
    await tester.pumpAndSettle();
    expect(find.text('unsupported'), findsOneWidget);
  });
}
