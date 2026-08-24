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

  test('maps permission modes to Codex turn policies', () {
    expect(RemotePermissionMode.requestApproval.approvalPolicy, 'on-request');
    expect(RemotePermissionMode.requestApproval.approvalsReviewer, 'user');
    expect(RemotePermissionMode.autoApprove.approvalPolicy, 'on-request');
    expect(RemotePermissionMode.autoApprove.approvalsReviewer, 'auto_review');
    expect(RemotePermissionMode.autoApprove.sandboxPolicy, 'workspaceWrite');
    expect(RemotePermissionMode.fullAccess.approvalPolicy, 'never');
    expect(RemotePermissionMode.fullAccess.sandboxPolicy, 'dangerFullAccess');
  });

  test('extracts approval reason and command or tool target', () {
    final command = approvalDetailsFrom({
      'method': 'item/commandExecution/requestApproval',
      'params': {
        'threadId': 'thread-42',
        'reason': 'Needs network access',
        'command': 'curl https://example.com',
      },
    });
    expect(
      approvalThreadIdFrom({
        'params': {'threadId': 'thread-42'},
      }),
      'thread-42',
    );
    expect(command.kind, 'Command');
    expect(command.reason, 'Needs network access');
    expect(command.target, 'curl https://example.com');

    final tool = approvalDetailsFrom({
      'method': 'item/tool/requestApproval',
      'params': {'server': 'github', 'tool': 'merge_pull_request'},
    });
    expect(tool.kind, 'Tool');
    expect(tool.target, 'github/merge_pull_request');
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
