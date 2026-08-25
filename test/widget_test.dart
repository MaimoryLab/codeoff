import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:codex_remote/api.dart';
import 'package:codex_remote/home/remote_home_page.dart'
    show startPeriodicRefresh;
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

  test('disconnects after three unanswered heartbeats', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var heartbeats = 0;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) {
        final message = jsonDecode('$data');
        if (message is Map && message['method'] == 'heartbeat') heartbeats++;
      });
    });
    final api = RemoteApi(
      'http://${server.address.address}:${server.port}',
      heartbeatInterval: const Duration(milliseconds: 20),
    );
    final disconnected = Completer<Object>();
    final subscription = api.events().listen(
      (_) {},
      onError: (Object error) => disconnected.complete(error),
    );

    final error = await disconnected.future.timeout(const Duration(seconds: 2));
    expect(error.toString(), contains('Heartbeat acknowledgement timed out'));
    expect(heartbeats, 3);

    await subscription.cancel();
    await api.close();
    await server.close(force: true);
  });

  test('reconnect makes exactly three attempts', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var attempts = 0;
    server.listen((request) async {
      attempts++;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    final api = RemoteApi('http://${server.address.address}:${server.port}');

    await expectLater(
      api.reconnect(retryDelay: Duration.zero),
      throwsA(isA<ApiException>()),
    );
    expect(attempts, 3);

    await api.close();
    await server.close(force: true);
  });

  test('periodic refresh stops when its view becomes inactive', () async {
    var active = true;
    var refreshes = 0;
    final reachedThree = Completer<void>();
    final timer = startPeriodicRefresh(
      interval: const Duration(milliseconds: 5),
      active: () => active,
      refresh: () async {
        refreshes++;
        if (refreshes == 3) {
          active = false;
          reachedThree.complete();
        }
      },
    );
    addTearDown(timer.cancel);

    await reachedThree.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(refreshes, 3);
    expect(timer.isActive, false);
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
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Codex Remote'), findsOneWidget);
    expect(find.text('Desktop endpoint'), findsOneWidget);
    expect(find.text('Connect to a desktop'), findsOneWidget);
    expect(find.text('Connection history'), findsOneWidget);
  });

  testWidgets('renders Chinese Material controls', (WidgetTester tester) async {
    await tester.pumpWidget(const CodexRemoteApp());
    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('桌面端地址'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
