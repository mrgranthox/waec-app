import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import '../../core/storage/encrypted_archive.dart';
import '../../core/ui/waec_ui.dart';

/// Transaction history — port of
/// docs/WAEC Result Verification App/src/screens/HistoryScreen.tsx.
///
/// Figma drives the layout (navy log header, "local storage only" notice,
/// per-record cards with monospace id + "Saved Local" chip). Data still
/// comes from the encrypted archive (plan §3.6): free re-fetch while the
/// 24h grace window is active, and irreversible user-initiated delete.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({
    super.key,
    required this.snapshots,
    required this.graceActiveIds,
    required this.onRefetch,
    required this.onOpen,
    required this.onDelete,
    this.checkers = const <Checker>[],
    this.onRedeemChecker,
    this.onDeleteChecker,
  });

  final List<ArchiveMeta> snapshots;

  /// Checkers held in the encrypted vault, newest first (ADR-001).
  ///
  /// Shown above saved results because an unspent checker is the one item on
  /// this screen with something left to do.
  final List<Checker> checkers;

  /// Spend a stored checker. The card renders the "Check Result" action only
  /// when this is supplied, so a host that cannot redeem never shows a dead
  /// button.
  final void Function(Checker checker)? onRedeemChecker;

  /// Forget a checker permanently (irreversible, with the ADR-001 zero-out).
  final void Function(Checker checker)? onDeleteChecker;

  /// Ids still inside the 24h grace window (free re-fetch allowed).
  final Set<String> graceActiveIds;
  final void Function(ArchiveMeta entry) onRefetch;
  final void Function(ArchiveMeta entry) onOpen;
  final void Function(ArchiveMeta entry) onDelete;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WaecNavyHeader(
              eyebrow: 'Transaction Log',
              title: 'Saved Results',
              subtitle: checkers.isEmpty
                  ? '${snapshots.length} records stored locally on this device'
                  : '${snapshots.length} records · '
                        '${checkers.where((c) => c.isRedeemable).length} '
                        'checkers ready',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: WaecSpacing.xl),
                children: [
                  const _LocalStorageNotice(),
                  if (checkers.isNotEmpty) ...[
                    const _SectionHeader('Result Checkers'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                      child: Column(
                        children: [
                          for (final c in checkers)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _CheckerCard(
                                checker: c,
                                onCheck: onRedeemChecker == null
                                    ? null
                                    : () => onRedeemChecker!(c),
                                onDelete: onDeleteChecker == null
                                    ? null
                                    : () => onDeleteChecker!(c),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (snapshots.isNotEmpty)
                    const _SectionHeader('Saved Results'),
                  if (snapshots.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 48, 24, 0),
                      child: Text('No saved results yet',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFF94A3B8))),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                      child: Column(
                        children: [
                          for (final s in snapshots)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _HistoryCard(
                                meta: s,
                                graceActive: graceActiveIds.contains(s.id),
                                onOpen: () => onOpen(s),
                                onRefetch: () => onRefetch(s),
                                onDelete: () => onDelete(s),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (snapshots.isNotEmpty) const _EndOfRecords(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// White notice card explaining device-local retention (Figma's shield row).
class _LocalStorageNotice extends StatelessWidget {
  const _LocalStorageNotice();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: waecCardDecoration(),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.workspace_premium_outlined,
                  size: 16, color: WaecColors.mint),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Local Storage Only',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: WaecColors.navy)),
                  SizedBox(height: 2),
                  Text(
                      'All records exist only on this device. No cloud backup.',
                      style:
                          TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                ],
              ),
            ),
          ],
        ),
      );
}

/// "End of records" divider shown under the list (Figma footer hint).
class _EndOfRecords extends StatelessWidget {
  const _EndOfRecords();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: Row(
          children: [
            Expanded(child: Divider(color: Color(0xFFE2E8F0), thickness: 1)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('End of records',
                  style: TextStyle(fontSize: 11, color: Color(0xFFCBD5E1))),
            ),
            Expanded(child: Divider(color: Color(0xFFE2E8F0), thickness: 1)),
          ],
        ),
      );
}

/// One saved-result card.
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.meta,
    required this.graceActive,
    required this.onOpen,
    required this.onRefetch,
    required this.onDelete,
  });

  final ArchiveMeta meta;
  final bool graceActive;
  final VoidCallback onOpen;
  final VoidCallback onRefetch;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: waecCardDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Card header: monospace id + saved chip + overflow menu.
          Container(
            color: const Color(0xFFFAFBFC),
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: Row(
              children: [
                Text(meta.id, style: WaecTheme.monoNum(13, WaecColors.navy)),
                const Spacer(),
                WaecChip(
                  label: graceActive ? 'Grace Active' : 'Saved Local',
                  foreground: graceActive
                      ? WaecColors.navy
                      : const Color(0xFF00856F),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz,
                      size: 18, color: Color(0xFF94A3B8)),
                  onSelected: (v) => switch (v) {
                    'open' => onOpen(),
                    'refetch' => onRefetch(),
                    'delete' => onDelete(),
                    _ => null,
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'open', child: Text('View result')),
                    // Free re-fetch during active grace (§3.6) — no re-charge.
                    if (graceActive)
                      const PopupMenuItem(
                          value: 'refetch',
                          child: Text('Free re-fetch (grace)')),
                    const PopupMenuItem(
                        value: 'delete', child: Text('Delete permanently')),
                  ],
                ),
              ],
            ),
          ),
          // Card body.
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(meta.examType,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: WaecColors.navy)),
                            const SizedBox(height: 2),
                            Text('Year ${meta.examYear}',
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF64748B))),
                          ],
                        ),
                      ),
                      Text(_when(meta.createdUnix),
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: WaecColors.navy)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text('REF: ${meta.id}',
                            style: const TextStyle(
                                fontSize: 10,
                                fontFamily: 'JetBrains Mono',
                                color: Color(0xFF94A3B8))),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: WaecColors.navy,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          minimumSize: Size.zero,
                          textStyle: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        icon: const Icon(Icons.chevron_right, size: 14),
                        label: const Text('View Stored Result'),
                        onPressed: onOpen,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _when(int unixSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final age = DateTime.now().difference(dt);
    if (age.inHours < 24) return '${age.inHours}h ago';
    return '${age.inDays}d ago';
  }
}

