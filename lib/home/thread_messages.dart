part of 'remote_home_page.dart';

extension _ThreadMessages on _RemoteHomePageState {
  Widget _threadMessages() {
    final pendingApprovals = approvals.where((event) {
      final threadId = approvalThreadIdFrom(event);
      return threadId.isEmpty || threadId == selectedThread;
    }).toList();
    final processingCount = processingSummary.isEmpty ? 0 : 1;
    if (loadingHistory &&
        history.isEmpty &&
        processingSummary.isEmpty &&
        pendingApprovals.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (history.isEmpty &&
        processingSummary.isEmpty &&
        pendingApprovals.isEmpty) {
      return _emptyState(context.t('noMessages'), Icons.chat_bubble_outline);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      reverse: true,
      itemCount: history.length + pendingApprovals.length + processingCount,
      itemBuilder: (context, index) {
        if (index < pendingApprovals.length) {
          return _approvalMessage(
            pendingApprovals[pendingApprovals.length - 1 - index],
          );
        }
        final activityIndex = index - pendingApprovals.length;
        if (processingCount == 1 && activityIndex == 0) {
          return _processingSummary();
        }
        return _messageBubble(
          history[history.length - 1 - activityIndex + processingCount],
        );
      },
    );
  }

  IconData _permissionIcon(RemotePermissionMode mode) => switch (mode) {
    RemotePermissionMode.requestApproval => Icons.shield_outlined,
    RemotePermissionMode.autoApprove => Icons.verified_user_outlined,
    RemotePermissionMode.fullAccess => Icons.warning_amber,
  };

  String _permissionLabel(RemotePermissionMode mode) => switch (mode) {
    RemotePermissionMode.requestApproval => context.t('askForApproval'),
    RemotePermissionMode.autoApprove => context.t('approveForMe'),
    RemotePermissionMode.fullAccess => context.t('fullAccess'),
  };

  Widget _messageBubble(Map<String, dynamic> item) {
    final user = _messageRole(item) == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        decoration: BoxDecoration(
          color: user ? const Color(0xff9f6148) : const Color(0xff292a2e),
          borderRadius: BorderRadius.circular(18),
        ),
        child: MarkdownBody(
          data: _messageText(item),
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
          onTapLink: (_, href, _) async {
            final uri = externalHttpUri(href);
            if (uri == null) return;
            try {
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                throw Exception('Could not open $uri');
              }
            } catch (error) {
              if (mounted) {
                ScaffoldMessenger.maybeOf(context)
                    ?.showSnackBar(SnackBar(content: Text(error.toString())));
              }
            }
          },
        ),
      ),
    );
  }

  Widget _approvalMessage(Map<String, dynamic> event) {
    final details = approvalDetailsFrom(event, AppLocalizations.of(context));
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xff302a27),
          border: Border.all(color: const Color(0xff9f6148)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield_outlined, size: 19),
                const SizedBox(width: 8),
                Text(
                  context.t('approvalSuffix', {'kind': details.kind}),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              context.t('reason'),
              style: const TextStyle(color: Colors.white60),
            ),
            SelectableText(details.reason),
            const SizedBox(height: 10),
            Text(details.kind, style: const TextStyle(color: Colors.white60)),
            SelectableText(
              details.target,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => answer(event, 'decline'),
                  icon: const Icon(Icons.close),
                  label: Text(context.t('deny')),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: busy ? null : () => answer(event, 'accept'),
                  icon: const Icon(Icons.check),
                  label: Text(context.t('allow')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _processingSummary() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            processingSummary,
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
