import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../i18n.dart';
import '../storage/connection_store.dart';
import '../storage/thread_cache.dart';
import 'pairing_payload.dart';

part 'thread_data.dart';
part 'settings_view.dart';
part 'thread_view.dart';
part 'home_scaffold.dart';
part 'pairing_scanner.dart';
part 'connection_controller.dart';
part 'remote_events.dart';

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

enum RemoteConnectionStatus { offline, connecting, reconnecting, online }

Timer startPeriodicRefresh({
  required Duration interval,
  required bool Function() active,
  required Future<void> Function() refresh,
}) {
  var refreshing = false;
  return Timer.periodic(interval, (timer) async {
    if (!active()) {
      timer.cancel();
    } else if (!refreshing) {
      refreshing = true;
      try {
        await refresh();
      } finally {
        refreshing = false;
      }
    }
  });
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  static const threadPageSize = 100;
  static const connectionStore = ConnectionStore(FlutterSecureStorage());
  static const threadCache = ThreadCache();
  final endpoint = TextEditingController();
  final accessToken = TextEditingController();
  final input = TextEditingController();
  final search = TextEditingController();
  RemoteApi? api;
  StreamSubscription<Map<String, dynamic>>? eventSubscription;
  Timer? historyRefreshTimer;
  Future<void>? connectionRecovery;
  Future<void>? threadReload;
  Future<void> threadCacheWrite = Future.value();
  List<Map<String, dynamic>> threads = [];
  Map<String, List<Map<String, dynamic>>> historyCache = {};
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
  RemoteConnectionStatus connectionStatus = RemoteConnectionStatus.offline;
  String? activeConnectionId;
  bool settingsOpen = true;
  bool loadingHistory = false;
  bool threadClaiming = false;
  bool threadOwned = false;
  bool threadConflict = false;
  bool uploadingAttachments = false;
  int uploadingAttachmentIndex = 0;
  double attachmentProgress = 0;
  String? loadedHistoryFor;
  final pendingReleases = <String>{};
  List<PlatformFile> attachments = [];
  RemotePermissionMode permissionMode = RemotePermissionMode.requestApproval;

  bool get connected => connectionStatus == RemoteConnectionStatus.online;

  void _showConnectionStatus(RemoteConnectionStatus status) {
    if (mounted) setState(() => connectionStatus = status);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_restoreConnection());
  }

  @override
  void dispose() {
    _releaseSelectedThread();
    historyRefreshTimer?.cancel();
    eventSubscription?.cancel();
    unawaited(api?.close());
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
      if (!mounted || !identical(api, client)) return;
      final historyThread = selectedThread;
      setState(() {
        threads = next;
        // A newly-created thread can be absent from list results briefly.
      });
      _queueThreadCacheWrite();
      if (historyThread != null) await _loadHistory(historyThread, force: true);
      if (pendingReleases.isNotEmpty) {
        await _releaseThread(pendingReleases.first);
      }
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    }
  }

  Future<void> createThread() async {
    await _run(context.t('startingThread'), () async {
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
            title: Text(context.t('chooseStartupFolder')),
            content: SizedBox(
              width: double.maxFinite,
              height: 360,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: context.t('parentFolder'),
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
                        ? Center(child: Text(context.t('noSubfolders')))
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
                child: Text(context.t('cancel')),
              ),
              FilledButton(
                onPressed: loading || listing.path.isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, listing.path),
                child: Text(context.t('useFolder')),
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
    _queueThreadCacheWrite();
  }

  Future<void> sendTurn() async {
    final id = selectedThread;
    final text = input.text.trim();
    if (id == null || !threadOwned || (text.isEmpty && attachments.isEmpty)) {
      return;
    }
    await _run(context.t('sending'), () async {
      if (!mounted || selectedThread != id) return;
      final thread = threads.firstWhere(
        (item) => _threadId(item) == id,
        orElse: () => <String, dynamic>{},
      );
      if (_threadNeedsResume(thread)) await api!.resumeThread(id);
      final active = remoteThreadIsActive(thread);
      final uploaded = <RemoteAttachment>[];
      final pendingAttachments = List<PlatformFile>.of(attachments);
      for (var index = 0; index < pendingAttachments.length; index++) {
        final attachment = pendingAttachments[index];
        if (mounted) {
          setState(() {
            uploadingAttachments = true;
            uploadingAttachmentIndex = index + 1;
            attachmentProgress = 0;
          });
        }
        final totalBytes = await attachment.length();
        uploaded.add(
          await api!.upload(
            attachment.name,
            attachment.readAsByteStream(),
            onProgress: (bytesRead) {
              if (!mounted) return;
              setState(() {
                attachmentProgress = totalBytes == 0
                    ? 1
                    : (bytesRead / totalBytes).clamp(0, 1).toDouble();
              });
            },
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
        message = active ? context.t('messageSent') : context.t('turnStarted');
      });
      _cacheCurrentHistory();
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
    _cacheCurrentHistory();
  }

  Future<void> answer(Map<String, dynamic> event, String decision) async {
    final id = event['id'];
    if (id is! int) return;
    await _run(context.t('sendingDecision'), () async {
      await api!.approve(id, decision);
      if (mounted) {
        setState(() => approvals.removeWhere((item) => item['id'] == id));
      }
    });
  }

  Future<void> _loadHistory(String? id, {bool force = false}) async {
    final client = api;
    if (id == null || client == null || (!force && loadedHistoryFor == id)) {
      return;
    }
    setState(() {
      loadingHistory = true;
      if (!force) history = [];
    });
    try {
      final value = await client.thread(id);
      if (!mounted || selectedThread != id || !identical(api, client)) return;
      final snapshotSummary = processingSummaryFromThread(
        value,
        AppLocalizations.of(context),
      );
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
          processingSummary = context.t('working');
        }
        loadedHistoryFor = id;
      });
      _cacheCurrentHistory();
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => loadingHistory = false);
    }
  }

  void _openThread(String id, {bool owned = false}) {
    _releaseSelectedThread(id);
    _stopHistoryRefresh();
    setState(() {
      selectedThread = id;
      selectedProject = null;
      projectsView = false;
      settingsOpen = false;
      loadedHistoryFor = null;
      activeTurnId = '';
      processingSummary = '';
      processingItemId = '';
      history =
          historyCache[id]
              ?.map((item) => Map<String, dynamic>.from(item))
              .toList() ??
          [];
      threadClaiming = !owned;
      threadOwned = owned;
      threadConflict = false;
    });
    _loadHistory(id, force: true);
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

  void _showThreads({bool popRoute = true}) {
    if (popRoute) Navigator.of(context).maybePop();
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
      _stopHistoryRefresh();
    } catch (error) {
      if (!mounted || selectedThread != id) return;
      final conflict = error is ApiException && error.isConflict;
      setState(() {
        threadClaiming = false;
        threadOwned = false;
        threadConflict = conflict;
        message = conflict
            ? context.t('activeThreadReadOnly')
            : error.toString();
      });
      if (conflict) {
        _startHistoryRefresh(id);
      } else {
        _stopHistoryRefresh();
      }
    }
  }

  void _startHistoryRefresh(String id) {
    _stopHistoryRefresh();
    if (connected && !loadingHistory) {
      unawaited(_loadHistory(id, force: true));
    }
    historyRefreshTimer = startPeriodicRefresh(
      interval: const Duration(seconds: 1),
      active: () => mounted && selectedThread == id && threadConflict,
      refresh: () => connected && !loadingHistory
          ? _loadHistory(id, force: true)
          : Future.value(),
    );
  }

  void _stopHistoryRefresh() {
    historyRefreshTimer?.cancel();
    historyRefreshTimer = null;
  }

  void _releaseSelectedThread([String? nextThread]) {
    final id = selectedThread;
    if (id == null || id == nextThread) return;
    _stopHistoryRefresh();
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
        title: Text(context.t('takeOverThreadQuestion')),
        content: Text(context.t('takeOverDescription')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.t('takeOver')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || selectedThread != id) return;
    await _run(context.t('takingOver'), () async {
      await api!.takeOverThread(id);
      if (!mounted || selectedThread != id) {
        await _releaseThread(id);
        return;
      }
      setState(() {
        threadOwned = true;
        threadConflict = false;
        message = context.t('threadTakenOver');
      });
      _stopHistoryRefresh();
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
        final client = api;
        setState(() {
          if (disconnected && client == null) {
            connectionStatus = RemoteConnectionStatus.offline;
            message = context.t('disconnected', {'error': '$error'});
          } else if (!disconnected) {
            message = error.toString();
          }
        });
        if (disconnected && client != null) {
          unawaited(_startReconnect(client));
        }
        if (!disconnected) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          uploadingAttachments = false;
          uploadingAttachmentIndex = 0;
          attachmentProgress = 0;
        });
      }
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 1)),
      );
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
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: context.t('searchThreads'),
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
                              ? context.t('noThreadsYet')
                              : context.t('connectFromSettings'),
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

  void _cacheCurrentHistory() {
    final id = selectedThread;
    if (id == null) return;
    if (history.isEmpty) {
      historyCache.remove(id);
    } else {
      historyCache[id] = history
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    _queueThreadCacheWrite();
  }

  void _queueThreadCacheWrite() {
    final serverId = activeConnectionId;
    if (serverId == null) return;
    threadCacheWrite = threadCacheWrite.then((_) async {
      try {
        await threadCache.write(serverId, threads, historyCache);
      } catch (_) {
        // Cache storage is optional; the live connection remains authoritative.
      }
    });
  }

  Future<void> _restoreThreadCache(String serverId) async {
    var snapshot = const ThreadCacheSnapshot(threads: [], history: {});
    try {
      snapshot = await threadCache.read(serverId);
    } catch (_) {
      // A stale or unavailable cache must not block a live connection.
    }
    if (!mounted || activeConnectionId != serverId) return;
    setState(() {
      threads = snapshot.threads;
      historyCache = snapshot.history;
      final id = selectedThread;
      history = id == null
          ? []
          : snapshot.history[id]
                    ?.map((item) => Map<String, dynamic>.from(item))
                    .toList() ??
                [];
    });
  }
}
