import 'dart:async';
import 'dart:convert';

import 'package:codeoff/api.dart';
import 'package:codeoff/home/remote_home_page.dart';
import 'package:codeoff/i18n.dart';
import 'package:codeoff/remote/remote_connection.dart';
import 'package:codeoff/storage/connection_store.dart';
import 'package:codeoff/storage/thread_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reopening a thread cancels its pending release', (tester) async {
    final api = await _openApp(tester);
    await tester.tap(find.text('Thread A').first);
    await _flush(tester);
    await tester.tap(find.byTooltip('Back'));
    await _flush(tester);
    expect(api.releases, ['A']);
    await tester.tap(find.text('Thread A').first);
    await _flush(tester);

    api.statusChanged();
    api.controller.add({
      'id': 17,
      'method': 'item/commandExecution/requestApproval',
      'params': {'threadId': 'A', 'itemId': 'cmd', 'command': 'echo hello'},
    });
    await _flush(tester);
    expect(find.text('Command approval'), findsOneWidget);
    expect(find.text('Continue conversation'), findsNothing);
    expect(api.releases, ['A']);

    // A real server release must still require an explicit resume.
    api.released();
    await _flush(tester);
    expect(find.text('Continue conversation'), findsOneWidget);
    await tester.tap(find.text('Continue conversation'));
    await _flush(tester);
    api.statusChanged();
    await _flush(tester);
    expect(api.resumes, ['A', 'A', 'A']);
    expect(api.releases, ['A']);
    expect(find.text('Continue conversation'), findsNothing);

    // Leaving again still queues a release that can be retried.
    await tester.tap(find.byTooltip('Back'));
    await _flush(tester);
    api.statusChanged();
    await _flush(tester);
    expect(api.releases, ['A', 'A', 'A']);
  });
}

Future<_ThreadApi> _openApp(WidgetTester tester) async {
  final api = _ThreadApi();
  final connection = RemoteConnection('1.3.0', createClient: (_, _) => api);
  FlutterSecureStorage.setMockInitialValues({
    'connections': jsonEncode([
      {
        'serverId': 'test',
        'name': 'Test',
        'endpoint': 'http://test',
        'token': 'test-only',
      },
    ]),
  });
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [AppLocalizationsDelegate()],
      home: RemoteHomePage(
        version: '1.3.0',
        connectionStore: ConnectionStore(const FlutterSecureStorage()),
        remoteConnection: connection,
        threadCache: _NoCache(),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    await tester.runAsync(() async {
      await connection.close();
      await api.controller.close();
    });
  });
  await _flush(tester);
  return api;
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _ThreadApi extends RemoteApi {
  _ThreadApi() : super('http://test', clientVersion: '1.3.0');

  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final releases = <String>[];
  final resumes = <String>[];

  void statusChanged() => controller.add({
    'method': 'thread/status/changed',
    'params': {
      'threadId': 'A',
      'status': {
        'type': 'active',
        'activeFlags': ['waitingOnApproval'],
      },
    },
  });

  void released() => controller.add({
    'method': 'thread/released',
    'params': {'threadId': 'A'},
  });

  @override
  Stream<Map<String, dynamic>> events() => controller.stream;

  @override
  Future<dynamic> status() async => {
    'server': {'id': 'test'},
  };

  @override
  Future<dynamic> threads({String? cursor, int? limit}) async => {
    'data': [
      {
        'id': 'A',
        'name': 'Thread A',
        'status': {'type': 'active'},
      },
    ],
  };

  @override
  Future<dynamic> thread(String threadId) async => {
    'thread': {
      'id': threadId,
      'turns': [
        {'id': 'turn-a', 'status': 'inProgress', 'items': []},
      ],
    },
  };

  @override
  Future<dynamic> resumeThread(String threadId) async {
    resumes.add(threadId);
    return thread(threadId);
  }

  @override
  Future<dynamic> releaseThread(String threadId) async {
    releases.add(threadId);
    // Active threads remain loaded after unsubscribe, so the server returns false.
    released();
    return {'released': false};
  }

  @override
  Future<void> close() async {}
}

class _NoCache extends ThreadCache {
  @override
  Future<ThreadCacheSnapshot> read(String serverId) async =>
      const ThreadCacheSnapshot(threads: [], history: {});

  @override
  void write(
    String serverId,
    List<Map<String, dynamic>> threads,
    Map<String, List<Map<String, dynamic>>> history,
  ) {}
}
