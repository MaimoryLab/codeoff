import 'dart:convert';

import 'package:flutter/material.dart';

import '../../i18n.dart';

class OperationDetailsPage extends StatelessWidget {
  const OperationDetailsPage({
    required this.items,
    required this.titleBuilder,
    super.key,
  });

  final List<Map<String, dynamic>> items;
  final String Function(Map<String, dynamic>) titleBuilder;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.t('operationDetails')),
    content: SizedBox(
      width: double.maxFinite,
      child: ListView(
        shrinkWrap: true,
        children: [for (final item in items) _card(context, item)],
      ),
    ),
  );

  Widget _card(BuildContext context, Map<String, dynamic> item) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titleBuilder(item),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          _value(context, item, 'input', ['input', 'arguments', 'command']),
          _value(context, item, 'output', ['output', 'result', 'changes']),
        ],
      ),
    ),
  );

  Widget _value(
    BuildContext context,
    Map<String, dynamic> item,
    String label,
    List<String> keys,
  ) {
    final value = _find(item, keys);
    if (value.isEmpty) return const SizedBox.shrink();
    return SelectableText(
      '${context.t(label)}: $value',
      style: const TextStyle(fontFamily: 'monospace'),
    );
  }

  String _find(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      if (value == null || value is String && value.trim().isEmpty) continue;
      try {
        return value is String
            ? value.trim()
            : const JsonEncoder.withIndent('  ').convert(value);
      } catch (_) {
        return '$value';
      }
    }
    return '';
  }
}
