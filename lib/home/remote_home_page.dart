import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ota_update/ota_update.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../i18n.dart';
import '../local_notifications.dart';
import '../remote/remote_connection.dart';
import '../storage/connection_store.dart';
import '../storage/thread_cache.dart';
import '../connection/pairing_payload.dart';
import '../connection/connection_settings_view.dart';
import '../thread/view/operation_details_page.dart';
import '../thread/view/thread_list_page.dart';
import '../thread/view/thread_detail_page.dart';
import '../file/file_preview.dart';

part 'home_scaffold.dart';
part '../connection/connection_controller.dart';
part '../connection/pairing_scanner.dart';
part '../update/app_update.dart';
part '../thread/thread_controller.dart';
part '../thread/thread_data.dart';
part '../thread/thread_events.dart';
part '../thread/thread_session.dart';
part '../thread/view/thread_messages.dart';
part '../thread/view/thread_view.dart';

class _DirectoryListing {
  const _DirectoryListing({
    required this.path,
    required this.parent,
    required this.directories,
    required this.files,
  });

  final String path;
  final String parent;
  final List<Map<String, String>> directories;
  final List<Map<String, dynamic>> files;

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
      files: value['files'] is List
          ? (value['files'] as List)
                .whereType<Map>()
                .map(
                  (entry) => <String, dynamic>{
                    'name': '${entry['name'] ?? ''}',
                    'path': '${entry['path'] ?? ''}',
                    'size': entry['size'] is num ? entry['size'] : 0,
                  },
                )
                .where((entry) => (entry['name'] as String).isNotEmpty)
                .toList()
          : const [],
    );
  }
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({
    required this.version,
    required this.connectionStore,
    required this.remoteConnection,
    required this.threadCache,
    super.key,
  });

  final String version;
  final ConnectionStore connectionStore;
  final RemoteConnection remoteConnection;
  final ThreadCache threadCache;

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

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

class _RemoteHomePageState extends State<RemoteHomePage>
    with WidgetsBindingObserver {
  static const threadPageSize = 100;
  final endpoint = TextEditingController();
  final accessToken = TextEditingController();
  final input = TextEditingController();
  final search = TextEditingController();
  final threadScrollController = ScrollController();
  late final connectionStore = widget.connectionStore;
  late final remoteConnection = widget.remoteConnection;
  late final threadCache = widget.threadCache;
  late final StreamSubscription<RemoteConnectionStatus> statusSubscription;
  late final StreamSubscription<Map<String, dynamic>> eventSubscription;
  Timer? historyRefreshTimer;
  Future<void>? threadReload;
  List<Map<String, dynamic>> threads = [];
  Map<String, List<Map<String, dynamic>>> historyCache = {};
  List<Map<String, dynamic>> approvals = [];
  List<Map<String, dynamic>> history = [];
  String? selectedThread;
  String? selectedProject;
  String activeTurnId = '';
  String processingSummary = '';
  String processingItemId = '';
  List<Map<String, dynamic>> processingItems = [];
  final expandedOperationGroups = <String>{};
  int historyLoadRevision = 0;
  bool projectsView = false;
  String message = 'Enter the desktop endpoint to begin.';
  bool busy = false;
  String? activeConnectionId;
  bool settingsOpen = true;
  bool loadingHistory = false;
  bool threadClaiming = false;
  bool threadOwned = false;
  bool threadConflict = false;
  bool threadServerReleased = false;
  bool uploadingAttachments = false;
  int uploadingAttachmentIndex = 0;
  double attachmentProgress = 0;
  String? loadedHistoryFor;
  final pendingReleases = <String>{};
  final locallyReleasingThreads = <String>{};
  final notifiedThreads = <String>{};
  List<PlatformFile> attachments = [];
  RemotePermissionMode permissionMode = RemotePermissionMode.requestApproval;

  RemoteApi? get api => remoteConnection.client;
  List<Map<String, String>> get connections => connectionStore.connections;
  RemoteConnectionStatus get connectionStatus => remoteConnection.status;
  bool get connected => connectionStatus == RemoteConnectionStatus.online;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    statusSubscription = remoteConnection.statuses.listen(
      _handleConnectionStatus,
    );
    eventSubscription = remoteConnection.events.listen(_handleRemoteEvent);
    unawaited(_restoreConnection());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Platform.isAndroid) {
        unawaited(checkForUpdate(silent: true));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _releaseSelectedThread();
    historyRefreshTimer?.cancel();
    statusSubscription.cancel();
    eventSubscription.cancel();
    for (final controller in [
      endpoint,
      accessToken,
      input,
      search,
      threadScrollController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool appInBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appInBackground = switch (state) {
      AppLifecycleState.resumed => false,
      AppLifecycleState.inactive ||
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => true,
    };
    if (!appInBackground) notifiedThreads.clear();
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
            message = error.upgradeRequired
                ? context.t('upgradeRequired')
                : context.t('disconnected', {'error': '$error'});
          } else if (!disconnected) {
            message = error.toString();
          }
        });
        if (disconnected && client != null) {
          unawaited(reconnect());
        }
        if (error is ApiException && error.upgradeRequired) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(context.t('upgradeRequired'))),
          );
        } else {
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

  void _setMessage(String value) => setState(() => message = value);

  @override
  Widget build(BuildContext context) => _homeScaffold(context);

  Widget _settingsView() => ConnectionSettingsPage(
    endpoint: endpoint,
    busy: busy,
    connections: connections,
    version: widget.version,
    onConnect: connect,
    onScan: scanPairingCode,
    onConnectSaved: _connectSaved,
    onEdit: _editConnection,
    onDelete: _deleteConnection,
    onCheckForUpdates: () => checkForUpdate(),
  );

  Widget _threadsView() {
    return ThreadListPage(
      search: search,
      threads: _visibleThreads(),
      connected: connected,
      onRefresh: _reloadThreads,
      onSearchChanged: (_) => setState(() {}),
      itemBuilder: _threadEntry,
      emptyState: _emptyState,
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
    threadCache.write(serverId, threads, historyCache);
  }

  Future<void> _restoreThreadCache(String serverId) async {
    final snapshot = await threadCache.read(serverId);
    if (!mounted || activeConnectionId != serverId) return;
    setState(() {
      threads = snapshot.threads
          .map((thread) => mutableRemoteValue(thread) as Map<String, dynamic>)
          .toList();
      historyCache = {
        for (final entry in snapshot.history.entries)
          entry.key: entry.value
              .map((item) => mutableRemoteValue(item) as Map<String, dynamic>)
              .toList(),
      };
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
