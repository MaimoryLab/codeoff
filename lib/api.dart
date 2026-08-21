import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
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

  Future<dynamic> threads() => _request('GET', '/api/v1/threads');

  Future<dynamic> startThread() =>
      _request('POST', '/api/v1/threads', body: {});

  Future<dynamic> startTurn(String threadId, String input) => _request(
    'POST',
    '/api/v1/threads/$threadId/turns',
    body: {'input': input},
  );

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

  Uri _uri(String path) =>
      base.resolve(path.startsWith('/') ? path.substring(1) : path);

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, _uri(path));
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
