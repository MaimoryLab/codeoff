import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';

part 'thread_data.dart';
part 'settings_view.dart';
part 'thread_view.dart';
part 'home_scaffold.dart';

class _DirectoryListing {
  const _DirectoryListing({
    required this.path,
    required this.parent,
    required this.directories,
  });

  final String path;
  final String parent;
  final List<Map<String, String>> directories;

  factory _DirectoryListing.from(dynamic value) {
    if (value is! Map) throw ApiException('Invalid directory response');
    final entries = value['directories'];
    return _DirectoryListing(
      path: '${value['path'] ?? ''}',
      parent: '${value['parent'] ?? ''}',
      directories: entries is List
          ? entries
                .whereType<Map>()
                .map(
                  (entry) => {
                    'name': '${entry['name'] ?? ''}',
                    'path': '${entry['path'] ?? ''}',
                  },
                )
                .where((entry) => entry['name']!.isNotEmpty)
                .toList()
          : const [],
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
  static const connectionsKey = 'connections';
  static const permissionModeKey = 'permission_mode';
  static const secureStorage = FlutterSecureStorage();
  static const threadPageSize = 100;
  final endpoint = TextEditingController();
  final accessToken = TextEditingController();
  final input = TextEditingController();
  final search = TextEditingController();
  RemoteApi? api;
  StreamSubscription<Map<String, dynamic>>? eventSubscription;
  Timer? threadRefreshTimer;
  Future<void>? threadReload;
  List<Map<String, dynamic>> threads = [];
  List<Map<String, dynamic>> approvals = [];
  List<Map<String, String>> connections = [];
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
  String? activeConnectionId;
  bool settingsOpen = true;
  bool loadingHistory = false;
  bool threadClaiming = false;
  bool threadOwned = false;
  bool threadConflict = false;
  String? loadedHistoryFor;
  final pendingReleases = <String>{};
  List<PlatformFile> attachments = [];
  RemotePermissionMode permissionMode = RemotePermissionMode.requestApproval;

  @override
  void initState() {
    super.initState();
    _restoreConnection();
  }

  @override
  void dispose() {
    _releaseSelectedThread();
    eventSubscription?.cancel();
    threadRefreshTimer?.cancel();
    for (final controller in [endpoint, accessToken, input, search]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> pickAttachments(FileType type) async {
    final picked = await FilePicker.pickFiles(type: type);
    if (!mounted || picked.isEmpty) return;
    setState(() => attachments = [...attachments, ...picked]);
  }

  void removeAttachment(PlatformFile attachment) {
    if (mounted) setState(() => attachments.remove(attachment));
  }

  Future<void> connect() async {
    await _run('Connecting...', () async {
      final endpointValue = endpoint.text.trim();
      if (endpointValue.isEmpty) throw ApiException('Endpoint is required');
      var token = accessToken.text.trim();
      final saved = connections.where(
        (item) => item['endpoint'] == endpointValue,
      );
      if (saved.isNotEmpty) {
        token = saved.first['token']!;
      } else if (activeConnectionId == null ||
          connections.any(
            (item) =>
                item['serverId'] == activeConnectionId &&
                item['endpoint'] != endpointValue,
          )) {
        token = '';
      }
      Map<String, dynamic>? pairing;
      if (token.isEmpty) {
        pairing = await _pairDialog();
        if (pairing == null) return;
        final value = await RemoteApi(endpointValue)
            .pair('${pairing['token']}', '${pairing['name']}');
        token = _stringValue(value, 'token');
        pairing = _serverFrom(value);
      }
      await _connectRecord(endpointValue, token, pairing: pairing);
    });
  }

  Future<void> _connectRecord(
    String endpointValue,
    String token, {
    Map<String, dynamic>? pairing,
  }) async {
    await _disconnect();
    final client = RemoteApi(endpointValue, token: token);
    final status = await client.status();
    final server = _serverFrom(status);
    final serverId = '${server['id'] ?? pairing?['id'] ?? endpointValue}';
    final previous = connections.where((item) => item['serverId'] == serverId);
    final record = <String, String>{
      'serverId': serverId,
      'name': previous.isEmpty
          ? '${server['name'] ?? pairing?['name'] ?? endpointValue}'
          : previous.first['name']!,
      'endpoint': endpointValue,
      'token': token,
    };
    final index = connections.indexWhere(
      (item) => item['serverId'] == record['serverId'],
    );
    if (index == -1) {
      connections = [record, ...connections];
    } else {
      connections = [...connections]
        ..[index] = {...connections[index], ...record};
    }
    activeConnectionId = record['serverId'];
    endpoint.text = endpointValue;
    accessToken.text = token;
    await _saveConnection();
    api = client;
    connected = true;
    await _reloadThreads();
    _listenEvents(client);
    _startThreadRefresh();
    settingsOpen = false;
    message = 'Connected';
    _toast('Connected to ${record['name']}');
  }

  Future<Map<String, dynamic>?> _pairDialog() {
    final token = TextEditingController();
    final name = TextEditingController(text: _defaultDeviceName);
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pair this device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: token,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Pairing code'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Device name'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (token.text.trim().isEmpty || name.text.trim().isEmpty) return;
              Navigator.pop(dialogContext, {
                'token': token.text.trim(),
                'name': name.text.trim(),
              });
            },
            child: const Text('Pair'),
          ),
        ],
      ),
    ).whenComplete(() {
      token.dispose();
      name.dispose();
    });
  }

  String get _defaultDeviceName => Platform.localHostname.trim().isEmpty
      ? 'Mobile device'
      : Platform.localHostname;

  Map<String, dynamic> _serverFrom(dynamic value) {
    if (value is! Map) return {};
    final server = value['server'];
    if (server is Map) return Map<String, dynamic>.from(server);
    return {};
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
        if (method == 'thread/name/updated') {
          final name = '${params['threadName'] ?? params['name'] ?? ''}'.trim();
          if (name.isNotEmpty) {
            setState(() {
              for (final thread in threads) {
                if (_threadId(thread) == threadId) thread['name'] = name;
              }
            });
          }
        }
        if (method == 'thread/archived') {
          setState(() {
            threads.removeWhere((thread) => _threadId(thread) == threadId);
          });
          if (selectedThread == threadId) _showThreads();
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
      if (pendingReleases.isNotEmpty) {
        await _releaseThread(pendingReleases.first);
      }
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
      final cwd = await _selectDirectory();
      if (cwd == null) return;
      final value = await api!.startThread(cwd: cwd);
      final id = _idFromValue(value);
      await _reloadThreads();
      if (id.isNotEmpty) _openThread(id, owned: true);
    });
  }

  Future<String?> _selectDirectory() async {
    final client = api;
    if (client == null) throw ApiException('Not connected');
    var listing = _DirectoryListing.from(await client.directories());
    if (!mounted) return null;
    var loading = false;
    String? error;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> openDirectory(String path) async {
            setDialogState(() {
              loading = true;
              error = null;
            });
            try {
              listing = _DirectoryListing.from(
                await client.directories(path: path),
              );
            } catch (value) {
              error = value.toString();
            } finally {
              if (dialogContext.mounted) {
                setDialogState(() => loading = false);
              }
            }
          }

          return AlertDialog(
            title: const Text('Choose startup folder'),
            content: SizedBox(
              width: double.maxFinite,
              height: 360,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Parent folder',
                        onPressed: loading || listing.parent.isEmpty
                            ? null
                            : () => openDirectory(listing.parent),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      Expanded(
                        child: Text(
                          listing.path,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: loading
                        ? const Center(child: CircularProgressIndicator())
                        : listing.directories.isEmpty
                        ? const Center(child: Text('No subfolders'))
                        : ListView.builder(
                            itemCount: listing.directories.length,
                            itemBuilder: (context, index) {
                              final directory = listing.directories[index];
                              return ListTile(
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(directory['name']!),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => openDirectory(directory['path']!),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: loading ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: loading || listing.path.isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, listing.path),
                child: const Text('Use folder'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _setThreadName(Map<String, dynamic> thread, String name) {
    if (!mounted) return;
    setState(() => thread['name'] = name);
  }

  Future<void> sendTurn() async {
    final id = selectedThread;
    final text = input.text.trim();
    if (id == null || !threadOwned || (text.isEmpty && attachments.isEmpty)) {
      return;
    }
    await _run('Sending...', () async {
      if (!mounted || selectedThread != id) return;
      final thread = threads.firstWhere(
        (item) => _threadId(item) == id,
        orElse: () => <String, dynamic>{},
      );
      if (_threadNeedsResume(thread)) await api!.resumeThread(id);
      final active = remoteThreadIsActive(thread);
      final uploaded = <RemoteAttachment>[];
      for (final attachment in attachments) {
        uploaded.add(
          await api!.upload(
            attachment.name,
            attachment.readAsByteStream(),
            await attachment.length(),
          ),
        );
      }
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
        response = await api!.steerTurn(
          id,
          turnId,
          text,
          attachments: uploaded,
        );
      } else {
        response = await api!.startTurn(
          id,
          text,
          attachments: uploaded,
          permissions: permissionMode,
        );
      }
      if (!mounted || selectedThread != id) return;
      final responseTurnId = activeTurnIdFrom(response);
      setState(() {
        if (input.text.trim() == text) {
          input.clear();
          attachments = [];
        }
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
      if (mounted) {
        setState(() => approvals.removeWhere((item) => item['id'] == id));
      }
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
      final snapshotSummary = processingSummaryFromThread(value);
      setState(() {
        history = _historyItems(value);
        activeTurnId = activeTurnIdFrom(value);
        if (snapshotSummary.isNotEmpty) {
          processingSummary = snapshotSummary;
          processingItemId = '';
        } else if (activeTurnId.isEmpty) {
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

  void _openThread(String id, {bool owned = false}) {
    _releaseSelectedThread(id);
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
      threadClaiming = !owned;
      threadOwned = owned;
      threadConflict = false;
    });
    _loadHistory(id);
    if (!owned) _claimThread(id);
  }

  void _openSettings() {
    Navigator.of(context).maybePop();
    _releaseSelectedThread();
    setState(() {
      settingsOpen = true;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showThreads() {
    Navigator.of(context).maybePop();
    _releaseSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showRecent() {
    Navigator.of(context).maybePop();
    _releaseSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = false;
    });
  }

  void _showProjects() {
    Navigator.of(context).maybePop();
    _releaseSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = null;
      projectsView = true;
    });
  }

  void _selectProject(String project) {
    Navigator.of(context).maybePop();
    _releaseSelectedThread();
    setState(() {
      settingsOpen = false;
      selectedThread = null;
      selectedProject = project;
      projectsView = false;
    });
  }

  Future<void> _claimThread(String id) async {
    try {
      final client = api;
      if (client == null) throw ApiException('Not connected');
      await client.resumeThread(id);
      if (!mounted || selectedThread != id) {
        await _releaseThread(id);
        return;
      }
      setState(() {
        threadClaiming = false;
        threadOwned = true;
        threadConflict = false;
      });
    } catch (error) {
      if (!mounted || selectedThread != id) return;
      final conflict = error is ApiException && error.isConflict;
      setState(() {
        threadClaiming = false;
        threadOwned = false;
        threadConflict = conflict;
        message = conflict
            ? 'Active in another app. This thread is read-only.'
            : error.toString();
      });
    }
  }

  void _releaseSelectedThread([String? nextThread]) {
    final id = selectedThread;
    if (id == null || id == nextThread) return;
    final owned = threadOwned;
    threadOwned = false;
    threadClaiming = false;
    threadConflict = false;
    if (owned) unawaited(_releaseThread(id));
  }

  Future<void> _takeOverThread() async {
    final id = selectedThread;
    if (id == null || !threadConflict) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Take over this thread?'),
        content: const Text(
          'This closes the desktop app using this thread. Other active threads in that app will also stop.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Take over'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || selectedThread != id) return;
    await _run('Taking over...', () async {
      await api!.takeOverThread(id);
      if (!mounted || selectedThread != id) {
        await _releaseThread(id);
        return;
      }
      setState(() {
        threadOwned = true;
        threadConflict = false;
        message = 'Thread taken over';
      });
      await _loadHistory(id, force: true);
    });
  }

  Future<void> _releaseThread(String id) async {
    try {
      final client = api;
      if (client == null) throw ApiException('Not connected');
      final value = await client.releaseThread(id);
      if (value is Map && value['released'] == true) {
        pendingReleases.clear();
        final selected = selectedThread;
        if (selected != null && threadOwned) {
          threadOwned = false;
          threadClaiming = true;
          await _claimThread(selected);
        }
      } else {
        pendingReleases.add(id);
      }
    } catch (error) {
      pendingReleases.add(id);
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
          if (disconnected) {
            connected = false;
            activeConnectionId = null;
          }
        });
        if (disconnected) threadRefreshTimer?.cancel();
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _disconnect() async {
    _releaseSelectedThread();
    await eventSubscription?.cancel();
    eventSubscription = null;
    threadRefreshTimer?.cancel();
    threadRefreshTimer = null;
    api = null;
    connected = false;
    activeConnectionId = null;
  }

  Future<void> _connectSaved(Map<String, String> record) async {
    endpoint.text = record['endpoint'] ?? '';
    accessToken.text = record['token'] ?? '';
    await connect();
  }

  Future<void> _editConnection(Map<String, String> record) async {
    final name = TextEditingController(text: record['name']);
    final changed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit connection'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, name.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    name.dispose();
    if (!mounted || changed == null || changed.isEmpty) return;
    final index = connections.indexOf(record);
    if (index == -1) return;
    setState(
      () =>
          connections = [...connections]
            ..[index] = {...record, 'name': changed},
    );
    await _saveConnection();
  }

  Future<void> _deleteConnection(Map<String, String> record) async {
    if (record['serverId'] == activeConnectionId) await _disconnect();
    if (!mounted) return;
    setState(() => connections = [...connections]..remove(record));
    await _saveConnection();
    _toast('Connection removed');
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
      final savedConnections = await secureStorage.read(key: connectionsKey);
      final savedEndpoint = await secureStorage.read(key: endpointKey);
      final savedToken = await secureStorage.read(key: tokenKey);
      final savedPermission = await secureStorage.read(key: permissionModeKey);
      if (!mounted) return;
      if (savedConnections != null && savedConnections.isNotEmpty) {
        final value = jsonDecode(savedConnections);
        if (value is List) {
          connections = value
              .whereType<Map>()
              .map(
                (item) => item.map((key, value) => MapEntry('$key', '$value')),
              )
              .where(
                (item) =>
                    item['endpoint']?.isNotEmpty == true &&
                    item['token']?.isNotEmpty == true,
              )
              .toList();
        }
      }
      if (endpoint.text.isEmpty && savedEndpoint != null) {
        endpoint.text = savedEndpoint;
      }
      if (accessToken.text.isEmpty && savedToken != null) {
        accessToken.text = savedToken;
      }
      if (connections.isEmpty &&
          endpoint.text.trim().isNotEmpty &&
          accessToken.text.trim().isNotEmpty) {
        connections = [
          {
            'serverId': endpoint.text.trim(),
            'name': endpoint.text.trim(),
            'endpoint': endpoint.text.trim(),
            'token': accessToken.text.trim(),
          },
        ];
      }
      setState(() {
        permissionMode = RemotePermissionMode.values.firstWhere(
          (mode) => mode.name == savedPermission,
          orElse: () => RemotePermissionMode.requestApproval,
        );
      });
    } catch (_) {
      // Stored connection settings are optional; the user can enter them again.
    }
  }

  Future<void> setPermissionMode(RemotePermissionMode mode) async {
    setState(() => permissionMode = mode);
    try {
      await secureStorage.write(key: permissionModeKey, value: mode.name);
    } catch (_) {
      // Permission persistence is optional; the selected mode still applies.
    }
  }

  Future<void> _saveConnection() async {
    try {
      await secureStorage.write(
        key: connectionsKey,
        value: jsonEncode(connections),
      );
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
}
