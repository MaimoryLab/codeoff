// ignore_for_file: invalid_use_of_protected_member

part of '../home/remote_home_page.dart';

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
    if (id is int && method.contains('Approval')) {
      setState(() {
        approvals = [...approvals.where((item) => item['id'] != id), event];
        message = context.t('approvalRequested');
      });
    }
    final params = event['params'] is Map
        ? Map<String, dynamic>.from(event['params'] as Map)
        : <String, dynamic>{};
    final threadId = '${params['threadId'] ?? ''}';
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
      });
    }
    if (method == 'item/started' && threadId == selectedThread) {
      final item = params['item'];
      final summary = processingSummaryFromItem(
        item,
        AppLocalizations.of(context),
      );
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
              : context.t('thinking', {'text': delta});
          processingItemId = itemId;
        });
      }
    }
    if (method == 'item/completed' && threadId == selectedThread) {
      final itemId =
          '${params['item'] is Map ? params['item']['id'] ?? '' : ''}';
      if (itemId == processingItemId) {
        setState(() => processingSummary = context.t('working'));
      }
    }
    if (method == 'turn/completed' && threadId == selectedThread) {
      setState(() {
        activeTurnId = '';
        processingSummary = '';
        processingItemId = '';
      });
      _loadHistory(selectedThread, force: true);
      unawaited(_reloadThreads());
    }
  }
}
