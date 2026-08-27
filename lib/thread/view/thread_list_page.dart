import 'package:flutter/material.dart';

import '../../i18n.dart';

class ThreadListPage extends StatelessWidget {
  const ThreadListPage({
    required this.search,
    required this.threads,
    required this.connected,
    required this.onRefresh,
    required this.onSearchChanged,
    required this.itemBuilder,
    required this.emptyState,
    super.key,
  });

  final TextEditingController search;
  final List<Map<String, dynamic>> threads;
  final bool connected;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onSearchChanged;
  final Widget Function(Map<String, dynamic>) itemBuilder;
  final Widget Function(String label, IconData icon) emptyState;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: TextField(
          controller: search,
          onChanged: onSearchChanged,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: context.t('searchThreads'),
          ),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: onRefresh,
          child: threads.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  children: [
                    SizedBox(
                      height: 240,
                      child: emptyState(
                        connected
                            ? context.t('noThreadsYet')
                            : context.t('connectFromSettings'),
                        Icons.forum_outlined,
                      ),
                    ),
                  ],
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  children: [for (final thread in threads) itemBuilder(thread)],
                ),
        ),
      ),
    ],
  );
}
