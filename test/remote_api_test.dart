import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeoff/api.dart';
import 'package:flutter_test/flutter_test.dart';

const _testVersion = '1.1.0';

void main() {
  test('streams uploads over authenticated HTTP with progress', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<({List<int> data, String? authorization})>();
    server.listen((request) async {
      final data = await request.fold<List<int>>(
        [],
        (data, chunk) => data..addAll(chunk),
      );
      received.complete((
        data: data,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
      ));
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'path': '/tmp/uploaded.txt'}));
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
    });
    final api = RemoteApi(
      'http://${server.address.address}:${server.port}',
      clientVersion: _testVersion,
      token: 'secret',
    );
    addTearDown(api.close);

    final progress = <int>[];
    final uploaded = await api.upload(
      'upload.txt',
      Stream<List<int>>.fromIterable([
        [1, 2],
        [3, 4, 5],
      ]),
      onProgress: progress.add,
    );

    expect(progress, [2, 5]);
    final request = await received.future;
    expect(request.data, [1, 2, 3, 4, 5]);
    expect(request.authorization, 'Bearer secret');
    expect(uploaded.path, '/tmp/uploaded.txt');
  });

  for (final serverVersion in [minServerVersion, 'dev']) {
    test('accepts compatible server version $serverVersion', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers
          ..set('X-Codeoff-Server-Version', serverVersion)
          ..set('X-Codeoff-Min-Client-Version', _testVersion);
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((data) {
          final message = jsonDecode('$data') as Map<String, dynamic>;
          socket.add(jsonEncode({'id': message['id'], 'result': {}}));
        });
      });
      addTearDown(() => server.close(force: true));
      final api = RemoteApi(
        'http://${server.address.address}:${server.port}',
        clientVersion: _testVersion,
      );
      addTearDown(api.close);

      await api.status();
    });
  }

  for (final versions in <(String?, String?)>[
    ('0.0.9', _testVersion),
    (minServerVersion, '2.0.0'),
    (null, null),
  ]) {
    test('requires an upgrade for incompatible versions $versions', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (versions.$1 != null) {
          request.response.headers.set(
            'X-Codeoff-Server-Version',
            versions.$1!,
          );
        }
        if (versions.$2 != null) {
          request.response.headers.set(
            'X-Codeoff-Min-Client-Version',
            versions.$2!,
          );
        }
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {});
      });
      addTearDown(() => server.close(force: true));
      final api = RemoteApi(
        'http://${server.address.address}:${server.port}',
        clientVersion: _testVersion,
      );
      addTearDown(api.close);

      await expectLater(
        api.status(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.upgradeRequired,
            'upgradeRequired',
            isTrue,
          ),
        ),
      );
    });
  }

  test('times out stalled requests and closes the connection', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers
        ..set('X-Codeoff-Server-Version', minServerVersion)
        ..set('X-Codeoff-Min-Client-Version', _testVersion);
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
    });
    addTearDown(() => server.close(force: true));
    final api = RemoteApi(
      'http://${server.address.address}:${server.port}',
      clientVersion: _testVersion,
      requestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(api.close);

    await expectLater(
      api.status(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          'Request timed out',
        ),
      ),
    );
  });
}
