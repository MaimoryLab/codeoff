part of 'remote_home_page.dart';

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
    onTap: () => _openThread(_threadId(thread)),
  );

  Widget _threadAppBarTitle(String id) {
    final cwd = _threadCwd(id);
    final active = threads.any(
      (thread) => _threadId(thread) == id && remoteThreadIsActive(thread),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                _threadTitle(id),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 8),
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 5),
              const Text('Working', style: TextStyle(fontSize: 12)),
            ],
          ],
        ),
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

  Widget _threadView() => Column(
    children: [
      Expanded(
        child: loadingHistory && history.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : history.isEmpty
            ? _emptyState(
                'No messages in this thread',
                Icons.chat_bubble_outline,
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                reverse: true,
                itemCount: history.length,
                itemBuilder: (context, index) =>
                    _messageBubble(history[history.length - 1 - index]),
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: busy ? null : sendTurn,
                tooltip: 'Send',
                icon: const Icon(Icons.send),
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
        ),
      ),
    );
  }
}
