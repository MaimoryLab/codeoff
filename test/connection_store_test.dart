import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:codeoff/storage/connection_store.dart';

void main() {
  test('keeps ordered endpoints and supports legacy records', () {
    expect(
      connectionEndpoints({
        'endpoint': 'https://public.example',
        'endpoints': jsonEncode([
          'http://192.168.1.2:11037',
          'https://public.example',
        ]),
      }),
      ['http://192.168.1.2:11037', 'https://public.example'],
    );
    expect(connectionEndpoints({'endpoint': 'http://legacy.example'}), [
      'http://legacy.example',
    ]);
  });

  test('owns saved server records and permission preference', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final store = ConnectionStore(storage);
    final first = {
      'serverId': 'one',
      'name': 'One',
      'endpoint': 'http://one',
      'token': 'token-one',
    };
    final second = {
      'serverId': 'two',
      'name': 'Two',
      'endpoint': 'http://two',
      'token': 'token-two',
    };

    await store.remember(first);
    await store.remember(second);
    await store.update(first, {'name': 'Updated'});
    await store.setPermissionMode('fullAccess');

    final restored = ConnectionStore(storage);
    await restored.load();
    expect(restored.connections.map((item) => item['serverId']), [
      'two',
      'one',
    ]);
    expect(restored.connections.last['name'], 'Updated');
    expect(restored.permissionMode, 'fullAccess');

    await restored.remove(restored.connections.first);
    expect(restored.connections.single['serverId'], 'one');
  });
}
