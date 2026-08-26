import 'dart:async';

import '../api.dart';

enum RemoteConnectionStatus { offline, connecting, reconnecting, online }

typedef RemoteApiFactory = RemoteApi Function(String endpoint, String token);

class RemoteConnection {
  RemoteConnection(this.clientVersion, {RemoteApiFactory? createClient})
    : _createClient =
          createClient ??
          ((endpoint, token) =>
              RemoteApi(endpoint, clientVersion: clientVersion, token: token));

  final String clientVersion;
  final RemoteApiFactory _createClient;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _statuses = StreamController<RemoteConnectionStatus>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  Future<void>? _recovery;
  RemoteApi? _client;
  String _endpoint = '';
  String _token = '';

  RemoteApi? get client => _client;
  RemoteConnectionStatus status = RemoteConnectionStatus.offline;
  RemoteConnectionStatus previousStatus = RemoteConnectionStatus.offline;
  Object? lastError;
  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<RemoteConnectionStatus> get statuses => _statuses.stream;

  Future<dynamic> connect(String endpoint, String token) async {
    await disconnect();
    _endpoint = endpoint;
    _token = token;
    _setStatus(RemoteConnectionStatus.connecting);
    final client = _createClient(endpoint, token);
    _client = client;
    try {
      final result = await client.status();
      if (!identical(_client, client)) return result;
      _listen(client);
      lastError = null;
      _setStatus(RemoteConnectionStatus.online);
      return result;
    } catch (_) {
      if (identical(_client, client)) await disconnect();
      rethrow;
    }
  }

  Future<void> reconnect({String? endpoint, String? token}) {
    if (endpoint != null) _endpoint = endpoint;
    if (token != null) _token = token;
    final current = _recovery;
    if (current != null) return current;
    final future = _recover();
    _recovery = future;
    return future.whenComplete(() {
      if (identical(_recovery, future)) _recovery = null;
    });
  }

  Future<void> _recover() async {
    var client = _client;
    if (client == null) {
      if (_endpoint.isEmpty || _token.isEmpty) return;
      client = _createClient(_endpoint, _token);
      _client = client;
    }
    _setStatus(RemoteConnectionStatus.reconnecting);
    try {
      await client.reconnect();
      await client.status();
      if (!identical(_client, client)) return;
      _listen(client);
      lastError = null;
      _setStatus(RemoteConnectionStatus.online);
    } catch (error) {
      if (!identical(_client, client)) return;
      lastError = error;
      _setStatus(RemoteConnectionStatus.offline);
    }
  }

  void _listen(RemoteApi client) {
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = client.events().listen(
      _events.add,
      onError: (Object error) {
        if (!identical(_client, client)) return;
        lastError = error;
        unawaited(reconnect());
      },
    );
  }

  void _setStatus(RemoteConnectionStatus value) {
    if (status == value) return;
    previousStatus = status;
    status = value;
    _statuses.add(value);
  }

  Future<void> disconnect() async {
    _recovery = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    final client = _client;
    _client = null;
    await client?.close();
    lastError = null;
    _setStatus(RemoteConnectionStatus.offline);
  }

  Future<void> close() async {
    await disconnect();
    await _events.close();
    await _statuses.close();
  }
}
