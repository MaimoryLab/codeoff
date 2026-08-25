import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  bool get isConnectionFailure =>
      statusCode == null ||
      statusCode == HttpStatus.unauthorized ||
      statusCode! >= HttpStatus.internalServerError;

  bool get isConflict => statusCode == HttpStatus.conflict;

  @override
  String toString() => message;
}

class RemoteAttachment {
  const RemoteAttachment({required this.name, required this.path});
  final String name;
  final String path;
}

enum RemotePermissionMode {
  requestApproval('Ask for approval', 'on-request', 'user', 'workspaceWrite'),
  autoApprove('Approve for me', 'on-request', 'auto_review', 'workspaceWrite'),
  fullAccess('Full access', 'never', 'user', 'dangerFullAccess');

  const RemotePermissionMode(
    this.label,
    this.approvalPolicy,
    this.approvalsReviewer,
    this.sandboxPolicy,
  );

  final String label;
  final String approvalPolicy;
  final String approvalsReviewer;
  final String sandboxPolicy;
}

class RemoteApi {
  RemoteApi(
    String endpoint, {
    this.token,
    this.heartbeatInterval = const Duration(seconds: 10),
  }) : base = Uri.parse(endpoint.trim().replaceFirst(RegExp(r'/+$'), ''));

  final Uri base;
  String? token;
  final Duration heartbeatInterval;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<dynamic>>{};
  final _heartbeatRequests = <int>{};
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _heartbeatTimer;
  Future<void>? _connecting;
  int _nextRequestId = 0;
  int _missedHeartbeatAcks = 0;
  bool _closed = false;

  Future<dynamic> pair(String pairingToken, String name) => _httpRequest(
    'POST',
    '/api/v1/pair/exchange',
    body: {'token': pairingToken, 'name': name},
  );

  Future<dynamic> status() => _request('status');

  Future<dynamic> threads({String? cursor, int? limit}) => _request(
    'thread/list',
    params: {
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      'limit': ?limit,
    },
  );

  Future<dynamic> thread(String threadId) =>
      _request('thread/read', params: {'threadId': threadId});

  Future<dynamic> directories({String? path}) => _request(
    'directories',
    params: {if (path != null && path.trim().isNotEmpty) 'path': path.trim()},
  );

  Future<dynamic> startThread({String? cwd}) => _request(
    'thread/start',
    params: {if (cwd != null && cwd.trim().isNotEmpty) 'cwd': cwd.trim()},
  );

  Future<dynamic> resumeThread(String threadId) =>
      _request('thread/resume', params: {'threadId': threadId});

  Future<dynamic> releaseThread(String threadId) =>
      _request('thread/release', params: {'threadId': threadId});

  Future<dynamic> takeOverThread(String threadId) =>
      _request('thread/takeover', params: {'threadId': threadId});

  Future<dynamic> renameThread(String threadId, String name) =>
      _request('thread/name/set', params: {'threadId': threadId, 'name': name});

  Future<dynamic> archiveThread(String threadId) =>
      _request('thread/archive', params: {'threadId': threadId});

  Future<dynamic> startTurn(
    String threadId,
    String input, {
    List<RemoteAttachment> attachments = const [],
    RemotePermissionMode permissions = RemotePermissionMode.requestApproval,
  }) => _request(
    'turn/start',
    params: {
      'threadId': threadId,
      ..._turnBody(input, attachments),
      'approvalPolicy': permissions.approvalPolicy,
      'approvalsReviewer': permissions.approvalsReviewer,
      'sandboxPolicy': {'type': permissions.sandboxPolicy},
    },
  );

  Future<dynamic> steerTurn(
    String threadId,
    String turnId,
    String input, {
    List<RemoteAttachment> attachments = const [],
  }) => _request(
    'turn/steer',
    params: {
      'threadId': threadId,
      'turnId': turnId,
      ..._turnBody(input, attachments),
    },
  );

  Future<RemoteAttachment> upload(
    String name,
    Stream<List<int>> bytes, {
    void Function(int bytesRead)? onProgress,
  }) async {
    final data = <int>[];
    await for (final chunk in bytes) {
      data.addAll(chunk);
      onProgress?.call(data.length);
    }
    final value = await _request(
      'upload',
      params: {'name': name, 'data': base64Encode(data)},
    ) as Map<String, dynamic>;
    return RemoteAttachment(name: name, path: '${value['path'] ?? ''}');
  }

  Map<String, dynamic> _turnBody(
    String input,
    List<RemoteAttachment> attachments,
  ) => {
    'input': input,
    if (attachments.isNotEmpty)
      'attachments': attachments
          .map(
            (attachment) => {'name': attachment.name, 'path': attachment.path},
          )
          .toList(),
  };

  Future<void> approve(int requestId, String decision) async {
    await _request(
      'approval/respond',
      params: {'requestId': requestId, 'decision': decision},
    );
  }

  Stream<Map<String, dynamic>> events() async* {
    await _ensureConnected();
    yield* _events.stream;
  }

  Future<void> close() async {
    _closed = true;
    final socket = _socket;
    _socket = null;
    _stopHeartbeat();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    if (socket != null) await socket.close(WebSocketStatus.normalClosure);
    _failPending(ApiException('Connection closed'));
  }

