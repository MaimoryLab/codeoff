import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class ThreadCacheSnapshot {
  const ThreadCacheSnapshot({required this.threads, required this.history});

  final List<Map<String, dynamic>> threads;
  final Map<String, List<Map<String, dynamic>>> history;
}

class ThreadCache {
  static const _directoryName = 'codeoff_threads';
  Future<void> _writes = Future.value();

  void write(
    String serverId,
    List<Map<String, dynamic>> threads,
    Map<String, List<Map<String, dynamic>>> history,
  ) {
    late final String payload;
    try {
      payload = jsonEncode({'threads': threads, 'history': history});
    } catch (_) {
      return;
    }
    _writes = _writes.then((_) async {
      try {
        final file = await _file(serverId);
        await file.writeAsString(payload, flush: true);
      } catch (_) {
        // Cache storage is optional; callers use the live connection instead.
      }
    });
  }

  Future<ThreadCacheSnapshot> read(String serverId) async {
    try {
      final file = await _file(serverId);
      if (!await file.exists()) return _emptySnapshot;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return _emptySnapshot;
      final histories = <String, List<Map<String, dynamic>>>{};
      final rawHistory = value['history'];
      if (rawHistory is Map) {
        for (final entry in rawHistory.entries) {
          final items = _maps(entry.value);
          if (items.isNotEmpty) histories['${entry.key}'] = items;
        }
      }
      return ThreadCacheSnapshot(
        threads: _maps(value['threads']),
        history: histories,
      );
    } catch (_) {
      return const ThreadCacheSnapshot(threads: [], history: {});
    }
  }

  static const _emptySnapshot = ThreadCacheSnapshot(threads: [], history: {});

  Future<File> _file(String serverId) async {
    final root = await getApplicationCacheDirectory();
    final directory = Directory('${root.path}/$_directoryName');
    await directory.create(recursive: true);
    final name = base64Url.encode(utf8.encode(serverId)).replaceAll('=', '');
    return File('${directory.path}/$name.json');
  }

  List<Map<String, dynamic>> _maps(dynamic value) => value is List
      ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
      : [];
}
