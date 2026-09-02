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

List<String> connectionEndpoints(Map<String, String> record) {
  final value = record['endpoints'];
  dynamic endpoints;
  if (value != null && value.isNotEmpty) {
    try {
      endpoints = jsonDecode(value);
    } on FormatException {
      endpoints = null;
    }
  }
  final candidates = endpoints is List
      ? endpoints.whereType<String>()
      : const <String>[];
  return {
    ...candidates,
    if (record['endpoint']?.isNotEmpty == true) record['endpoint']!,
  }.toList();
}

class ConnectionStore {
  ConnectionStore(this.storage);

  final FlutterSecureStorage storage;
  List<Map<String, String>> _connections = [];
  String? permissionMode;

  List<Map<String, String>> get connections => List.unmodifiable(_connections);

  Future<void> load() async {
    try {
      final saved = await storage.read(key: _connectionsKey);
      final value = saved == null || saved.isEmpty ? null : jsonDecode(saved);
      _connections = value is List
          ? value
                .whereType<Map>()
                .map(
                  (item) =>
                      item.map((key, value) => MapEntry('$key', '$value')),
                )
                .where(
                  (item) =>
                      item['endpoint']?.isNotEmpty == true &&
                      item['token']?.isNotEmpty == true,
                )
                .toList()
          : [];
      permissionMode = await storage.read(key: _permissionModeKey);
    } catch (_) {
      // Stored settings are optional; callers can enter them again.
    }
  }

  Future<void> remember(Map<String, String> record) async {
    _connections = rememberRemoteConnection(_connections, record);
    await _saveConnections();
  }

  Future<Map<String, String>?> update(
    Map<String, String> record,
    Map<String, String> changes,
  ) async {
    final index = _connections.indexOf(record);
    if (index == -1) return null;
    final updated = {...record, ...changes};
    _connections = [..._connections]..[index] = updated;
    await _saveConnections();
    return updated;
  }

  Future<void> remove(Map<String, String> record) async {
    _connections = [..._connections]..remove(record);
    await _saveConnections();
  }

  Future<void> setPermissionMode(String mode) async {
    permissionMode = mode;
    try {
      await storage.write(key: _permissionModeKey, value: mode);
    } catch (_) {
      // The in-memory selection remains usable when persistence is unavailable.
    }
  }

  Future<void> _saveConnections() async {
    try {
      await storage.write(
        key: _connectionsKey,
        value: jsonEncode(_connections),
      );
    } catch (_) {
      // The active connection remains usable when persistence is unavailable.
    }
  }
}