/// Group heading inside the log list.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Color(0xFF94A3B8),
      ),
    ),
  );
}

/// A stored result checker with its "Check Result" action attached.
///
/// The serial is rendered **masked** (last 4 characters only): the full
/// credential is never on screen, so it cannot be captured in a screenshot or
/// read over a shoulder. The real value never leaves the encrypted vault except
/// when the redemption call needs it.
class _CheckerCard extends StatelessWidget {
  const _CheckerCard({
    required this.checker,
    required this.onCheck,
    required this.onDelete,
  });

  final Checker checker;

  /// Null when the host cannot redeem (no handler wired).
  final VoidCallback? onCheck;

  /// Null when the host cannot delete.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final usable = checker.isRedeemable;
    return Container(
      decoration: BoxDecoration(
        color: WaecColors.cardLight,
        borderRadius: BorderRadius.circular(WaecRadii.lg),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _examLabel(checker.examType),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: WaecColors.navy,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Year ${checker.examYear} · ${_when(checker.purchasedAtUnix)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                WaecChip(
                  label: checker.status.displayName,
                  foreground: usable
                      ? const Color(0xFF00856F)
                      : const Color(0xFF64748B),
                  background: usable
                      ? const Color(0xFFF0FDF9)
                      : const Color(0xFFF1F5F9),
                  borderColor: usable
                      ? const Color(0xFFCCFBF1)
                      : const Color(0xFFE2E8F0),
                ),
                if (onDelete != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Delete checker',
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'SERIAL ${checker.maskedSerial}',
              style: const TextStyle(
                fontSize: 10,
                fontFamily: 'JetBrains Mono',
                color: Color(0xFF94A3B8),
              ),
            ),
            // The action is only offered for a checker that can still be spent,
            // and only when the host can actually run the redemption.
            if (usable && onCheck != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: Key('history-check-${checker.id}'),
                  style: FilledButton.styleFrom(
                    backgroundColor: WaecColors.navy,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    minimumSize: Size.zero,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: onCheck,
                  icon: const Icon(Icons.search, size: 14),
                  label: const Text('Check Result'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Wire code -> the label the rest of the app shows.
  String _examLabel(String code) =>
      ExamType.fromCode(code).displayName;

  String _when(int unixSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final age = DateTime.now().difference(dt);
    if (age.inHours < 24) return '${age.inHours}h ago';
    return '${age.inDays}d ago';
  }
}