  Future<void> reconnect({
    int attempts = 3,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    ApiException? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay * attempt);
      try {
        await _ensureConnected();
        return;
      } catch (error) {
        lastError = error is ApiException
            ? error
            : ApiException(error.toString());
      }
    }
    throw lastError ?? ApiException('Unable to reconnect');
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = base.resolve(path.startsWith('/') ? path.substring(1) : path);
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Future<dynamic> _request(
    String method, {
    Map<String, dynamic> params = const {},
  }) async {
    await _ensureConnected();
    final id = ++_nextRequestId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final socket = _socket;
    if (socket == null) {
      _pending.remove(id);
      throw ApiException('WebSocket is not connected');
    }
    try {
      socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    } catch (error) {
      _pending.remove(id);
      _failConnection(socket, error);
      throw ApiException(error.toString());
    }
    return completer.future;
  }

  Future<dynamic> _httpRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, _uri(path, query));
      request.headers.contentType = ContentType.json;
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          text.isEmpty
              ? 'Request failed (${response.statusCode})'
              : text.trim(),
          statusCode: response.statusCode,
        );
      }
      return text.isEmpty ? null : jsonDecode(text);
    } on SocketException catch (error) {
      throw ApiException(error.message);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _ensureConnected() {
    if (_closed) return Future.error(ApiException('Connection closed'));
    if (_socket != null) return Future.value();
    final existing = _connecting;
    if (existing != null) return existing;
    final future = () async {
      try {
        final headers = <String, String>{
          if (token != null && token!.isNotEmpty)
            HttpHeaders.authorizationHeader: 'Bearer $token',
        };
        final socket = await WebSocket.connect(
          _webSocketUri.toString(),
          headers: headers,
        ).timeout(const Duration(seconds: 10));
        if (_closed) {
          await socket.close(WebSocketStatus.normalClosure);
          throw ApiException('Connection closed');
        }
        _socket = socket;
        _socketSubscription = socket.listen(
          (data) => _receive(socket, data),
          onError: (Object error) => _failConnection(socket, error),
          onDone: () =>
              _failConnection(socket, ApiException('WebSocket closed')),
          cancelOnError: false,
        );
        _heartbeatTimer = Timer.periodic(
          heartbeatInterval,
          (_) => _sendHeartbeat(socket),
        );
      } on ApiException {
        rethrow;
      } catch (error) {
        throw ApiException(error.toString());
      }
    }();
    _connecting = future;
    return future.whenComplete(() {
      if (identical(_connecting, future)) _connecting = null;
    });
  }

  Uri get _webSocketUri => base.replace(
    scheme: base.scheme == 'https' ? 'wss' : 'ws',
    path: '/api/v1/ws',
    query: '',
    fragment: '',
  );

  void _receive(WebSocket socket, dynamic data) {
    try {
      final value = jsonDecode('$data');
      if (value is! Map) return;
      if (value['method'] is String) {
        _resetHeartbeatTimeout();
        final event = Map<String, dynamic>.from(value);
        if (event['params'] is! Map) event['params'] = <String, dynamic>{};
        _events.add(event);
        return;
      }
      final id = value['id'];
      if (id is int) {
        if (_heartbeatRequests.remove(id)) {
          final result = value['result'];
          if (result is Map && result['ack'] == true) {
            _missedHeartbeatAcks = 0;
            _heartbeatRequests.clear();
          }
          return;
        }
        _resetHeartbeatTimeout();
        final completer = _pending.remove(id);
        if (completer == null) return;
        final error = value['error'];
        if (error is Map) {
          completer.completeError(
            ApiException(
              '${error['message'] ?? 'Request failed'}',
              statusCode: error['statusCode'] is int
                  ? error['statusCode'] as int
                  : null,
            ),
          );
        } else {
          completer.complete(value['result']);
        }
        return;
      }
    } catch (error) {
      _failConnection(socket, error);
    }
  }

  void _failConnection(WebSocket socket, Object error) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    _stopHeartbeat();
    final subscription = _socketSubscription;
    _socketSubscription = null;
    unawaited(subscription?.cancel());
    unawaited(socket.close(WebSocketStatus.goingAway));
    final failure = error is ApiException
        ? error
        : ApiException(error.toString());
    _failPending(failure);
    _events.addError(failure);
  }

  void _sendHeartbeat(WebSocket socket) {
    if (!identical(_socket, socket)) return;
    if (_pending.isNotEmpty) {
      _resetHeartbeatTimeout();
      return;
    }
    if (_missedHeartbeatAcks >= 3) {
      _failConnection(
        socket,
        ApiException('Heartbeat acknowledgement timed out'),
      );
      return;
    }
    final id = ++_nextRequestId;
    _heartbeatRequests.add(id);
    _missedHeartbeatAcks++;
    try {
      socket.add(jsonEncode({'id': id, 'method': 'heartbeat'}));
    } catch (error) {
      _failConnection(socket, error);
    }
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatRequests.clear();
    _missedHeartbeatAcks = 0;
  }

  void _resetHeartbeatTimeout() {
    _heartbeatRequests.clear();
    _missedHeartbeatAcks = 0;
  }

  void _failPending(ApiException error) {
    final pending = List<Completer<dynamic>>.from(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}
