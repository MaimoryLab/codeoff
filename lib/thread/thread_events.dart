// ignore_for_file: invalid_use_of_protected_member

part of '../home/remote_home_page.dart';

List<Map<String, dynamic>> recordRemoteOperation(
  List<Map<String, dynamic>> items,
  Map<String, dynamic> operation,
) {
  final local = {...operation, 'local': true};
  final index = items.indexWhere((item) => item['id'] == operation['id']);
  if (index < 0) return [...items, local];
  return [...items]..[index] = local;
}

extension _RemoteEvents on _RemoteHomePageState {
  void _notifyForMessage(String threadId) {
    if (!shouldNotifyThreadMessage(threadId, selectedThread)) return;
    if (!notifiedThreads.add(threadId)) return;
    final title = threads
        .where((thread) => _threadId(thread) == threadId)
        .map(_threadTitle)
        .firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => context.t('thread'),
        );
    unawaited(
      LocalNotifications.instance.showThreadMessage(
        title,
        context.t('newMessage'),
        threadId,
      ),
    );
  }

  void _handleRemoteEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final id = event['id'];
    final method = '${event['method'] ?? ''}';
    final params = event['params'] is Map
        ? mutableRemoteValue(event['params']) as Map<String, dynamic>
        : <String, dynamic>{};
    final threadId = '${params['threadId'] ?? ''}';
    if (method == 'thread/released' &&
        threadId == selectedThread &&
        threadConflict &&
        !threadOwned &&
        !threadClaiming) {
      _stopHistoryRefresh();
      setState(() {
        threadConflict = true;
        threadServerReleased = true;
        message = context.t('threadReleasedByServer');
      });
    }
    if (id is int && method.contains('Approval')) {
      final operation = threadId == selectedThread
          ? approvalOperationFrom(event)
          : null;
      setState(() {
        approvals = [...approvals.where((item) => item['id'] != id), event];
        if (operation != null &&
            !history.any((item) => item['id'] == operation['id'])) {
          history = [...history, operation];
        }
        message = context.t('approvalRequested');
      });
      if (operation != null) _cacheCurrentHistory();
    }
    final status = params['status'];
    if (method == 'thread/status/changed' && status is Map) {
      setState(() {
        threads = updateRemoteThread(threads, threadId, {
          'status': Map<String, dynamic>.from(status),
        });
        threads.sort(compareRemoteThreads);
      });
      _queueThreadCacheWrite();
      unawaited(_reloadThreads());
    }
    if (method == 'thread/name/updated') {
      final name = '${params['threadName'] ?? params['name'] ?? ''}'.trim();
      if (name.isNotEmpty) {
        setState(
          () => threads = updateRemoteThread(threads, threadId, {'name': name}),
        );
        _queueThreadCacheWrite();
        unawaited(_reloadThreads());
      }
    }
    if (method == 'thread/archived') {
      setState(() {
        threads.removeWhere((thread) => _threadId(thread) == threadId);
        historyCache.remove(threadId);
      });
      _queueThreadCacheWrite();
      if (selectedThread == threadId) _showThreads();
      unawaited(_reloadThreads());
    }
    if (method == 'item/agentMessage/delta' && threadId == selectedThread) {
      _appendAssistantDelta(params);
    }
    if (method == 'item/agentMessage/delta' && threadId != selectedThread) {
      _notifyForMessage(threadId);
    }
    if (method == 'turn/started' && threadId == selectedThread) {
      setState(() {
        activeTurnId = activeTurnIdFrom(params);
        processingSummary = context.t('working');
        processingItemId = '';
        processingItems = [];
      });
    }
    if (method == 'item/started' && threadId == selectedThread) {
      final item = params['item'];
      final summary = processingSummaryFromItem(
        item,
        AppLocalizations.of(context),
      );
      if (item is Map && summary.isNotEmpty) {
        final operation = mutableRemoteValue(item) as Map<String, dynamic>;
        _updateFollowingExpandedOperationGroup(() {
          processingSummary = summary;
          processingItemId = '${item['id'] ?? ''}';
          processingItems = [
            ...processingItems.where((entry) => entry['id'] != item['id']),
            operation,
          ];
          history = recordRemoteOperation(history, operation);
        });
        _cacheCurrentHistory();
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
              : context.t('thinking', {'text': delta});
          processingItemId = itemId;
        });
      }
    }
    if (method == 'item/completed' && threadId == selectedThread) {
      final item = params['item'];
      if (item is Map && isRemoteOperationItem(item)) {
        final operation = mutableRemoteValue(item) as Map<String, dynamic>;
        _updateFollowingExpandedOperationGroup(() {
          processingItems = [
            ...processingItems.where((entry) => entry['id'] != item['id']),
            operation,
          ];
          history = recordRemoteOperation(history, operation);
        });
        _cacheCurrentHistory();
      }
      final itemId = '${item is Map ? item['id'] ?? '' : ''}';
      if (itemId == processingItemId) {
        setState(() => processingSummary = context.t('working'));
      }
    }
    if (method == 'turn/completed' && threadId == selectedThread) {
      setState(() {
        activeTurnId = '';
        processingSummary = '';
        processingItemId = '';
        processingItems = [];
      });
      _loadHistory(selectedThread, force: true);
      unawaited(_reloadThreads());
    }
  }
}
