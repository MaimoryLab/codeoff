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
      _settingsSection(context.t('connectToDesktop'), [
        TextField(
          controller: endpoint,
          decoration: InputDecoration(
            labelText: context.t('desktopEndpoint'),
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
            label: Text(context.t('connect')),
          ),
        ),
      ]),
      _settingsSection(context.t('connectionHistory'), [
        if (connections.isEmpty)
          Text(
            context.t('noSavedConnections'),
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
          tooltip: context.t('connect'),
          onPressed: busy ? null : () => _connectSaved(record),
          icon: const Icon(Icons.login),
        ),
        IconButton(
          tooltip: context.t('edit'),
          onPressed: busy ? null : () => _editConnection(record),
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: context.t('delete'),
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
