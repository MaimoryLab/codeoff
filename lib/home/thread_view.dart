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
                  child: _emptyState('No projects yet', Icons.folder_outlined),
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
    tooltip: 'Thread actions',
    onSelected: (action) => _threadAction(thread, action),
    itemBuilder: (context) => const [
      PopupMenuItem(value: 'rename', child: Text('Rename')),
      PopupMenuItem(value: 'archive', child: Text('Archive')),
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
        title: const Text('Rename thread'),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || renamed == null || renamed.isEmpty) return;
    final id = _threadId(thread);
    await _run('Renaming...', () async {
      await api!.renameThread(id, renamed);
      _setThreadName(thread, renamed);
    });
  }

  Future<void> _archiveThread(Map<String, dynamic> thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive thread?'),
        content: Text('"${_threadTitle(thread)}" will be removed from Recent.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final id = _threadId(thread);
    await _run('Archiving...', () async {
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
        const Text('Working'),
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
      Expanded(
        child: loadingHistory && history.isEmpty && processingSummary.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : history.isEmpty && processingSummary.isEmpty
            ? _emptyState(
                'No messages in this thread',
                Icons.chat_bubble_outline,
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                reverse: true,
                itemCount:
                    history.length + (processingSummary.isNotEmpty ? 1 : 0),
                itemBuilder: (context, index) {
                  if (processingSummary.isNotEmpty && index == 0) {
                    return _processingSummary();
                  }
                  final offset = processingSummary.isNotEmpty ? 1 : 0;
                  return _messageBubble(
                    history[history.length - 1 - index + offset],
                  );
                },
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: [
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
                  PopupMenuButton<FileType>(
                    enabled: !busy && _canEditThread,
                    tooltip: 'Attach file or image',
                    icon: const Icon(Icons.attach_file),
                    onSelected: pickAttachments,
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: FileType.image,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.image_outlined),
                          title: Text('Choose images'),
                        ),
                      ),
                      PopupMenuItem(
                        value: FileType.any,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.insert_drive_file_outlined),
                          title: Text('Choose files'),
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
                            ? 'Checking access...'
                            : _canEditThread
                            ? 'Message'
                            : 'Active in another app',
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
                    tooltip: 'Send',
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
