import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';

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
  static const endpointKey = 'desktop_endpoint';
  static const tokenKey = 'device_token';
  static const secureStorage = FlutterSecureStorage();
  static const threadPageSize = 100;
  final endpoint = TextEditingController();
  final pairingToken = TextEditingController();
  final deviceName = TextEditingController(text: 'Phone');
  final accessToken = TextEditingController();
  final input = TextEditingController();
  final search = TextEditingController();
  RemoteApi? api;
  StreamSubscription<Map<String, dynamic>>? eventSubscription;
  Timer? threadRefreshTimer;
  Future<void>? threadReload;
  List<Map<String, dynamic>> threads = [];
  List<Map<String, dynamic>> approvals = [];
  List<Map<String, dynamic>> history = [];
  String? selectedThread;
  String? selectedProject;
  bool projectsView = false;
  String message = 'Enter the desktop endpoint to begin.';
  bool busy = false;
  bool connected = false;
  bool settingsOpen = true;
  bool loadingHistory = false;
  String? loadedHistoryFor;

  @override
  void initState() {
    super.initState();
    _restoreConnection();
  }

  @override
  void dispose() {
    eventSubscription?.cancel();
    threadRefreshTimer?.cancel();
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
      await _saveConnection();
      final client = RemoteApi(endpoint.text);
      final value = await client.pair(pairingToken.text, deviceName.text);
      accessToken.text = _stringValue(value, 'token');
      await connect();
    });
  }

  Future<void> connect() async {
    await _run('Connecting...', () async {
      await _saveConnection();
      final client = RemoteApi(endpoint.text, token: accessToken.text);
      await client.status();
      api = client;
      connected = true;
      await _reloadThreads();
      _listenEvents(client);
      _startThreadRefresh();
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

  Future<void> _reloadThreads() {
    final current = threadReload;
    if (current != null) return current;
    final future = _performThreadReload();
    threadReload = future;
    unawaited(
      future.whenComplete(() {
        if (identical(threadReload, future)) threadReload = null;
      }),
    );
    return future;
  }

  Future<void> _performThreadReload() async {
    final client = api;
    if (client == null) return;
    try {
      final pages = <Map<String, dynamic>>[];
      String? cursor;
      do {
        final value = await client.threads(
          cursor: cursor,
          limit: threadPageSize,
        );
        final list = value is Map ? value['data'] ?? value['threads'] : value;
        if (list is List) {
          pages.addAll(
            list.whereType<Map>().map(
              (item) => Map<String, dynamic>.from(item),
            ),
          );
        }
        final next = value is Map
            ? '${value['nextCursor'] ?? value['next_cursor'] ?? ''}'
            : '';
        if (next.isEmpty || next == cursor || list is! List || list.isEmpty) {
          break;
        }
        cursor = next;
      } while (true);
      final seen = <String>{};
      final next = pages
          .where((thread) => _threadId(thread).isNotEmpty)
          .where((thread) => seen.add(_threadId(thread)))
          .toList();
      next.sort((a, b) => _threadDate(b).compareTo(_threadDate(a)));
      if (!mounted) return;
      setState(() {
        threads = next;
        // A newly-created thread can be absent from list results briefly.
      });
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    }
  }

  void _startThreadRefresh() {
    threadRefreshTimer?.cancel();
    threadRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (connected) unawaited(_reloadThreads());
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
      selectedProject = null;
      projectsView = false;
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
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showThreads() {
    Navigator.of(context).maybePop();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showRecent() {
    Navigator.of(context).maybePop();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showProjects() {
    Navigator.of(context).maybePop();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = true;
    });
  }

  void _selectProject(String project) {
    Navigator.of(context).maybePop();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = project;
      projectsView = false;
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
        threadRefreshTimer?.cancel();
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
              : projectsView
              ? 'Projects'
              : selectedProject ?? 'Recent',
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
          : projectsView
          ? _projectsView()
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
            padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
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
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _drawerItem(Icons.add, 'New', false, () {
                  Navigator.pop(context);
                  if (!busy) createThread();
                }),
                const Divider(height: 24),
                _drawerLabel('Recent'),
                for (final thread in threads.take(5))
                  _recentEntry(context, thread),
                if (threads.length > 5)
                  _moreEntry('More recent chats', _showRecent),
                if (threads.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Text(
                      'No recent chats',
                      style: TextStyle(color: Colors.white38),
                    ),
                  ),
                const Divider(height: 24),
                _drawerLabel('Projects'),
                for (final project in _projects().take(5))
                  _projectEntry(context, project),
                if (_projects().length > 5)
                  _moreEntry('More projects', _showProjects),
                if (_projects().isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Text(
                      'No projects',
                      style: TextStyle(color: Colors.white38),
                    ),
                  ),
              ],
            ),
          ),
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

  Widget _drawerLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white60,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _recentEntry(BuildContext context, Map<String, dynamic> thread) =>
      ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(
          _threadTitle(thread),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: _threadMeta(thread),
        onTap: () {
          Navigator.pop(context);
          _openThread(_threadId(thread));
        },
      );

  Widget _projectEntry(BuildContext context, String project) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: const Icon(Icons.folder_outlined, size: 20),
    title: Text(project, overflow: TextOverflow.ellipsis),
    selected: selectedProject == project && selectedThread == null,
    onTap: () => _selectProject(project),
  );

  Widget _moreEntry(String label, VoidCallback onTap) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: const Icon(Icons.more_horiz),
    title: Text(label),
    trailing: const Icon(Icons.chevron_right, size: 18),
    onTap: onTap,
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
    final visible = _visibleThreads();
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
          child: RefreshIndicator(
            onRefresh: _reloadThreads,
            child: visible.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                    children: [
                      SizedBox(
                        height: 240,
                        child: _emptyState(
                          connected
                              ? 'No threads yet'
                              : 'Connect from Settings to begin',
                          Icons.forum_outlined,
                        ),
                      ),
                    ],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                    children: [
                      for (final thread in visible) _threadEntry(thread),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _projectsView() {
    final projects = _projects();
    return RefreshIndicator(
      onRefresh: _reloadThreads,
      child: projects.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: 240,
                  child: _emptyState('No projects yet', Icons.folder_outlined),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              itemCount: projects.length,
              itemBuilder: (context, index) => ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  projects[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _selectProject(projects[index]),
              ),
            ),
    );
  }

  Widget _threadEntry(Map<String, dynamic> thread) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 4),
    title: Text(
      _threadTitle(thread),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
    ),
    subtitle: _threadMeta(thread),
    onTap: () => _openThread(_threadId(thread)),
  );

  Widget _threadMeta(Map<String, dynamic> thread) => Row(
    children: [
      Expanded(child: Text(_timeLabel(_threadDate(thread)))),
      if (_threadProject(thread).isNotEmpty)
        Flexible(
          child: Text(
            _threadProject(thread),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          ),
        ),
    ],
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
              onPressed: busy ? null : _clearToken,
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
    for (final thread in threads) {
      final project = _threadProject(thread);
      if (project.isEmpty) continue;
      final date = _threadDate(thread);
      final previous = latest[project];
      if (previous == null || date.isAfter(previous)) latest[project] = date;
    }
    final projects = latest.keys.toList()
      ..sort((a, b) {
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
    return '';
  }

  DateTime _threadDate(Map<String, dynamic> thread) {
    for (final key in [
      'updatedAt',
      'lastUpdatedAt',
      'createdAt',
      'timestamp',
    ]) {
      final parsed = parseRemoteTimestamp(thread[key]);
      if (parsed != null) return parsed;
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

  Future<void> _restoreConnection() async {
    try {
      final savedEndpoint = await secureStorage.read(key: endpointKey);
      final savedToken = await secureStorage.read(key: tokenKey);
      if (!mounted) return;
      if (endpoint.text.isEmpty && savedEndpoint != null) {
        endpoint.text = savedEndpoint;
      }
      if (accessToken.text.isEmpty && savedToken != null) {
        accessToken.text = savedToken;
      }
    } catch (_) {
      // Stored connection settings are optional; the user can enter them again.
    }
  }

  Future<void> _saveConnection() async {
    try {
      final endpointValue = endpoint.text.trim();
      if (endpointValue.isEmpty) {
        await secureStorage.delete(key: endpointKey);
      } else {
        await secureStorage.write(key: endpointKey, value: endpointValue);
      }
      final tokenValue = accessToken.text.trim();
      if (tokenValue.isEmpty) {
        await secureStorage.delete(key: tokenKey);
      } else {
        await secureStorage.write(key: tokenKey, value: tokenValue);
      }
    } catch (_) {
      // A storage failure must not prevent an otherwise valid connection.
    }
  }

  void _clearToken() {
    setState(accessToken.clear);
    unawaited(secureStorage.delete(key: tokenKey));
  }
}
