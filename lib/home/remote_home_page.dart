import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api.dart';

part 'thread_data.dart';
part 'settings_view.dart';

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
        title: settingsOpen
            ? const Text('Settings')
            : detail
            ? _threadAppBarTitle(selectedThread!)
            : Text(
                projectsView
                    ? 'Projects'
                    : selectedProject == null
                    ? 'Recent'
                    : _projectLabel(selectedProject!),
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
          _drawerItem(Icons.add, 'New', false, () {
            Navigator.pop(context);
            if (!busy) createThread();
          }),
          const Divider(height: 24),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reloadThreads,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
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
    title: Text(_projectLabel(project), overflow: TextOverflow.ellipsis),
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
                  _projectLabel(projects[index]),
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

  Widget _threadAppBarTitle(String id) {
    final cwd = _threadCwd(id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_threadTitle(id), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (cwd.isNotEmpty)
          Text(
            cwd,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
      ],
    );
  }

  Widget _threadMeta(Map<String, dynamic> thread) => Row(
    children: [
      Expanded(child: Text(_timeLabel(_threadDate(thread)))),
      if (_threadProject(thread).isNotEmpty)
        Flexible(
          child: Text(
            _projectLabel(_threadProject(thread)),
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
