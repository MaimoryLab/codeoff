import 'package:flutter_test/flutter_test.dart';

import 'package:codex_remote/api.dart';
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

  test('sorts active threads ahead of newer idle threads', () {
    final threads = <Map<String, dynamic>>[
      {
        'id': 'new-idle',
        'updatedAt': 200,
        'status': {'type': 'idle'},
      },
      {
        'id': 'old-active',
        'updatedAt': 100,
        'status': {'type': 'active'},
      },
    ]..sort(compareRemoteThreads);

    expect(threads.map((thread) => thread['id']), ['old-active', 'new-idle']);
  });

  test('refreshes history after an active thread becomes idle', () {
    final active = <Map<String, dynamic>>[
      {
        'id': 'selected',
        'status': {'type': 'active'},
      },
    ];
    final idle = <Map<String, dynamic>>[
      {
        'id': 'selected',
        'status': {'type': 'idle'},
      },
    ];

    expect(shouldRefreshRemoteHistory('selected', active, idle), isTrue);
    expect(shouldRefreshRemoteHistory('selected', idle, idle), isFalse);
  });

  test('finds the in-progress turn in a thread response', () {
    final response = {
      'thread': {
        'turns': [
          {'id': 'done', 'status': 'completed'},
          {'id': 'active', 'status': 'inProgress'},
        ],
      },
    };

    expect(activeTurnIdFrom(response), 'active');
  });

  test('does not treat a business error as a disconnect', () {
    expect(
      ApiException('conflict', statusCode: 409).isConnectionFailure,
      false,
    );
    expect(ApiException('offline').isConnectionFailure, true);
  });

  testWidgets('renders remote control sections', (WidgetTester tester) async {
    await tester.pumpWidget(const CodexRemoteApp());
    expect(find.text('Codex Remote'), findsOneWidget);
    expect(find.text('Desktop endpoint'), findsOneWidget);
    expect(find.text('Pair new device'), findsOneWidget);
  });
}
