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
  RemoteApi(String endpoint, {this.token})
    : base = Uri.parse(endpoint.trim().replaceFirst(RegExp(r'/+$'), ''));

  final Uri base;
  String? token;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<dynamic>>{};
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Future<void>? _connecting;
  int _nextRequestId = 0;

  Future<dynamic> pair(String pairingToken, String name) => _httpRequest(
    'POST',
    '/api/v1/pair/exchange',
    body: {'token': pairingToken, 'name': name},
  );

  Future<dynamic> status() => _request('GET', '/api/v1/status');

  Future<dynamic> threads({String? cursor, int? limit}) => _request(
    'GET',
    '/api/v1/threads',
    query: {
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (limit != null) 'limit': '$limit',
    },
  );

  Future<dynamic> thread(String threadId) =>
      _request('GET', '/api/v1/threads/$threadId');

  Future<dynamic> directories({String? path}) => _request(
    'GET',
    '/api/v1/directories',
    query: {if (path != null && path.trim().isNotEmpty) 'path': path.trim()},
  );

  Future<dynamic> startThread({String? cwd}) => _request(
    'POST',
    '/api/v1/threads',
    body: {if (cwd != null && cwd.trim().isNotEmpty) 'cwd': cwd.trim()},
  );

  Future<dynamic> resumeThread(String threadId) =>
      _request('POST', '/api/v1/threads/$threadId/resume', body: {});

  Future<dynamic> releaseThread(String threadId) =>
      _request('POST', '/api/v1/threads/$threadId/release', body: {});

  Future<dynamic> takeOverThread(String threadId) =>
      _request('POST', '/api/v1/threads/$threadId/takeover', body: {});

  Future<dynamic> renameThread(String threadId, String name) =>
      _request('POST', '/api/v1/threads/$threadId/name', body: {'name': name});

  Future<dynamic> archiveThread(String threadId) =>
      _request('POST', '/api/v1/threads/$threadId/archive', body: {});

  Future<dynamic> startTurn(
    String threadId,
    String input, {
    List<RemoteAttachment> attachments = const [],
    RemotePermissionMode permissions = RemotePermissionMode.requestApproval,
  }) => _request(
    'POST',
    '/api/v1/threads/$threadId/turns',
    body: {
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
    'POST',
    '/api/v1/turns/$turnId/steer',
    query: {'threadId': threadId},
    body: _turnBody(input, attachments),
  );

  Future<RemoteAttachment> upload(String name, Stream<List<int>> bytes) async {
    final chunks = await bytes.toList();
    final data = <int>[];
    for (final chunk in chunks) {
      data.addAll(chunk);
    }
    final value = await _request(
      'POST',
      '/api/v1/files',
      query: {'name': name},
      binary: base64Encode(data),
      contentType: ContentType('application', 'octet-stream').mimeType,
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
      'POST',
      '/api/v1/approvals/$requestId',
      body: {'decision': decision},
    );
  }

  Stream<Map<String, dynamic>> events() async* {
    await _ensureConnected();
    yield* _events.stream;
  }

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    if (socket != null) await socket.close(WebSocketStatus.normalClosure);
    _failPending(ApiException('Connection closed'));
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = base.resolve(path.startsWith('/') ? path.substring(1) : path);
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    String? binary,
    String? contentType,
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
    socket.add(
      jsonEncode({
        'id': id,
        'method': method,
        'path': path,
        if (query != null && query.isNotEmpty) 'query': query,
        'body': ?body,
        'binary': ?binary,
        'contentType': ?contentType,
      }),
    );
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
    final existing = _connecting;
    if (existing != null) return existing;
    final future = () async {
      final headers = <String, String>{
        if (token != null && token!.isNotEmpty)
          HttpHeaders.authorizationHeader: 'Bearer $token',
      };
      final socket = await WebSocket.connect(
        _webSocketUri.toString(),
        headers: headers,
      );
      socket.pingInterval = const Duration(seconds: 20);
      _socket = socket;
      _socketSubscription = socket.listen(
        (data) => _receive(socket, data),
        onError: (Object error) => _failConnection(socket, error),
        onDone: () => _failConnection(socket, ApiException('WebSocket closed')),
        cancelOnError: false,
      );
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
      final id = value['id'];
      if (id is int) {
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
      if (value['method'] is String && value['params'] is Map) {
        _events.add(Map<String, dynamic>.from(value));
      }
    } catch (error) {
      _failConnection(socket, error);
    }
  }

  void _failConnection(WebSocket socket, Object error) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    final failure = error is ApiException
        ? error
        : ApiException(error.toString());
    _failPending(failure);
    _events.addError(failure);
  }

  void _failPending(ApiException error) {
    final pending = List<Completer<dynamic>>.from(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}
