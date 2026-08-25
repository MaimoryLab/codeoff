// ignore_for_file: invalid_use_of_protected_member

part of 'remote_home_page.dart';

extension _ConnectionController on _RemoteHomePageState {
  Future<void> connect() async {
    await _run(context.t('connecting'), () async {
      final endpointValue = endpoint.text.trim();
      if (endpointValue.isEmpty) throw ApiException('Endpoint is required');
      var token = accessToken.text.trim();
      final saved = connections.where(
        (item) => item['endpoint'] == endpointValue,
      );
      if (saved.isNotEmpty) {
        token = saved.first['token']!;
      } else if (activeConnectionId == null ||
          connections.any(
            (item) =>
                item['serverId'] == activeConnectionId &&
                item['endpoint'] != endpointValue,
          )) {
        token = '';
      }
      Map<String, dynamic>? pairing;
      if (token.isEmpty) {
        pairing = await _pairDialog();
        if (pairing == null) return;
        final value = await RemoteApi(endpointValue)
            .pair('${pairing['token']}', '${pairing['name']}');
        token = _stringValue(value, 'token');
        pairing = _serverFrom(value);
      }
      await _disconnect();
      try {
        await _connectRecord(endpointValue, token, pairing: pairing);
      } catch (_) {
        await _disconnect();
        rethrow;
      }
    });
  }

  Future<void> _connectRecord(
    String endpointValue,
    String token, {
    Map<String, dynamic>? pairing,
  }) async {
    final status = await remoteConnection.connect(endpointValue, token);
    final server = _serverFrom(status);
    final serverId = '${server['id'] ?? pairing?['id'] ?? endpointValue}';
    final previous = connections.where((item) => item['serverId'] == serverId);
    final record = <String, String>{
      'serverId': serverId,
      'name': previous.isEmpty
          ? '${server['name'] ?? pairing?['name'] ?? endpointValue}'
          : previous.first['name']!,
      'endpoint': endpointValue,
      'token': token,
    };
    connections = rememberRemoteConnection(connections, record);
    activeConnectionId = record['serverId'];
    endpoint.text = endpointValue;
    accessToken.text = token;
    await _saveConnection();
    await _restoreThreadCache(serverId);
    await _reloadThreads();
    if (!mounted) return;
    setState(() {
      settingsOpen = false;
      message = context.t('connected');
    });
    _toast(context.t('connectedTo', {'name': record['name'] ?? ''}));
  }

