import 'dart:io';

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../storage/connection_store.dart';

class ConnectionSettingsPage extends StatelessWidget {
  const ConnectionSettingsPage({
    required this.endpoint,
    required this.busy,
    required this.connections,
    required this.version,
    required this.onConnect,
    required this.onScan,
    required this.onConnectSaved,
    required this.onEdit,
    required this.onDelete,
    required this.onCheckForUpdates,
    super.key,
  });

  final TextEditingController endpoint;
  final bool busy;
  final List<Map<String, String>> connections;
  final String version;
  final VoidCallback onConnect;
  final VoidCallback onScan;
  final Future<void> Function(Map<String, String>) onConnectSaved;
  final Future<void> Function(Map<String, String>) onEdit;
  final Future<void> Function(Map<String, String>) onDelete;
  final Future<void> Function() onCheckForUpdates;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 22),
        child: Text(
          'Codeoff',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
      ),
      _section(context.t('connectToDesktop'), [
        TextField(
          controller: endpoint,
          decoration: InputDecoration(
            labelText: context.t('desktopEndpoint'),
            hintText: 'https://...trycloudflare.com',
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onConnect,
                icon: const Icon(Icons.login),
                label: Text(context.t('connect')),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: context.t('scanPairingCode'),
              onPressed: busy ? null : onScan,
              icon: const Icon(Icons.qr_code_scanner),
            ),
          ],
        ),
      ]),
      _section(context.t('connectionHistory'), [
        if (connections.isEmpty)
          Text(
            context.t('noSavedConnections'),
            style: const TextStyle(color: Colors.white54),
          )
        else
          for (final record in connections) _entry(context, record),
      ]),
      if (Platform.isAndroid || Platform.isIOS)
        _section(context.t('about'), [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Codeoff'),
            subtitle: Text(context.t('version', {'version': version})),
            trailing: Platform.isAndroid
                ? FilledButton.icon(
                    onPressed: busy ? null : onCheckForUpdates,
                    icon: const Icon(Icons.system_update_alt),
                    label: Text(context.t('checkForUpdates')),
                  )
                : null,
          ),
        ]),
    ],
  );

  Widget _entry(BuildContext context, Map<String, String> record) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(record['name'] ?? record['endpoint'] ?? ''),
    subtitle: Text(
      connectionEndpoints(record).join(', '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: context.t('connect'),
          onPressed: busy ? null : () => onConnectSaved(record),
          icon: const Icon(Icons.login),
        ),
        IconButton(
          tooltip: context.t('edit'),
          onPressed: busy ? null : () => onEdit(record),
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: context.t('delete'),
          onPressed: busy ? null : () => onDelete(record),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
  );

  Widget _section(String title, List<Widget> children) => Padding(
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
