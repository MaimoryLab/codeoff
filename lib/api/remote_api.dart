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
  requestApproval('Request approval', 'on-request', 'workspaceWrite'),
  autoApprove('Auto approve', 'never', 'workspaceWrite'),
  fullAccess('Full access', 'never', 'dangerFullAccess');

  const RemotePermissionMode(
    this.label,
    this.approvalPolicy,
    this.sandboxPolicy,
  );

  final String label;
  final String approvalPolicy;
  final String sandboxPolicy;
}

class RemoteApi {
  RemoteApi(String endpoint, {this.token})
    : base = Uri.parse(endpoint.trim().replaceFirst(RegExp(r'/+$'), ''));

  final Uri base;
  String? token;

  Future<dynamic> pair(String pairingToken, String name) => _request(
    'POST',
    '/api/v1/pair/exchange',
    auth: false,
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

  Future<RemoteAttachment> upload(
    String name,
    Stream<List<int>> bytes,
    int length,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        _uri('/api/v1/files', {'name': name}),
      );
      _authorize(request);
      request.contentLength = length;
      request.headers.contentType = ContentType('application', 'octet-stream');
      await request.addStream(bytes);
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          text.isEmpty ? 'Upload failed (${response.statusCode})' : text.trim(),
          statusCode: response.statusCode,
        );
      }
      final value = jsonDecode(text) as Map<String, dynamic>;
      return RemoteAttachment(name: name, path: '${value['path'] ?? ''}');
    } on SocketException catch (error) {
      throw ApiException(error.message);
    } finally {
      client.close(force: true);
    }
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
    final client = HttpClient();
    try {
      final request = await client.getUrl(_uri('/api/v1/events'));
      _authorize(request);
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException('Events failed (${response.statusCode})');
      }
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data: ')) continue;
        final value = jsonDecode(line.substring(6));
        if (value is Map<String, dynamic>) yield value;
      }
    } finally {
      client.close(force: true);
    }
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
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, _uri(path, query));
      if (auth) _authorize(request);
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

  void _authorize(HttpClientRequest request) {
    final value = token;
    if (value != null && value.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $value');
    }
  }
}
