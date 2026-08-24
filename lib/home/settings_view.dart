part of 'remote_home_page.dart';

extension _SettingsView on _RemoteHomePageState {
  Widget _settingsView() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 22),
        child: Text(
          'Codex Remote',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
      ),
      _settingsSection('Connect to a desktop', [
        TextField(
          controller: endpoint,
          decoration: const InputDecoration(
            labelText: 'Desktop endpoint',
            hintText: 'https://...trycloudflare.com',
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: busy ? null : connect,
            icon: const Icon(Icons.login),
            label: const Text('Connect'),
          ),
        ),
      ]),
      _settingsSection('Connection history', [
        if (connections.isEmpty)
          const Text(
            'No saved connections',
            style: TextStyle(color: Colors.white54),
          )
        else
          for (final record in connections) _connectionEntry(record),
      ]),
    ],
  );

  Widget _connectionEntry(Map<String, String> record) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(record['name'] ?? record['endpoint'] ?? ''),
    subtitle: Text(
      record['endpoint'] ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Connect',
          onPressed: busy ? null : () => _connectSaved(record),
          icon: const Icon(Icons.login),
        ),
        IconButton(
          tooltip: 'Edit',
          onPressed: busy ? null : () => _editConnection(record),
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: 'Delete',
          onPressed: busy ? null : () => _deleteConnection(record),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
  );

  Widget _settingsSection(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white60,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );
}
