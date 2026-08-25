import 'dart:convert';

class PairingPayload {
  const PairingPayload({
    required this.serverUuid,
    required this.pairingCode,
    required this.listenAddresses,
    required this.tunnelAddress,
  });

  factory PairingPayload.parse(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map) throw const FormatException('Invalid pairing payload');
    final serverUuid = '${value['serverUuid'] ?? ''}'.trim();
    final pairingCode = '${value['pairingCode'] ?? ''}'.trim();
    final listenAddresses = value['listenAddresses'];
    final tunnelAddress = _httpEndpoint(value['tunnelAddress']);
    if (serverUuid.isEmpty || listenAddresses is! List) {
      throw const FormatException('Invalid pairing payload');
    }
    final endpoints = listenAddresses
        .map(_httpEndpoint)
        .whereType<String>()
        .toList();
    if (endpoints.isEmpty && tunnelAddress == null) {
      throw const FormatException('Pairing payload has no usable address');
    }
    return PairingPayload(
      serverUuid: serverUuid,
      pairingCode: pairingCode,
      listenAddresses: endpoints,
      tunnelAddress: tunnelAddress ?? '',
    );
  }

  final String serverUuid;
  final String pairingCode;
  final List<String> listenAddresses;
  final String tunnelAddress;

  List<String> get endpoints => {
    ...listenAddresses,
    if (tunnelAddress.isNotEmpty) tunnelAddress,
  }.toList();
}

String? _httpEndpoint(dynamic value) {
  final text = '${value ?? ''}'.trim().replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri.toString();
}
