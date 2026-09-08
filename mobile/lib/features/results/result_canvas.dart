import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';

/// Official result canvas — plan §3.5.
///
/// WAEC-style rendering: candidate header, subject/grade table,
/// 24h grace-period badge with live countdown, uses-remaining counter.
class ResultCanvas extends StatefulWidget {
  const ResultCanvas({
    super.key,
    required this.indexNumber,
    required this.examType,
    required this.examYear,
    required this.candidateName,
    required this.grades,
    required this.aggregate,
    required this.graceExpiresAt,
    this.refetchRemaining = 1,
  });

  final String indexNumber;
  final ExamType examType;
  final String examYear;
  final String candidateName;
  final List<SubjectGradeView> grades;
  final String aggregate;
  final DateTime graceExpiresAt;
  final int refetchRemaining;

  @override
  State<ResultCanvas> createState() => _ResultCanvasState();
}

class _ResultCanvasState extends State<ResultCanvas> {
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _remaining = widget.graceExpiresAt.difference(DateTime.now());
    // 1-second countdown tick from server-synced expiry (acceptance §3.5).
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _remaining = widget.graceExpiresAt.difference(DateTime.now());
        if (_remaining.isNegative) t.cancel();
      });
    });
  }

  String get _countdown {
    if (_remaining.isNegative) return 'expired';
    final h = _remaining.inHours;
    final m = _remaining.inMinutes % 60;
    final s = _remaining.inSeconds % 60;
    return '${h}h ${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(WaecSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Grace-period badge with live countdown (§3.5).
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: WaecSpacing.sm, vertical: WaecSpacing.xs),
              decoration: BoxDecoration(
                color: WaecColors.mint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(WaecRadii.pill),
              ),
              child: Text(
                'Free re-fetch window: $_countdown',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: WaecColors.navy,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: WaecSpacing.md),
            Text('WEST AFRICAN EXAMINATIONS COUNCIL',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: WaecSpacing.xs),
            Text(widget.examType.displayName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: WaecSpacing.md),
            _kv('Candidate', widget.candidateName),
            _kv('Index number', widget.indexNumber),
            _kv('Exam year', widget.examYear),
            const Divider(height: WaecSpacing.lg),
            // Subject/grade table.
            for (final g in widget.grades)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(g.subject)),
                    Text(g.grade,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            const Divider(height: WaecSpacing.lg),
            if (widget.aggregate.isNotEmpty)
              _kv('Aggregate', widget.aggregate),
            const SizedBox(height: WaecSpacing.sm),
            Text('Re-fetches remaining: ${widget.refetchRemaining}',
                style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: WaecColors.textSecondaryLight)),
            Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

/// Renderable grade pair (kept independent of the API payload model).
class SubjectGradeView {
  const SubjectGradeView({required this.subject, required this.grade});
  final String subject;
  final String grade;
}
