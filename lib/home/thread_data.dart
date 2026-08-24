part of 'remote_home_page.dart';

DateTime? parseRemoteTimestamp(dynamic value) {
  if (value is num) return _unixTimestamp(value);
  final text = '${value ?? ''}'.trim();
  if (text.isEmpty) return null;
  final numeric = num.tryParse(text);
  if (numeric != null) return _unixTimestamp(numeric);
  return DateTime.tryParse(text)?.toLocal();
}

DateTime _unixTimestamp(num value) {
  final milliseconds = value.abs() < 100000000000 ? value * 1000 : value;
  return DateTime.fromMillisecondsSinceEpoch(
    milliseconds.round(),
    isUtc: true,
  ).toLocal();
}

bool remoteThreadIsActive(Map<String, dynamic> thread) {
  final status = thread['status'];
  return status is Map && status['type'] == 'active';
}

DateTime remoteThreadDate(Map<String, dynamic> thread) {
  for (final key in ['updatedAt', 'lastUpdatedAt', 'createdAt', 'timestamp']) {
    final parsed = parseRemoteTimestamp(thread[key]);
    if (parsed != null) return parsed;
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

int compareRemoteThreads(Map<String, dynamic> a, Map<String, dynamic> b) {
  final activeA = remoteThreadIsActive(a);
  final activeB = remoteThreadIsActive(b);
  if (activeA != activeB) return activeA ? -1 : 1;
  return remoteThreadDate(b).compareTo(remoteThreadDate(a));
}

extension _ThreadData on _RemoteHomePageState {
  List<Map<String, dynamic>> _visibleThreads() {
    final query = search.text.trim().toLowerCase();
    return threads.where((thread) {
      if (selectedProject != null &&
          _threadProject(thread) != selectedProject) {
        return false;
      }
      if (query.isNotEmpty &&
          !_threadTitle(thread).toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();
  }

  String _threadId(Map<String, dynamic> thread) =>
      '${thread['id'] ?? thread['threadId'] ?? ''}';

  String _threadCwd(String id) {
    for (final thread in threads) {
      if (_threadId(thread) != id) continue;
      final cwd = '${thread['cwd'] ?? ''}'.trim();
      if (cwd.isNotEmpty && cwd != 'null') return cwd;
    }
    return '';
  }

  String _threadTitle(dynamic thread) {
    if (thread is String) {
      final found = threads.where((item) => _threadId(item) == thread);
      return found.isEmpty ? thread : _threadTitle(found.first);
    }
    if (thread is! Map) return 'Thread';
    for (final key in ['name', 'sessionName', 'title', 'preview']) {
      final value = thread[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return _threadId(Map<String, dynamic>.from(thread));
  }

  List<String> _projects() {
    final latest = <String, DateTime>{};
    final active = <String>{};
    for (final thread in threads) {
      final project = _threadProject(thread);
      if (project.isEmpty) continue;
      final date = remoteThreadDate(thread);
      final previous = latest[project];
      if (previous == null || date.isAfter(previous)) latest[project] = date;
      if (remoteThreadIsActive(thread)) active.add(project);
    }
    final projects = latest.keys.toList()
      ..sort((a, b) {
        if (active.contains(a) != active.contains(b)) {
          return active.contains(a) ? -1 : 1;
        }
        final result = latest[b]!.compareTo(latest[a]!);
        return result != 0 ? result : a.compareTo(b);
      });
    return projects;
  }

  String _threadProject(Map<String, dynamic> thread) {
    for (final key in ['projectName', 'project']) {
      final value = thread[key];
      if (value is Map) {
        final name = '${value['name'] ?? value['title'] ?? ''}'.trim();
        if (name.isNotEmpty) return name;
      }
      final name = '$value'.trim();
      if (name.isNotEmpty && name != 'null') return name;
    }
    final cwd = '${thread['cwd'] ?? ''}'.trim();
    return cwd.isEmpty || cwd == 'null' ? '' : cwd;
  }

  String _projectLabel(String project) {
    if (!project.contains('/') && !project.contains('\\')) return project;
    return project.split(RegExp(r'[/\\]')).last;
  }

  String _timeLabel(DateTime date) {
    if (date.year == DateTime.now().year &&
        date.month == DateTime.now().month) {
      return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.year}/${date.month}/${date.day}';
  }

  bool _threadNeedsResume(Map<String, dynamic> thread) {
    final status = thread['status'];
    return status is Map && status['type'] == 'notLoaded';
  }

  List<Map<String, dynamic>> _historyItems(dynamic value) {
    if (value is Map) {
      if (value['thread'] != null) return _historyItems(value['thread']);
      if (value['turns'] is List) return _historyItems(value['turns']);
      for (final key in ['items', 'messages']) {
        if (value[key] is List) return _historyItems(value[key]);
      }
      final item = Map<String, dynamic>.from(value);
      return _messageText(item).isEmpty ? [] : [item];
    }
    if (value is List) {
      final items = <Map<String, dynamic>>[];
      for (final raw in value.whereType<Map>()) {
        final item = Map<String, dynamic>.from(raw);
        if (item['items'] is List) {
          items.addAll(_historyItems(item['items']));
        } else if (_messageText(item).isNotEmpty) {
          items.add(item);
        }
      }
      return items;
    }
    return [];
  }

  String _messageRole(Map<String, dynamic> item) {
    final value = '${item['role'] ?? item['type'] ?? ''}'.toLowerCase();
    return value.contains('user') || value.contains('input')
        ? 'user'
        : 'assistant';
  }

  String _messageText(Map<String, dynamic> item) {
    for (final key in [
      'text',
      'content',
      'message',
      'input',
      'output',
      'preview',
    ]) {
      final text = _contentText(item[key]);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _contentText(dynamic value) {
    if (value is String) return value.trim();
    if (value is Map) {
      for (final key in ['text', 'value', 'content']) {
        final text = _contentText(value[key]);
        if (text.isNotEmpty) return text;
      }
    }
    if (value is List) {
      return value
          .map(_contentText)
          .where((text) => text.isNotEmpty)
          .join('\n');
    }
    return '';
  }

  String _idFromValue(dynamic value) {
    if (value is! Map) return '';
    for (final key in ['id', 'threadId']) {
      if (value[key] != null) return '${value[key]}';
    }
    return _idFromValue(value['thread']);
  }

  String _stringValue(dynamic value, String key) {
    if (value is Map && value[key] != null) return '${value[key]}';
    return '';
  }
}
