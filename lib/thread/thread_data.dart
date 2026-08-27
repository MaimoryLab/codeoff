part of '../home/remote_home_page.dart';

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

bool shouldNotifyThreadMessage(String threadId, String? selectedThread) =>
    threadId.isNotEmpty && threadId != selectedThread;

bool remoteThreadIsActive(Map<String, dynamic> thread) {
  final status = thread['status'];
  return status is Map && status['type'] == 'active';
}

List<Map<String, dynamic>> updateRemoteThread(
  List<Map<String, dynamic>> threads,
  String id,
  Map<String, dynamic> changes,
) => [
  for (final thread in threads)
    if ('${thread['id'] ?? thread['threadId'] ?? ''}' == id)
      {...thread, ...changes}
    else
      thread,
];

dynamic mutableRemoteValue(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': mutableRemoteValue(entry.value),
    };
  }
  if (value is List) return value.map(mutableRemoteValue).toList();
  return value;
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

String activeTurnIdFrom(dynamic value) {
  if (value is! Map) return '';
  if (_isInProgress(value['status'])) return '${value['id'] ?? ''}';
  final turns = value['turns'];
  if (turns is List) {
    for (final turn in turns.reversed) {
      final id = activeTurnIdFrom(turn);
      if (id.isNotEmpty) return id;
    }
  }
  return activeTurnIdFrom(value['thread'] ?? value['turn']);
}

bool _isInProgress(dynamic status) =>
    status == 'inProgress' || status == 'in_progress';

String processingSummaryFromThread(dynamic value, [AppLocalizations? l10n]) {
  if (value is! Map) return '';
  if (value['thread'] != null) {
    return processingSummaryFromThread(value['thread'], l10n);
  }
  final turns = value['turns'];
  if (turns is List) {
    for (final turn in turns.reversed) {
      if (turn is Map) return processingSummaryFromThread(turn, l10n);
    }
    return '';
  }
  final items = value['items'];
  final active =
      _isInProgress(value['status']) ||
      items is List &&
          items.whereType<Map>().any((item) => _isInProgress(item['status']));
  if (!active || items is! List) {
    return active ? l10n?.t('working') ?? 'Working...' : '';
  }
  for (final raw in items.reversed) {
    if (raw is! Map) continue;
    final item = mutableRemoteValue(raw) as Map<String, dynamic>;
    if (item['type'] == 'reasoning' && item['summary'] is List) {
      final summary = (item['summary'] as List)
          .map((part) => '$part'.trim())
          .where((part) => part.isNotEmpty)
          .join(' ');
      if (summary.isNotEmpty) {
        return l10n?.t('thinking', {'text': summary}) ?? 'Thinking: $summary';
      }
    }
    final summary = processingSummaryFromItem(item, l10n);
    if (summary.isNotEmpty) {
      return item['status'] == null || _isInProgress(item['status'])
          ? summary
          : l10n?.t('working') ?? 'Working...';
    }
    if (item['type'] == 'agentMessage') {
      return l10n?.t('working') ?? 'Working...';
    }
  }
  return l10n?.t('working') ?? 'Working...';
}

String processingSummaryFromItem(dynamic value, [AppLocalizations? l10n]) {
  if (value is! Map) return '';
  final type = '${value['type'] ?? ''}';
  switch (type) {
    case 'commandExecution':
      final command = '${value['command'] ?? ''}'.trim();
      return command.isEmpty
          ? l10n?.t('runningCommand') ?? 'Running a command'
          : l10n?.t('running', {'name': command}) ?? 'Running: $command';
    case 'mcpToolCall':
      final server = '${value['server'] ?? ''}'.trim();
      final tool = '${value['tool'] ?? ''}'.trim();
      final name = [server, tool].where((part) => part.isNotEmpty).join('/');
      return name.isEmpty
          ? l10n?.t('callingTool') ?? 'Calling a tool'
          : l10n?.t('calling', {'name': name}) ?? 'Calling: $name';
    case 'dynamicToolCall':
      final namespace = '${value['namespace'] ?? ''}'.trim();
      final tool = '${value['tool'] ?? ''}'.trim();
      final name = [namespace, tool].where((part) => part.isNotEmpty).join('/');
      return name.isEmpty
          ? l10n?.t('callingTool') ?? 'Calling a tool'
          : l10n?.t('calling', {'name': name}) ?? 'Calling: $name';
    case 'webSearch':
      return l10n?.t('searchingWeb') ?? 'Searching the web';
    case 'fileChange':
      final path = fileChangePath(Map<String, dynamic>.from(value));
      final name = path?.split(RegExp(r'[/\\]')).last.trim() ?? '';
      return name.isEmpty
          ? l10n?.t('applyingFileChanges') ?? 'Applying file changes'
          : l10n?.t('editedFile', {'name': name}) ?? 'Edited $name';
    case 'collabAgentToolCall':
      return l10n?.t('runningAgentTask') ?? 'Running an agent task';
    default:
      return '';
  }
}

bool isRemoteOperationItem(dynamic value) =>
    value is Map && processingSummaryFromItem(value).isNotEmpty;

String approvalThreadIdFrom(Map<String, dynamic> event) {
  final params = event['params'];
  if (params is! Map) return '';
  return '${params['threadId'] ?? params['conversationId'] ?? ''}';
}

({String kind, String reason, String target}) approvalDetailsFrom(
  Map<String, dynamic> event, [
  AppLocalizations? l10n,
]) {
  final method = '${event['method'] ?? ''}';
  final lowerMethod = method.toLowerCase();
  final params = event['params'] is Map
      ? Map<String, dynamic>.from(event['params'] as Map)
      : <String, dynamic>{};
  final kind = lowerMethod.contains('command')
      ? l10n?.t('command') ?? 'Command'
      : lowerMethod.contains('file') || lowerMethod.contains('patch')
      ? l10n?.t('fileChanges') ?? 'File changes'
      : lowerMethod.contains('permission')
      ? l10n?.t('permissions') ?? 'Permissions'
      : lowerMethod.contains('tool')
      ? l10n?.t('tool') ?? 'Tool'
      : l10n?.t('approval') ?? 'Approval';
  final tool = [
    params['server'] ?? params['namespace'],
    params['tool'] ?? params['name'],
  ].map(_approvalValue).where((part) => part.isNotEmpty).join('/');
  final target = [
    _approvalValue(params['command']),
    tool,
    _approvalValue(params['grantRoot']),
    _approvalValue(params['permissions']),
  ].firstWhere((value) => value.isNotEmpty, orElse: () => kind);
  final reason = _approvalValue(params['reason']);
  return (
    kind: kind,
    reason: reason.isEmpty
        ? l10n?.t('approvalReason') ?? 'Codex needs your approval to continue.'
        : reason,
    target: target,
  );
}

String _approvalValue(dynamic value) {
  if (value == null) return '';
  if (value is List) return value.map(_approvalValue).join(' ').trim();
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${_approvalValue(entry.value)}')
        .join(', ');
  }
  return '$value'.trim();
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
    if (thread is! Map) return context.t('thread');
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
      final item = mutableRemoteValue(value) as Map<String, dynamic>;
      return _messageText(item).isEmpty && !isRemoteOperationItem(item)
          ? []
          : [item];
    }
    if (value is List) {
      final items = <Map<String, dynamic>>[];
      for (final raw in value.whereType<Map>()) {
        final item = mutableRemoteValue(raw) as Map<String, dynamic>;
        if (item['items'] is List) {
          items.addAll(_historyItems(item['items']));
        } else if (_messageText(item).isNotEmpty ||
            isRemoteOperationItem(item)) {
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
