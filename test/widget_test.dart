import 'package:flutter_test/flutter_test.dart';

import 'package:codex_remote/main.dart';

void main() {
  test('parses Unix timestamps as dates', () {
    expect(
      parseRemoteTimestamp(1787301205),
      DateTime.fromMillisecondsSinceEpoch(1787301205000, isUtc: true).toLocal(),
    );
    expect(
      parseRemoteTimestamp('1787301205000'),
      DateTime.fromMillisecondsSinceEpoch(1787301205000, isUtc: true).toLocal(),
    );
  });

  testWidgets('renders remote control sections', (WidgetTester tester) async {
    await tester.pumpWidget(const CodexRemoteApp());
    expect(find.text('Codex Remote'), findsOneWidget);
    expect(find.text('Desktop endpoint'), findsOneWidget);
    expect(find.text('Pair new device'), findsOneWidget);
  });
}
