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

  test('summarizes processing from a polled thread snapshot', () {
    expect(
      processingSummaryFromThread({
        'thread': {
          'turns': [
            {
              'status': 'inProgress',
              'items': [
                {
                  'type': 'commandExecution',
                  'command': 'flutter test',
                  'status': 'inProgress',
                },
              ],
            },
          ],
        },
      }),
      'Running: flutter test',
    );
    expect(
      processingSummaryFromThread({
        'status': 'inProgress',
        'items': [
          {
            'type': 'reasoning',
            'summary': ['Checking the failing test', 'Tracing its caller'],
          },
        ],
      }),
      'Thinking: Checking the failing test Tracing its caller',
    );
    expect(
      processingSummaryFromThread({'status': 'completed', 'items': []}),
      isEmpty,
    );
  });

  test('does not treat a business error as a disconnect', () {
    final conflict = ApiException('conflict', statusCode: 409);
    expect(conflict.isConnectionFailure, false);
    expect(conflict.isConflict, true);
    expect(ApiException('offline').isConnectionFailure, true);
  });

  test('accepts only external HTTP links', () {
    expect(externalHttpUri('https://example.com/docs')?.host, 'example.com');
    expect(externalHttpUri('http://example.com'), isNotNull);
    expect(externalHttpUri('javascript:alert(1)'), isNull);
    expect(externalHttpUri('/relative'), isNull);
  });

  test('summarizes reasoning and tool items', () {
    expect(
      processingSummaryFromItem({
        'type': 'commandExecution',
        'command': 'flutter test',
      }),
      'Running: flutter test',
    );
    expect(
      processingSummaryFromItem({
        'type': 'mcpToolCall',
        'server': 'docs',
        'tool': 'search',
      }),
      'Calling: docs/search',
    );
    expect(
      processingSummaryFromItem({'type': 'webSearch'}),
      'Searching the web',
    );
  });

  testWidgets('renders remote control sections', (WidgetTester tester) async {
    await tester.pumpWidget(const CodexRemoteApp());
    expect(find.text('Codex Remote'), findsOneWidget);
    expect(find.text('Desktop endpoint'), findsOneWidget);
    expect(find.text('Pair new device'), findsOneWidget);
  });
}
