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
      _settingsSection('Connection', [
        TextField(
          controller: endpoint,
          decoration: const InputDecoration(
            labelText: 'Desktop endpoint',
            hintText: 'https://...trycloudflare.com',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: accessToken,
          decoration: const InputDecoration(labelText: 'Device token'),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : connect,
                icon: const Icon(Icons.login),
                label: const Text('Connect'),
              ),
            ),
            const SizedBox(width: 10),
            IconButton(
              onPressed: busy ? null : _clearToken,
              tooltip: 'Clear token',
              icon: const Icon(Icons.link_off),
            ),
          ],
        ),
      ]),
      _settingsSection('Pair new device', [
        TextField(
          controller: pairingToken,
          decoration: const InputDecoration(labelText: 'One-time pairing code'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: deviceName,
          decoration: const InputDecoration(labelText: 'Device name'),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: busy ? null : pair,
            icon: const Icon(Icons.add_link),
            label: const Text('Pair'),
          ),
        ),
      ]),
      if (approvals.isNotEmpty)
        _settingsSection(
          'Approvals',
          approvals.map((event) => _approvalCard(event)).toList(),
        ),
      Text(message, style: Theme.of(context).textTheme.bodySmall),
    ],
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

  Widget _approvalCard(Map<String, dynamic> event) {
    final params = event['params'] is Map
        ? Map<String, dynamic>.from(event['params'] as Map)
        : <String, dynamic>{};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${event['method']} #${event['id']}'),
            Text(
              params['command']?.toString() ??
                  params['reason']?.toString() ??
                  'Codex requests approval',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                TextButton(
                  onPressed: busy ? null : () => answer(event, 'decline'),
                  child: const Text('Decline'),
                ),
                TextButton(
                  onPressed: busy ? null : () => answer(event, 'accept'),
                  child: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
