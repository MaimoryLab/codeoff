// ignore_for_file: invalid_use_of_protected_member

part of '../home/remote_home_page.dart';

extension _ThreadController on _RemoteHomePageState {
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
          limit: _RemoteHomePageState.threadPageSize,
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
}
