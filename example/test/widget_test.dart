import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gapless_loop_example/main.dart';

void main() {
  testWidgets('App builds without errors', (WidgetTester tester) async {
    await tester.pumpWidget(const GaplessLoopApp());
    expect(find.text('Gapless Loop Demo'), findsWidgets);
  });
}
