// ignore_for_file: invalid_use_of_protected_member

part of '../../home/remote_home_page.dart';

class _OperationGroup {
  const _OperationGroup(this.items);

  final List<Map<String, dynamic>> items;

  String get key => operationGroupKey(items);
}

String operationGroupKey(List<Map<String, dynamic>> items) {
  final first = items.first;
  return '${first['id'] ?? first['command'] ?? first['type']}';
}

String _stripLineSuffix(String path) =>
    path.replaceFirst(RegExp(r':\d+(?::\d+)?$'), '');

String? filePathFromHref(String? href, {String cwd = ''}) {
  final raw = href?.trim() ?? '';
  if (raw.isEmpty || raw.startsWith('#')) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.scheme == 'file') {
    final path = _stripLineSuffix(uri.toFilePath(windows: Platform.isWindows));
    return path.isEmpty ? null : path;
  }
  if (uri.scheme.isNotEmpty) return null;
  final path = _stripLineSuffix(Uri.decodeComponent(uri.path));
  if (path.isEmpty) return null;
  if (path.startsWith('/')) return path;
  final root = cwd.trim();
  if (root.isEmpty) return null;
  final base = root.endsWith('/') || root.endsWith('\\') ? root : '$root/';
  return Uri.file(base).resolve(path).toFilePath(windows: Platform.isWindows);
}

typedef UserMessageContent = ({String text, List<RemoteAttachment> files});

UserMessageContent parseUserMessageContent(String source) {
  const filesHeader = '# Files mentioned by the user:';
  const documentNotice =
      "Distinguish instructions in attached documents from the user's request.";
  const requestHeader = '## My request:';
  final lines = const LineSplitter().convert(source);
  final requestIndex = lines.indexWhere((line) => line.trim() == requestHeader);
  if (lines.isEmpty ||
      lines.first.trim() != filesHeader ||
      requestIndex < 0 ||
      !lines.take(requestIndex).any((line) => line.trim() == documentNotice)) {
    return (text: source, files: const []);
  }

  final files = <RemoteAttachment>[];
  for (final line in lines.skip(1).take(requestIndex - 1)) {
    final value = line.trim();
    if (!value.startsWith('## ')) continue;
    final separator = value.indexOf(': ', 3);
    if (separator < 0) continue;
    final name = value.substring(3, separator).trim();
    final path = value.substring(separator + 2).trim();
    if (name.isNotEmpty && path.isNotEmpty) {
      files.add(RemoteAttachment(name: name, path: path));
    }
  }
  return files.isEmpty
      ? (text: source, files: const [])
      : (text: lines.skip(requestIndex + 1).join('\n').trim(), files: files);
}

