import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'api.dart';

void main() => runApp(const CodexRemoteApp());

class CodexRemoteApp extends StatelessWidget {
  const CodexRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xff191a1c);
    return MaterialApp(
      title: 'Codex Remote',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffd78360),
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xff242528),
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff292a2e),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
        useMaterial3: true,
      ),
      home: const RemoteHomePage(),
    );
  }
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  final endpoint = TextEditingController();
  final pairingToken = TextEditingController();
  final deviceName = TextEditingController(text: 'Phone');
  final accessToken = TextEditingController();
  final input = TextEditingController();
  final search = TextEditingController();
  RemoteApi? api;
  StreamSubscription<Map<String, dynamic>>? eventSubscription;
  List<Map<String, dynamic>> threads = [];
  List<Map<String, dynamic>> approvals = [];
  List<Map<String, dynamic>> history = [];
  String? selectedThread;
  String message = 'Enter the desktop endpoint to begin.';
  bool busy = false;
  bool connected = false;
  bool settingsOpen = true;
  bool loadingHistory = false;
  String? loadedHistoryFor;

  @override
  void dispose() {
    eventSubscription?.cancel();
    for (final controller in [
      endpoint,
      pairingToken,
      deviceName,
      accessToken,
      input,
      search,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> pair() async {
    await _run('Pairing...', () async {
      final client = RemoteApi(endpoint.text);
      final value = await client.pair(pairingToken.text, deviceName.text);
      accessToken.text = _stringValue(value, 'token');
      await connect();
    });
  }

  Future<void> connect() async {
    await _run('Connecting...', () async {
      final client = RemoteApi(endpoint.text, token: accessToken.text);
      await client.status();
      api = client;
      connected = true;
      await _reloadThreads();
      _listenEvents(client);
      settingsOpen = false;
      message = 'Connected';
    });
  }

  void _listenEvents(RemoteApi client) {
    eventSubscription?.cancel();
    eventSubscription = client.events().listen(
      (event) {
        if (!mounted) return;
        final id = event['id'];
        final method = '${event['method'] ?? ''}';
        if (id is int && method.contains('Approval')) {
          setState(() {
            approvals = [...approvals.where((item) => item['id'] != id), event];
            message = 'Approval requested';
          });
        }
        final params = event['params'] is Map
            ? Map<String, dynamic>.from(event['params'] as Map)
            : <String, dynamic>{};
        final threadId = '${params['threadId'] ?? ''}';
        if (method == 'item/agentMessage/delta' && threadId == selectedThread) {
          _appendAssistantDelta(params);
        }
        if (method == 'turn/completed' && threadId == selectedThread) {
          _loadHistory(selectedThread, force: true);
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => message = error.toString());
      },
    );
  }

  Future<void> _reloadThreads() async {
    final value = await api!.threads();
    final list = value is Map ? value['data'] ?? value['threads'] : value;
    final seen = <String>{};
    final next = list is List
        ? list
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .where((thread) => seen.add(_threadId(thread)))
              .where((thread) => _threadId(thread).isNotEmpty)
              .toList()
        : <Map<String, dynamic>>[];
    next.sort((a, b) => _threadDate(b).compareTo(_threadDate(a)));
    if (!mounted) return;
    setState(() {
      threads = next;
      final ids = next.map(_threadId).toSet();
      selectedThread = ids.contains(selectedThread) ? selectedThread : null;
    });
  }

  Future<void> createThread() async {
    await _run('Starting thread...', () async {
      final value = await api!.startThread();
      final id = _idFromValue(value);
      await _reloadThreads();
      if (id.isNotEmpty) _openThread(id);
    });
  }

  Future<void> sendTurn() async {
    final id = selectedThread;
    final text = input.text.trim();
    if (id == null || text.isEmpty) return;
    await _run('Sending...', () async {
      if (!mounted || selectedThread != id) return;
      setState(() {
        input.clear();
        history = [
          ...history,
          {'role': 'user', 'content': text},
        ];
        message = 'Turn started';
      });
      final thread = threads.firstWhere(
        (item) => _threadId(item) == id,
        orElse: () => <String, dynamic>{},
      );
      if (_threadNeedsResume(thread)) await api!.resumeThread(id);
      await api!.startTurn(id, text);
    });
  }

  void _appendAssistantDelta(Map<String, dynamic> params) {
    final delta = '${params['delta'] ?? ''}';
    final itemId = '${params['itemId'] ?? ''}';
    if (delta.isEmpty || itemId.isEmpty || !mounted) return;
    setState(() {
      final index = history.indexWhere((item) => item['id'] == itemId);
      if (index == -1) {
        history = [
          ...history,
          {'id': itemId, 'type': 'agentMessage', 'text': delta},
        ];
        return;
      }
      final item = Map<String, dynamic>.from(history[index]);
      item['text'] = '${item['text'] ?? ''}$delta';
      history = [...history]..[index] = item;
    });
  }

  Future<void> answer(Map<String, dynamic> event, String decision) async {
    final id = event['id'];
    if (id is! int) return;
    await _run('Sending decision...', () async {
      await api!.approve(id, decision);
      setState(() => approvals.removeWhere((item) => item['id'] == id));
    });
  }

  Future<void> _loadHistory(String? id, {bool force = false}) async {
    if (id == null || api == null || (!force && loadedHistoryFor == id)) return;
    setState(() {
      loadingHistory = true;
      if (!force) history = [];
    });
    try {
      final value = await api!.thread(id);
      if (!mounted || selectedThread != id) return;
      setState(() {
        history = _historyItems(value);
        loadedHistoryFor = id;
      });
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => loadingHistory = false);
    }
  }

  void _openThread(String id) {
    setState(() {
      selectedThread = id;
      settingsOpen = false;
      loadedHistoryFor = null;
      history = [];
    });
    _loadHistory(id);
  }

  void _openSettings() {
    Navigator.of(context).maybePop();
    setState(() {
      settingsOpen = true;
      selectedThread = null;
    });
  }

  void _showThreads() {
    Navigator.of(context).maybePop();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
    });
  }

  Future<void> _run(String pending, Future<void> Function() operation) async {
    if (!mounted) return;
    setState(() {
      busy = true;
      message = pending;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(() {
          message = error.toString();
          connected = false;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = selectedThread != null;
    return Scaffold(
      drawer: _drawer(context),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: detail ? 'Back' : 'Menu',
            icon: Icon(detail ? Icons.arrow_back : Icons.menu),
            onPressed: detail
                ? _showThreads
                : () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text(
          settingsOpen
              ? 'Settings'
              : detail
              ? _threadTitle(selectedThread!)
              : 'Threads',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Icon(
            connected ? Icons.cloud_done : Icons.cloud_off,
            color: connected ? Colors.greenAccent : Colors.white38,
            size: 20,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: settingsOpen
          ? _settingsView()
          : detail
          ? _threadView()
          : _threadsView(),
      floatingActionButton: !settingsOpen && !detail && connected
          ? FloatingActionButton(
              onPressed: busy ? null : createThread,
              tooltip: 'New thread',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _drawer(BuildContext context) => Drawer(
    backgroundColor: const Color(0xff222326),
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 30),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Color(0xffd78360),
                  child: Icon(Icons.auto_awesome, color: Colors.white),
                ),
                SizedBox(width: 12),
                Text(
                  'Codex Remote',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          _drawerItem(
            Icons.forum_outlined,
            'Threads',
            !settingsOpen,
            _showThreads,
          ),
          if (approvals.isNotEmpty)
            _drawerItem(Icons.verified_outlined, 'Approvals', false, () {
              Navigator.pop(context);
              setState(() {
                settingsOpen = false;
                selectedThread = null;
              });
            }),
          const Spacer(),
          const Divider(height: 1),
          _drawerItem(
            Icons.settings_outlined,
            'Settings',
            settingsOpen,
            _openSettings,
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );

  Widget _drawerItem(
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    selected: selected,
    selectedTileColor: const Color(0xff34363a),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    onTap: onTap,
  );

  Widget _threadsView() {
    final groups = _groupedThreads();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search threads',
            ),
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? _emptyState(
                  connected
                      ? 'No threads yet'
                      : 'Connect from Settings to begin',
                  Icons.forum_outlined,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  children: [
                    for (final entry in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 18, bottom: 8),
                        child: Text(
                          entry.key,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      for (final thread in entry.value) _threadEntry(thread),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _threadEntry(Map<String, dynamic> thread) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 4),
    leading: CircleAvatar(
      radius: 20,
      backgroundColor: const Color(0xff303136),
      child: Text(
        _threadTitle(thread).characters.first.toUpperCase(),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    title: Text(
      _threadTitle(thread),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(_timeLabel(_threadDate(thread))),
    trailing: const Icon(Icons.chevron_right, color: Colors.white38),
    onTap: () => _openThread(_threadId(thread)),
  );

  Widget _threadView() => Column(
    children: [
      Expanded(
        child: loadingHistory
            ? const Center(child: CircularProgressIndicator())
            : history.isEmpty
            ? _emptyState(
                'No messages in this thread',
                Icons.chat_bubble_outline,
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                itemCount: history.length,
                itemBuilder: (context, index) => _messageBubble(history[index]),
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: busy ? null : sendTurn,
                tooltip: 'Send',
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _messageBubble(Map<String, dynamic> item) {
    final user = _messageRole(item) == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        decoration: BoxDecoration(
          color: user ? const Color(0xff9f6148) : const Color(0xff292a2e),
          borderRadius: BorderRadius.circular(18),
        ),
        child: MarkdownBody(
          data: _messageText(item),
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ),
      ),
    );
  }

  Widget _settingsView() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 22),
        child: Text(
          'Codex Remote',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
      ),
      _settingsSection('Connection', [
        TextField(
          controller: endpoint,
          decoration: const InputDecoration(
            labelText: 'Desktop endpoint',
            hintText: 'https://...trycloudflare.com',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: accessToken,
          decoration: const InputDecoration(labelText: 'Device token'),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : connect,
                icon: const Icon(Icons.login),
                label: const Text('Connect'),
              ),
            ),
            const SizedBox(width: 10),
            IconButton(
              onPressed: busy ? null : () => setState(accessToken.clear),
              tooltip: 'Clear token',
              icon: const Icon(Icons.link_off),
            ),
          ],
        ),
      ]),
      _settingsSection('Pair new device', [
        TextField(
          controller: pairingToken,
          decoration: const InputDecoration(labelText: 'One-time pairing code'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: deviceName,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: busy ? null : pair,
            icon: const Icon(Icons.add_link),
            label: const Text('Pair'),
          ),
        ),
      ]),
      if (approvals.isNotEmpty)
        _settingsSection(
          'Approvals',
          approvals.map((event) => _approvalCard(event)).toList(),
        ),
      Text(message, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Widget _settingsSection(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white60,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );

  Widget _approvalCard(Map<String, dynamic> event) {
    final params = event['params'] is Map
        ? Map<String, dynamic>.from(event['params'] as Map)
        : <String, dynamic>{};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${event['method']} #${event['id']}'),
            Text(
              params['command']?.toString() ??
                  params['reason']?.toString() ??
                  'Codex requests approval',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                TextButton(
                  onPressed: busy ? null : () => answer(event, 'decline'),
                  child: const Text('Decline'),
                ),
                TextButton(
                  onPressed: busy ? null : () => answer(event, 'accept'),
                  child: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(String label, IconData icon) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 42, color: Colors.white24),
        const SizedBox(height: 12),
        Text(label, style: const TextStyle(color: Colors.white54)),
      ],
    ),
  );

  Map<String, List<Map<String, dynamic>>> _groupedThreads() {
    final groups = <String, List<Map<String, dynamic>>>{};
    final query = search.text.trim().toLowerCase();
    for (final thread in threads) {
      if (query.isNotEmpty &&
          !_threadTitle(thread).toLowerCase().contains(query)) {
        continue;
      }
      final age = DateTime.now().difference(_threadDate(thread));
      final group = age <= const Duration(days: 1)
          ? 'Today'
          : age <= const Duration(days: 7)
          ? 'Previous 7 days'
          : age <= const Duration(days: 30)
          ? 'Previous 30 days'
          : 'Older';
      groups.putIfAbsent(group, () => []).add(thread);
    }
    return groups;
  }

  String _threadId(Map<String, dynamic> thread) =>
      '${thread['id'] ?? thread['threadId'] ?? ''}';

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

  DateTime _threadDate(Map<String, dynamic> thread) {
    for (final key in [
      'updatedAt',
      'lastUpdatedAt',
      'createdAt',
      'timestamp',
    ]) {
      final parsed = DateTime.tryParse('${thread[key]}');
      if (parsed != null) return parsed.toLocal();
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
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
