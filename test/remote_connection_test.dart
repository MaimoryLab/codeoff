import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:codex_remote/api.dart';
import 'package:codex_remote/remote/remote_connection.dart';

void main() {
  test('owns connection status, events, and reconnects', () async {
    final client = _FakeRemoteApi();
    final connection = RemoteConnection(createClient: (_, _) => client);
    final statuses = <RemoteConnectionStatus>[];
    final events = <Map<String, dynamic>>[];
    final statusSubscription = connection.statuses.listen(statuses.add);
    final eventSubscription = connection.events.listen(events.add);

    final status = await connection.connect('http://localhost', 'token');
    client.controller.add({'method': 'thread/status/changed'});
    await pumpEventQueue();

    expect(status, {
      'server': {'id': 'server'},
    });
    expect(events.single['method'], 'thread/status/changed');
    expect(statuses, [
      RemoteConnectionStatus.connecting,
      RemoteConnectionStatus.online,
    ]);

    client.controller.addError(ApiException('connection lost'));
    await pumpEventQueue();

    expect(client.reconnectCount, 1);
    expect(connection.status, RemoteConnectionStatus.online);
    expect(statuses, [
      RemoteConnectionStatus.connecting,
      RemoteConnectionStatus.online,
      RemoteConnectionStatus.reconnecting,
      RemoteConnectionStatus.online,
    ]);

    await connection.close();
    await statusSubscription.cancel();
    await eventSubscription.cancel();
    await client.controller.close();
  });
}

class _FakeRemoteApi extends RemoteApi {
  _FakeRemoteApi() : super('http://localhost');

  final controller = StreamController<Map<String, dynamic>>.broadcast();
  int reconnectCount = 0;

  @override
  Stream<Map<String, dynamic>> events() => controller.stream;

  @override
  Future<dynamic> status() async => {
    'server': {'id': 'server'},
  };

  @override
  Future<void> reconnect({
    int attempts = 3,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    reconnectCount++;
  }

  @override
  Future<void> close() async {}
}