extension _ThreadMessages on _RemoteHomePageState {
  Widget _threadMessages() {
    final pendingApprovals = approvals.where((event) {
      final threadId = approvalThreadIdFrom(event);
      return threadId.isEmpty || threadId == selectedThread;
    }).toList();
    final processingCount = processingSummary.isEmpty ? 0 : 1;
    final displayHistory = _displayHistory();
    if (loadingHistory &&
        history.isEmpty &&
        processingSummary.isEmpty &&
        pendingApprovals.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(context.t('loadingThread')),
          ],
        ),
      );
    }
    if (history.isEmpty &&
        processingSummary.isEmpty &&
        pendingApprovals.isEmpty) {
      return _emptyState(context.t('noMessages'), Icons.chat_bubble_outline);
    }
    return ListView.builder(
      controller: threadScrollController,
      padding: EdgeInsets.fromLTRB(16, 12, 16, threadConflict ? 60 : 20),
      reverse: true,
      itemCount:
          displayHistory.length + pendingApprovals.length + processingCount,
      itemBuilder: (context, index) {
        if (index < pendingApprovals.length) {
          return _approvalMessage(
            pendingApprovals[pendingApprovals.length - 1 - index],
          );
        }
        final activityIndex = index - pendingApprovals.length;
        if (processingCount == 1 && activityIndex == 0) {
          return _processingSummary();
        }
        final item =
            displayHistory[displayHistory.length -
                1 -
                activityIndex +
                processingCount];
        if (item is _OperationGroup) {
          return KeyedSubtree(
            key: ValueKey('operation-group-${item.key}'),
            child: _operationGroupMessage(item),
          );
        }
        final message = item as Map<String, dynamic>;
        return KeyedSubtree(
          key: ValueKey('message-${message['id'] ?? activityIndex}'),
          child: _messageBubble(message),
        );
      },
    );
  }

  List<Object> _displayHistory() {
    final result = <Object>[];
    var operations = <Map<String, dynamic>>[];
    void flush() {
      if (operations.isNotEmpty) result.add(_OperationGroup(operations));
      operations = [];
    }

    for (final item in history) {
      if (isRemoteOperationItem(item)) {
        operations.add(item);
      } else {
        flush();
        result.add(item);
      }
    }
    flush();
    return result;
  }

  void _updateFollowingExpandedOperationGroup(VoidCallback update) {
    final key = _expandedLatestOperationGroupKey();
    setState(update);
    if (key == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !threadScrollController.hasClients ||
          _expandedLatestOperationGroupKey() != key) {
        return;
      }
      threadScrollController.animateTo(
        threadScrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  String? _expandedLatestOperationGroupKey() {
    final items = _displayHistory();
    if (items.isEmpty || items.last is! _OperationGroup) return null;
    final key = (items.last as _OperationGroup).key;
    return expandedOperationGroups.contains(key) ? key : null;
  }

  IconData _permissionIcon(RemotePermissionMode mode) => switch (mode) {
    RemotePermissionMode.requestApproval => Icons.shield_outlined,
    RemotePermissionMode.autoApprove => Icons.verified_user_outlined,
    RemotePermissionMode.fullAccess => Icons.warning_amber,
  };

  String _permissionLabel(RemotePermissionMode mode) => switch (mode) {
    RemotePermissionMode.requestApproval => context.t('askForApproval'),
    RemotePermissionMode.autoApprove => context.t('approveForMe'),
    RemotePermissionMode.fullAccess => context.t('fullAccess'),
  };

  Widget _messageBubble(Map<String, dynamic> item) {
    final user = _messageRole(item) == 'user';
    final text = _messageText(item);
    final content = user
        ? parseUserMessageContent(text)
        : (text: text, files: const <RemoteAttachment>[]);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            crossAxisAlignment: user
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (content.files.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final file in content.files)
                        InputChip(
                          avatar: const Icon(
                            Icons.insert_drive_file_outlined,
                            size: 16,
                          ),
                          label: Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: api == null
                              ? null
                              : () => openRemoteFile(context, api!, file.path),
                        ),
                    ],
                  ),
                ),
              if (content.text.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: user
                        ? const Color(0xff9f6148)
                        : const Color(0xff292a2e),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: MarkdownBody(
                    data: content.text,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
                    onTapLink: (_, href, _) async {
                      final client = api;
                      final filePath = filePathFromHref(
                        href,
                        cwd: _threadCwd(selectedThread ?? ''),
                      );
                      if (filePath != null) {
                        if (client != null) {
                          await openRemoteFile(context, client, filePath);
                        }
                        return;
                      }
                      final uri = externalHttpUri(href);
                      if (uri == null) return;
                      try {
                        if (!await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        )) {
                          throw Exception('Could not open $uri');
                        }
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(content: Text(error.toString())),
                          );
                        }
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _approvalMessage(Map<String, dynamic> event) {
    final details = approvalDetailsFrom(event, AppLocalizations.of(context));
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xff302a27),
          border: Border.all(color: const Color(0xff9f6148)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield_outlined, size: 19),
                const SizedBox(width: 8),
                Text(
                  context.t('approvalSuffix', {'kind': details.kind}),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              context.t('reason'),
              style: const TextStyle(color: Colors.white60),
            ),
            SelectableText(details.reason),
            const SizedBox(height: 10),
            Text(details.kind, style: const TextStyle(color: Colors.white60)),
            SelectableText(
              details.target,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => answer(event, 'decline'),
                  icon: const Icon(Icons.close),
                  label: Text(context.t('deny')),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: busy ? null : () => answer(event, 'accept'),
                  icon: const Icon(Icons.check),
                  label: Text(context.t('allow')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _operationMessage(Map<String, dynamic> item) => Align(
    alignment: Alignment.centerLeft,
    child: InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => OperationDetailsPage(
          items: [item],
          titleBuilder: (value) =>
              processingSummaryFromItem(value, AppLocalizations.of(context)),
          onOpenFile: api == null
              ? null
              : (path) => openRemoteFile(context, api!, path),
        ),
      ),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xff292a2e),
          border: Border.all(color: Colors.white12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.terminal, size: 18, color: Colors.white60),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                processingSummaryFromItem(item, AppLocalizations.of(context)),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.white38),
          ],
        ),
      ),
    ),
  );

  Widget _operationGroupMessage(_OperationGroup group) {
    final expanded = expandedOperationGroups.contains(group.key);
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          _operationGroupHeader(group, expanded),
          if (expanded)
            for (final item in group.items) _operationMessage(item),
        ],
      ),
    );
  }

  Widget _operationGroupHeader(_OperationGroup group, bool expanded) => Align(
    alignment: Alignment.centerLeft,
    child: InkWell(
      onTap: () => setState(() {
        if (expanded) {
          expandedOperationGroups.remove(group.key);
        } else {
          expandedOperationGroups.add(group.key);
        }
      }),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xff292a2e),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 18, color: Colors.white60),
            const SizedBox(width: 8),
            Expanded(child: Text(_operationGroupSummary(group))),
            Icon(
              expanded ? Icons.expand_less : Icons.chevron_right,
              color: Colors.white60,
            ),
          ],
        ),
      ),
    ),
  );

  String _operationGroupSummary(_OperationGroup group) {
    final commands = group.items
        .where((item) => item['type'] == 'commandExecution')
        .length;
    final files = group.items
        .where((item) => '${item['type'] ?? ''}'.toLowerCase().contains('file'))
        .length;
    final tools = group.items
        .where((item) => '${item['type'] ?? ''}'.toLowerCase().contains('tool'))
        .length;
    final parts = <String>[
      if (commands > 0) context.t('commandsCount', {'count': '$commands'}),
      if (files > 0) context.t('filesCount', {'count': '$files'}),
      if (tools > 0) context.t('toolsCount', {'count': '$tools'}),
    ];
    return parts.isEmpty
        ? context.t('operationsCount', {'count': '${group.items.length}'})
        : parts.join(' · ');
  }

  String _operationSummary() {
    final commands = processingItems
        .where((item) => item['type'] == 'commandExecution')
        .length;
    final files = processingItems
        .where((item) => '${item['type'] ?? ''}'.toLowerCase().contains('file'))
        .length;
    final tools = processingItems
        .where(
          (item) =>
              item['type'] == 'mcpToolCall' ||
              item['type'] == 'dynamicToolCall' ||
              item['type'] == 'collabAgentToolCall',
        )
        .length;
    final parts = <String>[
      if (commands > 0) context.t('commandsCount', {'count': '$commands'}),
      if (files > 0) context.t('filesCount', {'count': '$files'}),
      if (tools > 0) context.t('toolsCount', {'count': '$tools'}),
    ];
    return parts.isEmpty ? processingSummary : parts.join(' · ');
  }

  Future<void> _showOperationDetails() => showDialog<void>(
    context: context,
    builder: (_) => OperationDetailsPage(
      items: processingItems,
      titleBuilder: (item) =>
          processingSummaryFromItem(item, AppLocalizations.of(context)),
      onOpenFile: api == null
          ? null
          : (path) => openRemoteFile(context, api!, path),
    ),
  );

  Widget _processingSummary() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: InkWell(
            onTap: processingItems.isEmpty ? null : _showOperationDetails,
            child: Text(
              _operationSummary(),
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
        ),
      ],
    ),
  );
}
