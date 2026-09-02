import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:codeoff/api.dart';
import 'package:codeoff/remote/remote_connection.dart';

void main() {
  test('reconnects through saved endpoints in order', () async {
    final endpoints = <String>[];
    final connection = RemoteConnection(
      '1.1.0',
      createClient: (endpoint, _) {
        endpoints.add(endpoint);
        return _FallbackRemoteApi(endpoint);
      },
    );

    await connection.connect(
      'http://lan',
      'token',
      endpoints: ['http://lan', 'https://public'],
    );
    await connection.reconnect();

    expect(endpoints, ['http://lan', 'https://public']);
    expect(connection.status, RemoteConnectionStatus.online);
    await connection.close();
  });

  test('owns connection status, events, and reconnects', () async {
    final client = _FakeRemoteApi();
    final connection = RemoteConnection(
      '1.1.0',
      createClient: (_, _) => client,
    );
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
  _FakeRemoteApi() : super('http://localhost', clientVersion: '1.1.0');

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

class _FallbackRemoteApi extends RemoteApi {
  _FallbackRemoteApi(this.endpoint) : super(endpoint, clientVersion: '1.1.0');

  final String endpoint;

  @override
  Stream<Map<String, dynamic>> events() => const Stream.empty();

  @override
  Future<dynamic> status() async => {
    'server': {'id': 'server'},
  };

  @override
  Future<void> reconnect({
    int attempts = 3,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    if (endpoint == 'http://lan') throw ApiException('LAN unavailable');
  }

  @override
  Future<void> close() async {}
}
