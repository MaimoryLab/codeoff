part of 'remote_home_page.dart';

extension _HomeScaffold on _RemoteHomePageState {
  Widget _homeScaffold(BuildContext context) {
    final detail = selectedThread != null;
    final pendingConnection =
        connectionStatus == RemoteConnectionStatus.connecting ||
        connectionStatus == RemoteConnectionStatus.reconnecting;
    final content = settingsOpen
        ? _settingsView()
        : detail
        ? _threadView()
        : projectsView
        ? _projectsView()
        : _threadsView();
    return Scaffold(
      drawer: _drawer(context),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: detail ? 'Back' : 'Menu',
            icon: Icon(detail ? Icons.arrow_back : Icons.menu),
            onPressed: detail
                ? _showThreads
                : () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: settingsOpen
            ? const Text('Settings')
            : detail
            ? _threadAppBarTitle(selectedThread!)
            : Text(
                projectsView
                    ? 'Projects'
                    : selectedProject == null
                    ? 'Recent'
                    : _projectLabel(selectedProject!),
              ),
        actions: [
          Icon(
            connected
                ? Icons.cloud_done
                : pendingConnection
                ? Icons.cloud_sync
                : Icons.cloud_off,
            color: connected
                ? Colors.greenAccent
                : pendingConnection
                ? Colors.amberAccent
                : Colors.white38,
            size: 20,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          if (!connected) _connectionBanner(),
          Expanded(child: content),
        ],
      ),
      floatingActionButton: !settingsOpen && !detail && connected
          ? FloatingActionButton(
              onPressed: busy ? null : createThread,
              tooltip: 'New thread',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _connectionBanner() {
    final connecting = connectionStatus == RemoteConnectionStatus.connecting;
    final pending =
        connectionStatus == RemoteConnectionStatus.reconnecting || connecting;
    final canReconnect =
        !busy && endpoint.text.trim().isNotEmpty && accessToken.text.isNotEmpty;
    return Material(
      color: pending
          ? const Color(0xff6b4f00)
          : Theme.of(context).colorScheme.errorContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(pending ? Icons.cloud_sync : Icons.cloud_off),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  connecting
                      ? 'Connecting...'
                      : pending
                      ? 'Reconnecting...'
                      : 'Offline',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (!pending)
                FilledButton.icon(
                  onPressed: canReconnect ? reconnect : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _drawer(BuildContext context) => Drawer(
    backgroundColor: const Color(0xff222326),
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Color(0xffd78360),
                  child: Icon(Icons.auto_awesome, color: Colors.white),
                ),
                SizedBox(width: 12),
                Text(
                  'Codex Remote',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          _drawerItem(Icons.add, 'New', false, () {
            Navigator.pop(context);
            if (!busy) createThread();
          }),
          const Divider(height: 24),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reloadThreads,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _drawerLabel('Recent'),
                  for (final thread in threads.take(5))
                    _recentEntry(context, thread),
                  if (threads.length > 5)
                    _moreEntry('More recent chats', _showRecent),
                  if (threads.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text(
                        'No recent chats',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  const Divider(height: 24),
                  _drawerLabel('Projects'),
                  for (final project in _projects().take(5))
                    _projectEntry(context, project),
                  if (_projects().length > 5)
                    _moreEntry('More projects', _showProjects),
                  if (_projects().isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text(
                        'No projects',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          _drawerItem(
            Icons.settings_outlined,
            'Settings',
            settingsOpen,
            _openSettings,
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );

  Widget _drawerLabel(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white60,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _recentEntry(BuildContext context, Map<String, dynamic> thread) =>
      ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(
          _threadTitle(thread),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: _threadMeta(thread),
        trailing: _threadMenu(thread),
        onTap: () {
          Navigator.pop(context);
          _openThread(_threadId(thread));
        },
      );

  Widget _projectEntry(BuildContext context, String project) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: const Icon(Icons.folder_outlined, size: 20),
    title: Text(_projectLabel(project), overflow: TextOverflow.ellipsis),
    selected: selectedProject == project && selectedThread == null,
    onTap: () => _selectProject(project),
  );

  Widget _moreEntry(String label, VoidCallback onTap) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: const Icon(Icons.more_horiz),
    title: Text(label),
    trailing: const Icon(Icons.chevron_right, size: 18),
    onTap: onTap,
  );

  Widget _drawerItem(
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    selected: selected,
    selectedTileColor: const Color(0xff34363a),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    onTap: onTap,
  );
}
