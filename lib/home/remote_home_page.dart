import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';

part 'thread_data.dart';
part 'settings_view.dart';
part 'thread_view.dart';
part 'home_scaffold.dart';

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
  String activeTurnId = '';
  String processingSummary = '';
  String processingItemId = '';
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
    _unsubscribeSelectedThread();
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
        final status = params['status'];
        if (method == 'thread/status/changed' && status is Map) {
          setState(() {
            for (final thread in threads) {
              if (_threadId(thread) == threadId) {
                thread['status'] = Map<String, dynamic>.from(status);
              }
            }
            threads.sort(compareRemoteThreads);
          });
        }
        if (method == 'item/agentMessage/delta' && threadId == selectedThread) {
          _appendAssistantDelta(params);
        }
        if (method == 'turn/started' && threadId == selectedThread) {
          setState(() {
            activeTurnId = activeTurnIdFrom(params);
            processingSummary = 'Working...';
            processingItemId = '';
          });
        }
        if (method == 'item/started' && threadId == selectedThread) {
          final item = params['item'];
          final summary = processingSummaryFromItem(item);
          if (summary.isNotEmpty) {
            setState(() {
              processingSummary = summary;
              processingItemId = '${item is Map ? item['id'] ?? '' : ''}';
            });
          }
        }
        if (method == 'item/reasoning/summaryTextDelta' &&
            threadId == selectedThread) {
          final delta = '${params['delta'] ?? ''}';
          if (delta.isNotEmpty) {
            final itemId = '${params['itemId'] ?? ''}';
            setState(() {
              processingSummary = processingItemId == itemId
                  ? '$processingSummary$delta'
                  : 'Thinking: $delta';
              processingItemId = itemId;
            });
          }
        }
        if (method == 'item/completed' && threadId == selectedThread) {
          final itemId =
              '${params['item'] is Map ? params['item']['id'] ?? '' : ''}';
          if (itemId == processingItemId) {
            setState(() => processingSummary = 'Working...');
          }
        }
        if (method == 'turn/completed' && threadId == selectedThread) {
          setState(() {
            activeTurnId = '';
            processingSummary = '';
            processingItemId = '';
          });
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
      next.sort(compareRemoteThreads);
      if (!mounted) return;
      final historyThread = selectedThread;
      setState(() {
        threads = next;
        // A newly-created thread can be absent from list results briefly.
      });
      if (historyThread != null) await _loadHistory(historyThread, force: true);
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
      final thread = threads.firstWhere(
        (item) => _threadId(item) == id,
        orElse: () => <String, dynamic>{},
      );
      if (_threadNeedsResume(thread)) await api!.resumeThread(id);
      final active = remoteThreadIsActive(thread);
      dynamic response;
      if (active) {
        var turnId = activeTurnId;
        if (turnId.isEmpty) turnId = activeTurnIdFrom(await api!.thread(id));
        if (turnId.isEmpty) {
          throw ApiException(
            'Unable to find the active turn. Refresh and try again.',
            statusCode: 409,
          );
        }
        response = await api!.steerTurn(id, turnId, text);
      } else {
        response = await api!.startTurn(id, text);
      }
      if (!mounted || selectedThread != id) return;
      final responseTurnId = activeTurnIdFrom(response);
      setState(() {
        if (input.text.trim() == text) input.clear();
        history = [
          ...history,
          {'role': 'user', 'content': text},
        ];
        if (responseTurnId.isNotEmpty) activeTurnId = responseTurnId;
        message = active ? 'Message sent' : 'Turn started';
      });
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
        activeTurnId = activeTurnIdFrom(value);
        if (activeTurnId.isEmpty) {
          processingSummary = '';
          processingItemId = '';
        } else if (processingSummary.isEmpty) {
          processingSummary = 'Working...';
        }
        loadedHistoryFor = id;
      });
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => loadingHistory = false);
    }
  }

  void _openThread(String id) {
    _unsubscribeSelectedThread(id);
    setState(() {
      selectedThread = id;
      selectedProject = null;
      projectsView = false;
      settingsOpen = false;
      loadedHistoryFor = null;
      activeTurnId = '';
      processingSummary = '';
      processingItemId = '';
      history = [];
    });
    _loadHistory(id);
  }

  void _openSettings() {
    Navigator.of(context).maybePop();
    _unsubscribeSelectedThread();
    setState(() {
      settingsOpen = true;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showThreads() {
    Navigator.of(context).maybePop();
    _unsubscribeSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showRecent() {
    Navigator.of(context).maybePop();
    _unsubscribeSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showProjects() {
    Navigator.of(context).maybePop();
    _unsubscribeSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = true;
    });
  }

  void _selectProject(String project) {
    Navigator.of(context).maybePop();
    _unsubscribeSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = project;
      projectsView = false;
    });
  }

  void _unsubscribeSelectedThread([String? nextThread]) {
    final id = selectedThread;
    if (id != null && id != nextThread) unawaited(_unsubscribeThread(id));
  }

  Future<void> _unsubscribeThread(String id) async {
    try {
      await api?.unsubscribeThread(id);
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    }
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
        final disconnected = error is ApiException && error.isConnectionFailure;
        setState(() {
          message = error.toString();
          if (disconnected) connected = false;
        });
        if (disconnected) threadRefreshTimer?.cancel();
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _homeScaffold(context);

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
