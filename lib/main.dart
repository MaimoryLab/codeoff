import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

void main() => runApp(const CodexRemoteApp());

class CodexRemoteApp extends StatelessWidget {
  const CodexRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Codex Remote',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RemoteHomePage(),
    );
  }
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  final endpoint = TextEditingController();
  final pairingToken = TextEditingController();
  final deviceName = TextEditingController(text: 'Phone');
  final accessToken = TextEditingController();
  final input = TextEditingController();
  RemoteApi? api;
  StreamSubscription<Map<String, dynamic>>? eventSubscription;
  List<Map<String, dynamic>> threads = [];
  List<Map<String, dynamic>> approvals = [];
  String? selectedThread;
  String message = 'Enter the desktop endpoint to begin.';
  bool busy = false;
  bool connected = false;

  @override
  void dispose() {
    eventSubscription?.cancel();
    for (final controller in [
      endpoint,
      pairingToken,
      deviceName,
      accessToken,
      input,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> pair() async {
    await _run('Pairing...', () async {
      final client = RemoteApi(endpoint.text);
      final value = await client.pair(pairingToken.text, deviceName.text);
      accessToken.text = _stringValue(value, 'token');
      await connect();
    });
  }

  Future<void> connect() async {
    await _run('Connecting...', () async {
      final client = RemoteApi(endpoint.text, token: accessToken.text);
      await client.status();
      api = client;
      connected = true;
      await _reloadThreads();
      _listenEvents(client);
      message = 'Connected';
    });
  }

  void _listenEvents(RemoteApi client) {
    eventSubscription?.cancel();
    eventSubscription = client.events().listen(
      (event) {
        if (!mounted) return;
        final id = event['id'];
        final method = '${event['method'] ?? ''}';
        if (id is int && method.contains('Approval')) {
          setState(() {
            approvals = [...approvals.where((item) => item['id'] != id), event];
            message = 'Approval requested';
          });
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => message = error.toString());
      },
    );
  }

  Future<void> _reloadThreads() async {
    final value = await api!.threads();
    final list = value is Map ? value['data'] ?? value['threads'] : value;
    final seen = <String>{};
    final next = list is List
        ? list
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .where((thread) => seen.add(_threadId(thread)))
              .where((thread) => _threadId(thread).isNotEmpty)
              .toList()
        : <Map<String, dynamic>>[];
    setState(() {
      threads = next;
      final ids = next.map(_threadId).toSet();
      selectedThread = ids.contains(selectedThread)
          ? selectedThread
          : next.isEmpty
          ? null
          : _threadId(next.first);
    });
  }

  Future<void> createThread() async {
    await _run('Starting thread...', () async {
      final value = await api!.startThread();
      final id = _idFromValue(value);
      await _reloadThreads();
      if (threads.any((thread) => _threadId(thread) == id)) {
        setState(() => selectedThread = id);
      }
    });
  }

  Future<void> sendTurn() async {
    final id = selectedThread;
    if (id == null || input.text.trim().isEmpty) return;
    await _run('Sending...', () async {
      final thread = threads.firstWhere(
        (item) => _threadId(item) == id,
        orElse: () => <String, dynamic>{},
      );
      if (_threadNeedsResume(thread)) await api!.resumeThread(id);
      await api!.startTurn(id, input.text.trim());
      input.clear();
      message = 'Turn started';
    });
  }

  Future<void> answer(Map<String, dynamic> event, String decision) async {
    final id = event['id'];
    if (id is! int) return;
    await _run('Sending decision...', () async {
      await api!.approve(id, decision);
      setState(() => approvals.removeWhere((item) => item['id'] == id));
    });
  }

  Future<void> _run(String pending, Future<void> Function() operation) async {
    setState(() {
      busy = true;
      message = pending;
    });
    try {
      await operation();
    } catch (error) {
      message = error.toString();
      connected = false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Codex Remote'),
        actions: [
          Icon(
            connected ? Icons.cloud_done : Icons.cloud_off,
            color: connected ? Colors.greenAccent : null,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Connection', [
            TextField(
              controller: endpoint,
              decoration: const InputDecoration(
                labelText: 'Desktop endpoint',
                hintText: 'https://...trycloudflare.com',
              ),
            ),
            TextField(
              controller: accessToken,
              decoration: const InputDecoration(labelText: 'Device token'),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: busy ? null : connect,
                    icon: const Icon(Icons.login),
                    label: const Text('Connect'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => setState(() => accessToken.clear()),
                    icon: const Icon(Icons.link),
                    label: const Text('Clear token'),
                  ),
                ),
              ],
            ),
          ]),
          _section('Pair new device', [
            TextField(
              controller: pairingToken,
              decoration: const InputDecoration(
                labelText: 'One-time pairing code',
              ),
            ),
            TextField(
              controller: deviceName,
              decoration: const InputDecoration(labelText: 'Device name'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: busy ? null : pair,
                icon: const Icon(Icons.add_link),
                label: const Text('Pair'),
              ),
            ),
          ]),
          _section('Threads', [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value:
                        threads.any(
                          (thread) => _threadId(thread) == selectedThread,
                        )
                        ? selectedThread
                        : null,
                    hint: const Text('Select a thread'),
                    items: threads.map((thread) {
                      final id = _threadId(thread);
                      return DropdownMenuItem(
                        value: id,
                        child: Text(
                          _threadName(thread),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) =>
                        setState(() => selectedThread = value),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: busy || !connected ? null : createThread,
                  tooltip: 'New thread',
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            TextField(
              controller: input,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy || !connected || selectedThread == null
                    ? null
                    : sendTurn,
                icon: const Icon(Icons.send),
                label: const Text('Send'),
              ),
            ),
          ]),
          if (approvals.isNotEmpty)
            _section(
              'Approvals',
              approvals.map((event) => _approvalCard(event)).toList(),
            ),
          Text(message, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

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

  Widget _section(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );

  String _threadId(Map<String, dynamic> thread) =>
      '${thread['id'] ?? thread['threadId'] ?? ''}';

  String _threadName(Map<String, dynamic> thread) {
    for (final key in ['name', 'sessionName', 'title', 'preview']) {
      final value = thread[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return _threadId(thread);
  }

  bool _threadNeedsResume(Map<String, dynamic> thread) {
    final status = thread['status'];
    return status is Map && status['type'] == 'notLoaded';
  }

  String _idFromValue(dynamic value) {
    if (value is! Map) return '';
    for (final key in ['id', 'threadId']) {
      if (value[key] != null) return '${value[key]}';
    }
    return _idFromValue(value['thread']);
  }

  String _stringValue(dynamic value, String key) {
    if (value is Map && value[key] != null) return '${value[key]}';
    return '';
  }
}
