import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/vs2015.dart';

import '../../i18n.dart';

class OperationDetailsPage extends StatelessWidget {
  const OperationDetailsPage({
    required this.items,
    required this.titleBuilder,
    this.onOpenFile,
    super.key,
  });

  final List<Map<String, dynamic>> items;
  final String Function(Map<String, dynamic>) titleBuilder;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final path = _firstFilePath();
    return AlertDialog(
      title: Text(context.t('operationDetails')),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final item in items)
              if (titleBuilder(item).isNotEmpty) _card(context, item),
          ],
        ),
      ),
      actions: [
        if (path != null && onOpenFile != null)
          TextButton.icon(
            onPressed: () => onOpenFile!(path),
            icon: const Icon(Icons.open_in_new),
            label: Text(context.t('openFile')),
          ),
      ],
    );
  }

  String? _firstFilePath() {
    for (final item in items) {
      final path = fileChangePath(item);
      if (path != null) return path;
    }
    return null;
  }

  Widget _card(BuildContext context, Map<String, dynamic> item) => Card(
    margin: const EdgeInsets.only(bottom: 10),
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
          item['type'] == 'fileChange'
              ? _diff(item)
              : _value(context, item, 'output', [
                  'output',
                  'aggregatedOutput',
                  'stdout',
                  'stderr',
                  'result',
                  'changes',
                ]),
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
    final command = label == 'input' && item['type'] == 'commandExecution'
        ? '${item['command'] ?? ''}'.trim()
        : '';
    if (command.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text('${context.t(label)}:'), _codeBlock(command, 'shell')],
      );
    }
    if (label == 'output' && item['type'] == 'commandExecution') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${context.t(label)}:'),
          _codeBlock(value, 'plaintext'),
        ],
      );
    }
    return SelectableText(
      '${context.t(label)}: $value',
      style: const TextStyle(fontFamily: 'monospace'),
    );
  }

  Widget _diff(Map<String, dynamic> item) {
    final diff = fileChangeDiff(item);
    if (diff.isEmpty) return const SizedBox.shrink();
    return _codeBlock(diff, 'diff');
  }

  Widget _codeBlock(String source, String language) => SelectionArea(
    child: HighlightView(
      source,
      language: language,
      theme: vs2015Theme,
      padding: const EdgeInsets.all(8),
      textStyle: const TextStyle(fontFamily: 'monospace'),
    ),
  );

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

String? fileChangePath(Map<String, dynamic> item) {
  final type = '${item['type'] ?? ''}'.toLowerCase();
  if (!type.contains('file')) return null;
  for (final key in ['path', 'filePath', 'filename', 'file']) {
    final path = '${item[key] ?? ''}'.trim();
    if (path.isNotEmpty && path != 'null') return path;
  }
  final changes = item['changes'];
  if (changes is List) {
    for (final change in changes) {
      if (change is Map) {
        final path = '${change['path'] ?? ''}'.trim();
        if (path.isNotEmpty && path != 'null') return path;
      }
    }
  }
  if (changes is Map) {
    final directPath = '${changes['path'] ?? ''}'.trim();
    if (directPath.isNotEmpty && directPath != 'null') return directPath;
    for (final entry in changes.entries) {
      final path = '${entry.key}'.trim();
      if (path.isNotEmpty &&
          path != 'null' &&
          path != 'diff' &&
          path != 'kind') {
        return path;
      }
      if (entry.value is Map) {
        final nestedPath = '${entry.value['path'] ?? ''}'.trim();
        if (nestedPath.isNotEmpty && nestedPath != 'null') return nestedPath;
      }
    }
  }
  return null;
}

String fileChangeDiff(Map<String, dynamic> item) {
  final direct = '${item['diff'] ?? ''}'.trim();
  if (direct.isNotEmpty && direct != 'null') return direct;
  final changes = item['changes'];
  final diffs = <String>[];
  if (changes is List) {
    for (final change in changes) {
      if (change is Map) {
        final diff = '${change['diff'] ?? ''}'.trim();
        if (diff.isNotEmpty && diff != 'null') diffs.add(diff);
      }
    }
  } else if (changes is Map) {
    final directDiff = '${changes['diff'] ?? ''}'.trim();
    if (directDiff.isNotEmpty && directDiff != 'null') diffs.add(directDiff);
    for (final value in changes.values) {
      if (value is Map) {
        final diff = '${value['diff'] ?? ''}'.trim();
        if (diff.isNotEmpty && diff != 'null') diffs.add(diff);
      }
    }
  }
  return diffs.join('\n');
}
