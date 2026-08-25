part of 'remote_home_page.dart';

class _PairingFailure implements Exception {
  const _PairingFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

extension _PairingScanner on _RemoteHomePageState {
  Future<void> scanPairingCode() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _PairingScannerPage()),
    );
    if (!mounted || raw == null) return;
    final connecting = context.t('connecting');
    final invalidPairingCode = context.t('invalidPairingCode');
    final noReachableAddress = context.t('noReachableAddress');
    final serverNotPaired = context.t('serverNotPaired');
    final deviceName = _defaultDeviceName;
    await _run(connecting, () async {
      try {
        await _connectPairingPayload(
          PairingPayload.parse(raw),
          deviceName: deviceName,
          noReachableAddress: noReachableAddress,
          serverNotPaired: serverNotPaired,
        );
      } on FormatException {
        throw _PairingFailure(invalidPairingCode);
      } on _PairingFailure {
        rethrow;
      } catch (error) {
        throw _PairingFailure(error.toString());
      }
    });
  }

  Future<void> _connectPairingPayload(
    PairingPayload payload, {
    required String deviceName,
    required String noReachableAddress,
    required String serverNotPaired,
  }) async {
    final saved = connections.where(
      (record) => record['serverId'] == payload.serverUuid,
    );
    var token = saved.isEmpty ? '' : saved.first['token'] ?? '';
    if (token.isEmpty) {
      if (payload.pairingCode.isEmpty) throw _PairingFailure(serverNotPaired);
      Object? lastError;
      for (final candidate in payload.endpoints) {
        final client = RemoteApi(candidate);
        try {
          final value = await client.pair(payload.pairingCode, deviceName);
          final server = _serverFrom(value);
          if ('${server['id'] ?? ''}' != payload.serverUuid) {
            throw const _PairingFailure('Pairing server UUID mismatch');
          }
          token = _stringValue(value, 'token');
          break;
        } catch (error) {
          lastError = error;
        } finally {
          await client.close();
        }
      }
      if (token.isEmpty) {
        throw _PairingFailure(lastError?.toString() ?? noReachableAddress);
      }
    }

    final candidate = await _firstReachable(
      payload.endpoints,
      token,
      payload.serverUuid,
    );
    if (candidate == null) {
      throw _PairingFailure(noReachableAddress);
    }
    await _disconnect();
    _showConnectionStatus(RemoteConnectionStatus.connecting);
    try {
      await _connectRecord(candidate, token);
    } catch (error) {
      await _disconnect();
      throw _PairingFailure(error.toString());
    }
  }

  Future<String?> _firstReachable(
    List<String> candidates,
    String token,
    String serverUuid,
  ) async {
    for (final candidate in candidates) {
      final client = RemoteApi(candidate, token: token);
      try {
        final status = await client.status();
        if ('${_serverFrom(status)['id'] ?? ''}' == serverUuid) {
          return candidate;
        }
      } catch (_) {
        // Try the next advertised address.
      } finally {
        await client.close();
      }
    }
    return null;
  }
}

class _PairingScannerPage extends StatefulWidget {
  const _PairingScannerPage();

  @override
  State<_PairingScannerPage> createState() => _PairingScannerPageState();
}

class _PairingScannerPageState extends State<_PairingScannerPage> {
  final controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool handled = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.t('scanPairingCode'))),
    body: MobileScanner(
      controller: controller,
      onDetect: (capture) {
        if (handled) return;
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (value != null && value.isNotEmpty) {
            handled = true;
            Navigator.pop(context, value);
            return;
          }
        }
      },
    ),
  );
}
