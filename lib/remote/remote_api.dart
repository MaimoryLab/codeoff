import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const minServerVersion = '1.0.0';
const _serverVersionHeader = 'X-Codeoff-Server-Version';
const _minClientVersionHeader = 'X-Codeoff-Min-Client-Version';
const _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

int compareRemoteVersions(String left, String right) {
  List<int> parse(String value) {
    final core = value.trim().split(RegExp(r'[+-]')).first;
    final parts = core.split('.');
    if (parts.length != 3) throw const FormatException('Invalid version');
    return parts.map((part) {
      final number = int.tryParse(part);
      if (number == null || number < 0) {
        throw const FormatException('Invalid version');
      }
      return number;
    }).toList();
  }

  final a = parse(left);
  final b = parse(right);
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return a[index].compareTo(b[index]);
  }
  return 0;
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.upgradeRequired = false});
  ApiException.upgradeRequired(this.message)
    : statusCode = null,
      upgradeRequired = true;

  final String message;
  final int? statusCode;
  final bool upgradeRequired;

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

class RemoteFile {
  const RemoteFile({
    required this.name,
    required this.contentType,
    required this.bytes,
  });

  final String name;
  final String contentType;
  final Uint8List bytes;
}

typedef DownloadProgress = void Function(int received, int? total);

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
    required this.clientVersion,
    this.token,
    this.heartbeatInterval = const Duration(seconds: 10),
  }) : base = Uri.parse(endpoint.trim().replaceFirst(RegExp(r'/+$'), ''));

  final Uri base;
  final String clientVersion;
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

  Future<dynamic> createDirectory({
    required String path,
    required String name,
  }) => _request(
    'directory/create',
    params: {'path': path.trim(), 'name': name.trim()},
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
    final value = await _httpRequest(
      'POST',
      '/api/v1/upload',
      query: {'name': name},
      stream: bytes,
      onProgress: onProgress,
    ) as Map<String, dynamic>;
    return RemoteAttachment(name: name, path: '${value['path'] ?? ''}');
  }

  Future<RemoteFile> downloadFile(
    String path, {
    DownloadProgress? onProgress,
  }) async {
    final result = await _httpBytesRequest(
      'GET',
      '/api/v1/file',
      query: {'path': path.trim()},
      onProgress: onProgress,
    );
    return RemoteFile(
      name: result.name,
      contentType: result.contentType,
      bytes: result.bytes,
    );
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
    Stream<List<int>>? stream,
    void Function(int bytesRead)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, _uri(path, query));
      if (token?.isNotEmpty == true) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.headers.contentType = stream == null
          ? ContentType.json
          : ContentType.binary;
      if (stream != null) {
        var sent = 0;
        await request.addStream(
          stream.map((chunk) {
            sent += chunk.length;
            onProgress?.call(sent);
            return chunk;
          }),
        );
      } else if (body != null) {
        request.write(jsonEncode(body));
      }
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

  Future<RemoteFile> _httpBytesRequest(
    String method,
    String path, {
    Map<String, String>? query,
    DownloadProgress? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, _uri(path, query));
      if (token?.isNotEmpty == true) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();
      final total = response.contentLength > 0 ? response.contentLength : null;
      var received = 0;
      final bytes = await response.fold<List<int>>([], (all, chunk) {
        all.addAll(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
        return all;
      });
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = utf8.decode(bytes, allowMalformed: true).trim();
        throw ApiException(
          message.isEmpty ? 'Request failed (${response.statusCode})' : message,
          statusCode: response.statusCode,
        );
      }
      return RemoteFile(
        name: _filename(response.headers.value('content-disposition')),
        contentType:
            response.headers.contentType?.mimeType ??
            'application/octet-stream',
        bytes: Uint8List.fromList(bytes),
      );
    } on SocketException catch (error) {
      throw ApiException(error.message);
    } finally {
      client.close(force: true);
    }
  }

  String _filename(String? disposition) {
    final match = RegExp(r'filename="?([^";]+)').firstMatch(disposition ?? '');
    return match?.group(1) ?? 'download';
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
        final socket = await _connectWebSocket(headers)
            .timeout(const Duration(seconds: 10));
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

  Future<WebSocket> _connectWebSocket(Map<String, String> headers) async {
    final client = HttpClient();
    try {
      final uri = _webSocketUri.replace(
        scheme: _webSocketUri.scheme == 'wss' ? 'https' : 'http',
      );
      final request = await client.openUrl('GET', uri);
      final key = base64Encode(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
      request.headers
        ..add(HttpHeaders.connectionHeader, 'Upgrade')
        ..add(HttpHeaders.upgradeHeader, 'websocket')
        ..add('Sec-WebSocket-Version', '13')
        ..add('Sec-WebSocket-Key', key);
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode != HttpStatus.switchingProtocols) {
        throw ApiException(
          'WebSocket handshake failed (${response.statusCode})',
          statusCode: response.statusCode,
        );
      }
      final expectedAccept = base64Encode(
        sha1.convert(utf8.encode('$key$_webSocketGuid')).bytes,
      );
      if (response.headers.value('Sec-WebSocket-Accept') != expectedAccept) {
        final socket = await response.detachSocket();
        socket.destroy();
        throw ApiException('Invalid WebSocket handshake');
      }
      final serverVersion = response.headers.value(_serverVersionHeader);
      final requiredClient = response.headers.value(_minClientVersionHeader);
      try {
        if (serverVersion == null ||
            requiredClient == null ||
            (serverVersion != 'dev' &&
                compareRemoteVersions(serverVersion, minServerVersion) < 0) ||
            compareRemoteVersions(clientVersion, requiredClient) < 0) {
          throw const FormatException('Incompatible versions');
        }
      } on FormatException {
        final socket = await response.detachSocket();
        socket.destroy();
        throw ApiException.upgradeRequired(
          'Unable to connect: app upgrade required',
        );
      }
      return WebSocket.fromUpgradedSocket(
        await response.detachSocket(),
        serverSide: false,
      );
    } finally {
      client.close(force: true);
    }
  }

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
