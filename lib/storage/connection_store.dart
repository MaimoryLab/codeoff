import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _connectionsKey = 'connections';
const _permissionModeKey = 'permission_mode';

List<Map<String, String>> rememberRemoteConnection(
  List<Map<String, String>> connections,
  Map<String, String> record,
) => [
  record,
  ...connections.where((item) => item['serverId'] != record['serverId']),
];

class ConnectionStore {
  const ConnectionStore(this.storage);

  final FlutterSecureStorage storage;

  Future<List<Map<String, String>>> loadConnections() async {
    final saved = await storage.read(key: _connectionsKey);
    if (saved == null || saved.isEmpty) return [];
    final value = jsonDecode(saved);
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry('$key', '$value')))
        .where(
          (item) =>
              item['endpoint']?.isNotEmpty == true &&
              item['token']?.isNotEmpty == true,
        )
        .toList();
  }

  Future<void> saveConnections(List<Map<String, String>> connections) =>
      storage.write(key: _connectionsKey, value: jsonEncode(connections));

  Future<String?> loadPermissionMode() => storage.read(key: _permissionModeKey);

  Future<void> savePermissionMode(String mode) =>
      storage.write(key: _permissionModeKey, value: mode);
}
