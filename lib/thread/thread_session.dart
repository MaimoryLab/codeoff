// ignore_for_file: invalid_use_of_protected_member

part of '../home/remote_home_page.dart';

extension _ThreadSession on _RemoteHomePageState {
  Future<void> _loadHistory(String? id, {bool force = false}) async {
    final client = api;
    if (id == null || client == null || (!force && loadedHistoryFor == id)) {
      return;
    }
    final revision = ++historyLoadRevision;
    setState(() {
      loadingHistory = true;
      if (!force) history = [];
    });
    try {
      final value = await client.thread(id);
      if (!mounted ||
          selectedThread != id ||
          !identical(api, client) ||
          revision != historyLoadRevision) {
        return;
      }
      final snapshotSummary = processingSummaryFromThread(
        value,
        AppLocalizations.of(context),
      );
      setState(() {
        final loaded = _historyItems(value);
        final local = history.where((item) => item['local'] == true);
        history = [
          ...loaded,
          for (final item in local)
            if (!loaded.any(
              (remote) =>
                  _messageRole(remote) == 'user' &&
                  _messageText(remote) == _messageText(item),
            ))
              item,
        ];
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
      if (mounted && revision == historyLoadRevision) {
        setState(() => loadingHistory = false);
      }
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
      processingItems = [];
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
    notifiedThreads.remove(id);
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
}
