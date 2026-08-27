import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/vs2015.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' show Node, highlight;
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../i18n.dart';
import '../remote/remote_api.dart';

class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({required this.api, required this.path, super.key});

  final RemoteApi api;
  final String path;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  late String path = widget.path;
  _BrowserListing? listing;
  Object? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load(path);
  }

  Future<void> _load(String nextPath) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await widget.api.directories(path: nextPath);
      if (!mounted) return;
      setState(() {
        path = nextPath;
        listing = _BrowserListing.from(value);
      });
    } catch (value) {
      if (mounted) setState(() => error = value);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _openFile(String filePath) async {
    try {
      final file = await widget.api.downloadFile(filePath);
      if (mounted) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => FilePreviewPage(file: file)),
        );
      }
    } catch (value) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$value')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = listing;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('workspaceFiles'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
          if (error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text('$error')),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : current == null ||
                      (current.directories.isEmpty && current.files.isEmpty)
                ? Center(child: Text(context.t('emptyFolder')))
                : ListView(
                    children: [
                      if (current.parent.isNotEmpty)
                        ListTile(
                          leading: const Icon(
                            Icons.drive_folder_upload_outlined,
                          ),
                          title: const Text('..'),
                          onTap: () => _load(current.parent),
                        ),
                      for (final directory in current.directories)
                        ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(directory.name),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _load(directory.path),
                        ),
                      for (final file in current.files)
                        ListTile(
                          leading: Icon(_fileIcon(file.name)),
                          title: Text(file.name),
                          subtitle: Text(_fileSize(file.size)),
                          onTap: () => _openFile(file.path),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class FilePreviewPage extends StatefulWidget {
  const FilePreviewPage({required this.file, super.key});

  final RemoteFile file;

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  Future<void> _save() async {
    final uri = await FilePicker.saveFile(
      fileName: widget.file.name,
      bytes: widget.file.bytes,
      mimeType: widget.file.contentType,
    );
    if (mounted && uri != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.t('fileSaved'))));
    }
  }

  Future<void> _share() => SharePlus.instance.share(
    ShareParams(
      title: widget.file.name,
      files: [
        XFile.fromData(
          widget.file.bytes,
          name: widget.file.name,
          mimeType: widget.file.contentType,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.file.name, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: context.t('save'),
          onPressed: _save,
          icon: const Icon(Icons.download_outlined),
        ),
        IconButton(
          tooltip: context.t('share'),
          onPressed: _share,
          icon: const Icon(Icons.share_outlined),
        ),
      ],
    ),
    body: _body(),
  );

  Widget _body() {
    final file = widget.file;
    final lowerName = file.name.toLowerCase();
    if (file.contentType == 'application/pdf' || lowerName.endsWith('.pdf')) {
      return SfPdfViewer.memory(file.bytes);
    }
    if (file.contentType.startsWith('image/')) {
      return InteractiveViewer(
        child: Center(child: Image.memory(file.bytes, fit: BoxFit.contain)),
      );
    }
    if (_isText(file)) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: lowerName.endsWith('.md') || lowerName.endsWith('.markdown')
            ? SizedBox(
                width: double.infinity,
                child: MarkdownBody(
                  data: utf8.decode(file.bytes, allowMalformed: true),
                  selectable: true,
                ),
              )
            : _SelectableHighlight(
                source: utf8.decode(file.bytes, allowMalformed: true),
                language: _language(lowerName),
              ),
      );
    }
    return Center(child: Text(context.t('previewUnavailable')));
  }
}

class _SelectableHighlight extends StatelessWidget {
  const _SelectableHighlight({required this.source, required this.language});

  final String source;
  final String language;

  @override
  Widget build(BuildContext context) {
    final lineCount = source.split('\n').length;
    final lineNumberWidth = lineCount.toString().length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IgnorePointer(
            child: Text(
              List.generate(
                lineCount,
                (index) => (index + 1).toString().padLeft(lineNumberWidth),
              ).join('\n'),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white38,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SelectableText.rich(
            TextSpan(
              style: vs2015Theme['root']!.copyWith(
                backgroundColor: Colors.transparent,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              children: _spans(
                highlight.parse(source, language: language).nodes ?? const [],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<TextSpan> _spans(List<Node> nodes) => [
    for (final node in nodes)
      if (node.value != null)
        TextSpan(
          text: node.value,
          style: node.className == null ? null : vs2015Theme[node.className!],
        )
      else if (node.children != null)
        TextSpan(
          children: _spans(node.children!),
          style: node.className == null ? null : vs2015Theme[node.className!],
        ),
  ];
}

class _BrowserListing {
  const _BrowserListing({
    required this.parent,
    required this.directories,
    required this.files,
  });

  final String parent;
  final List<_BrowserEntry> directories;
  final List<_BrowserFile> files;

  factory _BrowserListing.from(dynamic value) {
    if (value is! Map) {
      throw const FormatException('Invalid directory response');
    }
    final directories = value['directories'] is List
        ? (value['directories'] as List)
              .whereType<Map>()
              .map(
                (entry) => _BrowserEntry(
                  '${entry['name'] ?? ''}',
                  '${entry['path'] ?? ''}',
                ),
              )
              .where((entry) => entry.name.isNotEmpty)
              .toList()
        : <_BrowserEntry>[];
    final files = value['files'] is List
        ? (value['files'] as List)
              .whereType<Map>()
              .map(
                (entry) => _BrowserFile(
                  '${entry['name'] ?? ''}',
                  '${entry['path'] ?? ''}',
                  entry['size'] is num ? (entry['size'] as num).toInt() : 0,
                ),
              )
              .where((entry) => entry.name.isNotEmpty)
              .toList()
        : <_BrowserFile>[];
    return _BrowserListing(
      parent: '${value['parent'] ?? ''}',
      directories: directories,
      files: files,
    );
  }
}

class _BrowserEntry {
  const _BrowserEntry(this.name, this.path);
  final String name;
  final String path;
}

class _BrowserFile extends _BrowserEntry {
  const _BrowserFile(super.name, super.path, this.size);
  final int size;
}

bool _isText(RemoteFile file) {
  if (file.contentType.startsWith('text/') ||
      file.contentType.contains('json')) {
    return true;
  }
  return RegExp(
    r'\.(txt|md|markdown|json|ya?ml|xml|html?|css|js|ts|dart|go|rs|py|java|kt|sh|sql|toml|ini|conf)$',
  ).hasMatch(file.name.toLowerCase());
}

String _language(String name) {
  final extension = name.split('.').last;
  return {
        'md': 'markdown',
        'markdown': 'markdown',
        'yml': 'yaml',
        'html': 'xml',
        'htm': 'xml',
        'js': 'javascript',
        'ts': 'typescript',
        'py': 'python',
        'rs': 'rust',
        'sh': 'bash',
      }[extension] ??
      (extension.isEmpty ? 'plaintext' : extension);
}

String _fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

IconData _fileIcon(String name) {
  final lower = name.toLowerCase();
  if (RegExp(r'\.(png|jpe?g|gif|webp|heic|bmp)$').hasMatch(lower)) {
    return Icons.image_outlined;
  }
  if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
  return Icons.insert_drive_file_outlined;
}