  Future<Map<String, dynamic>?> _pairDialog() {
    final token = TextEditingController();
    final name = TextEditingController(text: _defaultDeviceName);
    final dialog = showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.t('pairThisDevice')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: token,
              autofocus: true,
              decoration: InputDecoration(labelText: context.t('pairingCode')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              decoration: InputDecoration(labelText: context.t('deviceName')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (token.text.trim().isEmpty || name.text.trim().isEmpty) return;
              Navigator.pop(dialogContext, {
                'token': token.text.trim(),
                'name': name.text.trim(),
              });
            },
            child: Text(context.t('pair')),
          ),
        ],
      ),
    );
    dialog.whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        token.dispose();
        name.dispose();
      });
    });
    return dialog;
  }

  String get _defaultDeviceName => Platform.localHostname.trim().isEmpty
      ? context.t('mobileDevice')
      : Platform.localHostname;

  Map<String, dynamic> _serverFrom(dynamic value) {
    if (value is! Map) return {};
    final server = value['server'];
    if (server is Map) return Map<String, dynamic>.from(server);
    return {};
  }

  void _handleConnectionStatus(RemoteConnectionStatus status) {
    if (!mounted) return;
    setState(() {
      switch (status) {
        case RemoteConnectionStatus.reconnecting:
          message = context.t('connectionLost');
        case RemoteConnectionStatus.online:
          message = context.t('connected');
        case RemoteConnectionStatus.offline:
          final error = remoteConnection.lastError;
          if (error != null) {
            message = context.t('disconnected', {'error': '$error'});
          }
        case RemoteConnectionStatus.connecting:
          break;
      }
    });
    if (status == RemoteConnectionStatus.online &&
        remoteConnection.previousStatus ==
            RemoteConnectionStatus.reconnecting) {
      unawaited(_reloadThreads());
    }
  }

  Future<void> _disconnect() async {
    _releaseSelectedThread();
    await remoteConnection.disconnect();
    activeConnectionId = null;
  }

  Future<void> reconnect() async {
    final endpointValue = endpoint.text.trim();
    final token = accessToken.text.trim();
    if (endpointValue.isEmpty || token.isEmpty) return;
    await remoteConnection.reconnect(endpoint: endpointValue, token: token);
  }

  Future<void> _connectSaved(Map<String, String> record) async {
    endpoint.text = record['endpoint'] ?? '';
    accessToken.text = record['token'] ?? '';
    await connect();
  }

  Future<void> _editConnection(Map<String, String> record) async {
    final name = TextEditingController(text: record['name']);
    final address = TextEditingController(text: record['endpoint']);
    final formKey = GlobalKey<FormState>();
    final changed = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.t('edit')),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(labelText: context.t('name')),
                validator: (value) => value?.trim().isEmpty == false
                    ? null
                    : context.t('nameRequired'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: address,
                decoration: InputDecoration(
                  labelText: context.t('serverAddress'),
                ),
                keyboardType: TextInputType.url,
                validator: (value) => normalizeServerEndpoint(value) == null
                    ? context.t('invalidServerAddress')
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(dialogContext, {
                'name': name.text.trim(),
                'endpoint': normalizeServerEndpoint(address.text)!,
              });
            },
            child: Text(context.t('save')),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      name.dispose();
      address.dispose();
    });
    if (!mounted || changed == null) return;
    final index = connections.indexOf(record);
    if (index == -1) return;
    final wasActive = record['serverId'] == activeConnectionId;
    final addressChanged = record['endpoint'] != changed['endpoint'];
    if (wasActive && addressChanged) await _disconnect();
    if (!mounted) return;
    final updated = {...record, ...changed};
    setState(() => connections = [...connections]..[index] = updated);
    if (wasActive) {
      endpoint.text = updated['endpoint'] ?? '';
      accessToken.text = updated['token'] ?? '';
    }
    await _saveConnection();
  }

  Future<void> _deleteConnection(Map<String, String> record) async {
    if (record['serverId'] == activeConnectionId) await _disconnect();
    if (!mounted) return;
    setState(() => connections = [...connections]..remove(record));
    if (connections.isEmpty) {
      endpoint.clear();
      accessToken.clear();
    }
    await _saveConnection();
    if (!mounted) return;
    _toast(context.t('connectionRemoved'));
  }

  Future<void> _restoreConnection() async {
    try {
      final savedConnections = await _RemoteHomePageState.connectionStore
          .loadConnections();
      final savedPermission = await _RemoteHomePageState.connectionStore
          .loadPermissionMode();
      if (!mounted) return;
      connections = savedConnections;
      setState(() {
        if (connections.isNotEmpty) {
          final recent = connections.first;
          activeConnectionId = recent['serverId'];
          endpoint.text = recent['endpoint'] ?? '';
          accessToken.text = recent['token'] ?? '';
        }
        permissionMode = RemotePermissionMode.values.firstWhere(
          (mode) => mode.name == savedPermission,
          orElse: () => RemotePermissionMode.requestApproval,
        );
      });
      if (connections.isNotEmpty) {
        final recent = connections.first;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_connectSaved(recent));
        });
      }
    } catch (_) {
      // Stored connection settings are optional; the user can enter them again.
    }
  }

  Future<void> setPermissionMode(RemotePermissionMode mode) async {
    setState(() => permissionMode = mode);
    try {
      await _RemoteHomePageState.connectionStore.savePermissionMode(mode.name);
    } catch (_) {
      // Permission persistence is optional; the selected mode still applies.
    }
  }

  Future<void> _saveConnection() async {
    try {
      await _RemoteHomePageState.connectionStore.saveConnections(connections);
    } catch (_) {
      // A storage failure must not prevent an otherwise valid connection.
    }
  }
}
