part of 'remote_home_page.dart';

Uri? externalHttpUri(String? href) {
  final uri = Uri.tryParse(href ?? '');
  return uri != null &&
          uri.hasAuthority &&
          (uri.scheme == 'http' || uri.scheme == 'https')
      ? uri
      : null;
}

extension _ThreadView on _RemoteHomePageState {
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
                  child: _emptyState(
                    context.t('noProjectsYet'),
                    Icons.folder_outlined,
                  ),
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
    trailing: _threadMenu(thread),
    onTap: () => _openThread(_threadId(thread)),
  );

  Widget _threadMenu(Map<String, dynamic> thread) => PopupMenuButton<String>(
    tooltip: context.t('threadActions'),
    onSelected: (action) => _threadAction(thread, action),
    itemBuilder: (context) => [
      PopupMenuItem(value: 'rename', child: Text(context.t('rename'))),
      PopupMenuItem(value: 'archive', child: Text(context.t('archive'))),
    ],
  );

  Future<void> _threadAction(Map<String, dynamic> thread, String action) {
    switch (action) {
      case 'rename':
        return _renameThread(thread);
      case 'archive':
        return _archiveThread(thread);
      default:
        return Future.value();
    }
  }

  Future<void> _renameThread(Map<String, dynamic> thread) async {
    final initialName = _threadTitle(thread);
    var name = initialName;
    final renamed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t('renameThread')),
        content: TextFormField(
          initialValue: initialName,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: Text(context.t('save')),
          ),
        ],
      ),
    );
    if (!mounted || renamed == null || renamed.isEmpty) return;
    final id = _threadId(thread);
    await _run(context.t('renaming'), () async {
      await api!.renameThread(id, renamed);
      _setThreadName(thread, renamed);
    });
  }

  Future<void> _archiveThread(Map<String, dynamic> thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t('archiveThreadQuestion')),
        content: Text(
          context.t('archiveThreadContent', {'name': _threadTitle(thread)}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.t('archive')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final id = _threadId(thread);
    await _run(context.t('archiving'), () async {
      await api!.archiveThread(id);
      if (selectedThread == id) _showThreads();
      await _reloadThreads();
    });
  }

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
      if (remoteThreadIsActive(thread)) ...[
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 6),
        Text(context.t('working')),
        const SizedBox(width: 10),
      ],
      Expanded(child: Text(_timeLabel(remoteThreadDate(thread)))),
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

  bool get _canEditThread => threadOwned && !threadClaiming;

  Widget _threadView() => Column(
    children: [
      Expanded(child: _threadMessages()),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: [
              if (threadConflict)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FilledButton.tonalIcon(
                      onPressed: busy ? null : _takeOverThread,
                      icon: const Icon(Icons.lock_open),
                      label: Text(context.t('takeOver')),
                    ),
                  ),
                ),
              if (attachments.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final attachment in attachments)
                        InputChip(
                          avatar: Icon(
                            attachment.name.toLowerCase().endsWith('.png') ||
                                    attachment.name.toLowerCase().endsWith(
                                      '.jpg',
                                    ) ||
                                    attachment.name.toLowerCase().endsWith(
                                      '.jpeg',
                                    )
                                ? Icons.image_outlined
                                : Icons.insert_drive_file_outlined,
                            size: 16,
                          ),
                          label: Text(
                            attachment.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onDeleted: busy || !_canEditThread
                              ? null
                              : () => removeAttachment(attachment),
                        ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  PopupMenuButton<RemotePermissionMode>(
                    enabled: !busy && _canEditThread,
                    tooltip: _permissionLabel(permissionMode),
                    icon: Icon(_permissionIcon(permissionMode)),
                    onSelected: setPermissionMode,
                    itemBuilder: (context) => [
                      for (final mode in RemotePermissionMode.values)
                        PopupMenuItem(
                          value: mode,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(_permissionIcon(mode)),
                            title: Text(_permissionLabel(mode)),
                            trailing: mode == permissionMode
                                ? const Icon(Icons.check)
                                : null,
                          ),
                        ),
                    ],
                  ),
                  PopupMenuButton<FileType>(
                    enabled: !busy && _canEditThread,
                    tooltip: context.t('attachFileOrImage'),
                    icon: const Icon(Icons.attach_file),
                    onSelected: pickAttachments,
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: FileType.image,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.image_outlined),
                          title: Text(context.t('chooseImages')),
                        ),
                      ),
                      PopupMenuItem(
                        value: FileType.any,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.insert_drive_file_outlined),
                          title: Text(context.t('chooseFiles')),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: TextField(
                      controller: input,
                      readOnly: !_canEditThread,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: threadClaiming
                            ? context.t('checkingAccess')
                            : _canEditThread
                            ? context.t('message')
                            : threadConflict
                            ? context.t('activeInAnotherApp')
                            : context.t('unableToSend'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: busy || !_canEditThread ? null : sendTurn,
                    tooltip: context.t('send'),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _threadMessages() {
    final pendingApprovals = approvals.where((event) {
      final threadId = approvalThreadIdFrom(event);
      return threadId.isEmpty || threadId == selectedThread;
    }).toList();
    final processingCount = processingSummary.isEmpty ? 0 : 1;
    if (loadingHistory &&
        history.isEmpty &&
        processingSummary.isEmpty &&
        pendingApprovals.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (history.isEmpty &&
        processingSummary.isEmpty &&
        pendingApprovals.isEmpty) {
      return _emptyState(context.t('noMessages'), Icons.chat_bubble_outline);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      reverse: true,
      itemCount: history.length + pendingApprovals.length + processingCount,
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
        return _messageBubble(
          history[history.length - 1 - activityIndex + processingCount],
        );
      },
    );
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
          onTapLink: (_, href, _) async {
            final uri = externalHttpUri(href);
            if (uri == null) return;
            try {
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                throw Exception('Could not open $uri');
              }
            } catch (error) {
              if (mounted) {
                ScaffoldMessenger.maybeOf(context)
                    ?.showSnackBar(SnackBar(content: Text(error.toString())));
              }
            }
          },
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
          child: Text(
            processingSummary,
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
