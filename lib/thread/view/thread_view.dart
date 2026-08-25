part of '../../home/remote_home_page.dart';

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
              if (uploadingAttachments && attachments.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.t('uploadingAttachment', {
                          'current': '$uploadingAttachmentIndex',
                          'total': '${attachments.length}',
                          'name':
                              attachments[uploadingAttachmentIndex - 1].name,
                        }),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${(attachmentProgress * 100).round()}%'),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: attachmentProgress),
              ],
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
}
