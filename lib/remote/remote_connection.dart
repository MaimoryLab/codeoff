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
  List<String> _endpoints = const [];
  String _token = '';

  RemoteApi? get client => _client;
  RemoteConnectionStatus status = RemoteConnectionStatus.offline;
  RemoteConnectionStatus previousStatus = RemoteConnectionStatus.offline;
  Object? lastError;
  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<RemoteConnectionStatus> get statuses => _statuses.stream;

  Future<dynamic> connect(
    String endpoint,
    String token, {
    List<String>? endpoints,
  }) async {
    await disconnect();
    _endpoint = endpoint;
    _endpoints = endpoints ?? [endpoint];
    _token = token;
    _setStatus(RemoteConnectionStatus.connecting);
    return _open(endpoint);
  }

  Future<dynamic> _open(String endpoint) async {
    final client = _createClient(endpoint, _token);
    _client = client;
    try {
      final result = await client.status();
      if (!identical(_client, client)) return result;
      _listen(client);
      lastError = null;
      _endpoint = endpoint;
      _setStatus(RemoteConnectionStatus.online);
      return result;
    } catch (_) {
      if (identical(_client, client)) await _closeCurrent();
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
    if (_endpoint.isEmpty || _token.isEmpty) return;
    final candidates = _endpoints.isEmpty ? [_endpoint] : _endpoints;
    final current = _client;
    final currentEndpoint = _endpoint;
    _setStatus(RemoteConnectionStatus.reconnecting);
    for (final candidate in candidates) {
      try {
        if (current != null &&
            candidate == currentEndpoint &&
            identical(_client, current)) {
          await current.reconnect();
          await current.status();
          if (!identical(_client, current)) return;
          _listen(current);
          lastError = null;
          _setStatus(RemoteConnectionStatus.online);
          return;
        }
        await _closeCurrent();
        await _open(candidate);
        return;
      } catch (error) {
        lastError = error;
      }
    }
    _setStatus(RemoteConnectionStatus.offline);
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
    await _closeCurrent();
    lastError = null;
    _setStatus(RemoteConnectionStatus.offline);
  }

  Future<void> _closeCurrent() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    final client = _client;
    _client = null;
    await client?.close();
  }

  Future<void> close() async {
    await disconnect();
    await _events.close();
    await _statuses.close();
  }
}
