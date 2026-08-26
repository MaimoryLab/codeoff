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

part 'home_scaffold.dart';
part '../connection/connection_controller.dart';
part '../connection/connection_settings_view.dart';
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
  bool projectsView = false;
  String message = 'Enter the desktop endpoint to begin.';
  bool busy = false;
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
    for (final controller in [endpoint, accessToken, input, search]) {
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
        } else if (!disconnected) {
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
    threadCache.write(serverId, threads, historyCache);
  }

  Future<void> _restoreThreadCache(String serverId) async {
    final snapshot = await threadCache.read(serverId);
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
