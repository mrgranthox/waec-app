import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/storage/encrypted_archive.dart';

/// Transaction history — plan §3.6.
///
/// Past purchases from the encrypted archive, a free re-fetch button
/// while the 24h grace window is active, and irreversible user-initiated
/// delete.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({
    super.key,
    required this.snapshots,
    required this.graceActiveIds,
    required this.onRefetch,
    required this.onOpen,
    required this.onDelete,
  });

  final List<ArchiveMeta> snapshots;
  /// Ids still inside the 24h grace window (free re-fetch allowed).
  final Set<String> graceActiveIds;
  final void Function(ArchiveMeta entry) onRefetch;
  final void Function(ArchiveMeta entry) onOpen;
  final void Function(ArchiveMeta entry) onDelete;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) {
      return const Center(child: Text('No saved results yet'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(WaecSpacing.md),
      itemCount: snapshots.length,
      itemBuilder: (context, i) {
        final s = snapshots[i];
        final graceActive = graceActiveIds.contains(s.id);
        return Card(
          child: ListTile(
            leading: Icon(
              Icons.workspace_premium_outlined,
              color: graceActive ? WaecColors.mint : null,
            ),
            title: Text('${s.examType} ${s.examYear}'),
            subtitle: Text(_when(s.createdUnix)),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'open' => onOpen(s),
                'refetch' => onRefetch(s),
                'delete' => onDelete(s),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'open', child: Text('View result')),
                // Free re-fetch during active grace (§3.6) — no re-charge.
                if (graceActive)
                  const PopupMenuItem(
                      value: 'refetch',
                      child: Text('Free re-fetch (grace)')),
                const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete permanently')),
              ],
            ),
            onTap: () => onOpen(s),
          ),
        );
      },
    );
  }

  String _when(int unixSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final age = DateTime.now().difference(dt);
    if (age.inHours < 24) return '${age.inHours}h ago';
    return '${age.inDays}d ago';
  }
}
