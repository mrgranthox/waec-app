import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';

/// Official result screen — port of
/// docs/WAEC Result Verification App/src/screens/ResultScreen.tsx.
///
/// Full-page WAEC-style rendering: navy header (back, exam meta, saved
/// pill), verified-reference strip, subject/grade table with color-coded
/// grade chips, overall-performance summary with live 24h grace countdown,
/// and Export / Clear actions. Grades are held only in memory (plan §3.5);
/// [onClear] is invoked when the candidate permanently erases the record.
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
    this.onBack,
    this.onClear,
    this.reference,
  });

  final String indexNumber;
  final ExamType examType;
  final String examYear;
  final String candidateName;
  final List<SubjectGradeView> grades;
  final String aggregate;
  final DateTime graceExpiresAt;
  final int refetchRemaining;
  final VoidCallback? onBack;
  final VoidCallback? onClear;

  /// Optional server-issued verification reference (REF: WDX-…).
  final String? reference;

  @override
  State<ResultCanvas> createState() => _ResultCanvasState();
}

class _ResultCanvasState extends State<ResultCanvas> {
  late Duration _remaining;
  bool _cleared = false;

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

  String get _examLabel => switch (widget.examType) {
        ExamType.bece => 'BECE',
        ExamType.wassceSchool => 'WASSCE School',
        ExamType.wasscePrivate => 'WASSCE Private',
      };

  @override
  Widget build(BuildContext context) {
    if (_cleared) return _ClearedCard(onBack: widget.onBack);
    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _NavyResultHeader(
              indexNumber: widget.indexNumber,
              examLabel: _examLabel,
              examYear: widget.examYear,
              candidateName: widget.candidateName,
              onBack: widget.onBack,
            ),
            _VerifiedStrip(reference: widget.reference),
            _GradeTable(grades: widget.grades),
            _SummaryBand(
              subjectCount: widget.grades.length,
              distinctions:
                  widget.grades.where((g) => g.grade == 'A1').length,
              aggregate: widget.aggregate,
              countdown: _countdown,
              refetchRemaining: widget.refetchRemaining,
            ),
            _ActionToolbar(
              onClear: () {
                widget.onClear?.call();
                setState(() => _cleared = true);
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}


/// WAEC grade chip palette (bg / text / border) — port of `gradeColors`.
class GradePalette {
  const GradePalette._();

  static const _map = <String, (Color, Color, Color)>{
    'A1': (Color(0xFFF0FDF9), Color(0xFF00856F), Color(0xFFCCFBF1)),
    'B2': (Color(0xFFEFF6FF), Color(0xFF1D4ED8), Color(0xFFBFDBFE)),
    'B3': (Color(0xFFF0F9FF), Color(0xFF0369A1), Color(0xFFBAE6FD)),
    'C4': (Color(0xFFFFFBEB), Color(0xFF92400E), Color(0xFFFDE68A)),
    'C5': (Color(0xFFFFFBEB), Color(0xFF92400E), Color(0xFFFDE68A)),
    'C6': (Color(0xFFFFF7ED), Color(0xFF9A3412), Color(0xFFFED7AA)),
    'D7': (Color(0xFFFFF7ED), Color(0xFFC2410C), Color(0xFFFFEDD5)),
    'E8': (Color(0xFFFEF2F2), Color(0xFFB91C1C), Color(0xFFFECACA)),
    'F9': (Color(0xFFFEF2F2), Color(0xFF991B1B), Color(0xFFFCA5A5)),
  };

  static (Color bg, Color text, Color border) of(String grade) =>
      _map[grade] ?? _map['C4']!; // unknown grade falls back to CREDIT tone.
}

/// Subject/grade row entry — kept independent of the API payload model.
class SubjectGradeView {
  const SubjectGradeView({
    required this.subject,
    required this.grade,
    this.label,
  });
  final String subject;
  final String grade;

  /// Optional proficiency caption shown beside the grade chip (EXCELLENT…).
  final String? label;
}

/// Navy header: back button, index, exam meta and "Saved Locally" pill.
class _NavyResultHeader extends StatelessWidget {
  const _NavyResultHeader({
    required this.indexNumber,
    required this.examLabel,
    required this.examYear,
    required this.candidateName,
    required this.onBack,
  });

  final String indexNumber;
  final String examLabel;
  final String examYear;
  final String candidateName;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Container(
        color: WaecColors.navy,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: onBack,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: const Color(0x14FFFFFF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new,
                        size: 15, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('OFFICIAL RESULT',
                          style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.4,
                              fontWeight: FontWeight.w500,
                              color: Color(0xCC00D4B1))),
                      const SizedBox(height: 2),
                      Text(indexNumber,
                          style: WaecTheme.monoNum(15, Colors.white)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(examLabel,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    Text('Year $examYear',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0x80FFFFFF))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(candidateName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xB3FFFFFF))),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0x1F00D4B1),
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(color: const Color(0x4000D4B1)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 13, color: WaecColors.mint),
                      SizedBox(width: 6),
                      Text('Saved Locally to Device',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: WaecColors.mint)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

/// White strip: WAEC-verified badge + monospace reference.
class _VerifiedStrip extends StatelessWidget {
  const _VerifiedStrip({this.reference});
  final String? reference;

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 15, color: WaecColors.mint),
                SizedBox(width: 8),
                Text('WAEC Verified Result',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: WaecColors.navy)),
              ],
            ),
            Text(reference ?? 'REF: WAEC-DIRECT',
                style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'JetBrains Mono',
                    letterSpacing: 0.4,
                    color: Color(0xFF94A3B8))),
          ],
        ),
      );
}

/// Subject / grade table card.
class _GradeTable extends StatelessWidget {
  const _GradeTable({required this.grades});
  final List<SubjectGradeView> grades;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                color: const Color(0xFFF8FAFC),
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: Color(0xFFE2E8F0))),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('SUBJECT',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            color: Color(0xFF64748B))),
                    Text('GRADE',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            color: Color(0xFF64748B))),
                  ],
                ),
              ),
              for (var i = 0; i < grades.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    border: i < grades.length - 1
                        ? const Border(
                            bottom: BorderSide(color: Color(0xFFF1F5F9)))
                        : null,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          grades[i].subject.toUpperCase(),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: WaecColors.navy),
                        ),
                      ),
                      _GradeChip(
                          grade: grades[i].grade, label: grades[i].label),
                    ],
                  ),
                ),
              if (grades.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No subjects returned',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFF94A3B8))),
                ),
            ],
          ),
        ),
      );
}

/// Color-coded grade pill.
class _GradeChip extends StatelessWidget {
  const _GradeChip({required this.grade, this.label});
  final String grade;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final (bg, text, border) = GradePalette.of(grade);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      constraints: const BoxConstraints(minWidth: 96),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(grade,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'JetBrains Mono',
                  color: text)),
          if (label != null) ...[
            const SizedBox(width: 6),
            Text(label!,
                style: TextStyle(
                    fontSize: 9, fontWeight: FontWeight.w500, color: text)),
          ],
        ],
      ),
    );
  }
}

/// Overall-performance band with the live grace countdown (§3.5).
class _SummaryBand extends StatelessWidget {
  const _SummaryBand({
    required this.subjectCount,
    required this.distinctions,
    required this.aggregate,
    required this.countdown,
    required this.refetchRemaining,
  });

  final int subjectCount;
  final int distinctions;
  final String aggregate;
  final String countdown;
  final int refetchRemaining;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: WaecColors.navy,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Overall Performance',
                        style: TextStyle(
                            fontSize: 11, color: Color(0x80FFFFFF))),
                    const SizedBox(height: 2),
                    Text('$subjectCount Subjects - $distinctions Distinctions',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    const SizedBox(height: 6),
                    Text(
                        'Free re-fetch window: $countdown - '
                        '$refetchRemaining refetch(es) remaining',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xCC00D4B1))),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x2600D4B1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x4D00D4B1)),
                ),
                child: Column(
                  children: [
                    const Text('Aggregate',
                        style: TextStyle(
                            fontSize: 11, color: WaecColors.mint)),
                    Text(aggregate.isEmpty ? '-' : aggregate,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'JetBrains Mono',
                            color: WaecColors.mint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

/// Export / Clear action buttons.
class _ActionToolbar extends StatelessWidget {
  const _ActionToolbar({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: WaecColors.navy,
                  minimumSize: const Size.fromHeight(50),
                  side: const BorderSide(color: WaecColors.navy, width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Export PDF'),
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Result exported to a secure PDF')),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB91C1C),
                  backgroundColor: const Color(0xFFFEF2F2),
                  minimumSize: const Size.fromHeight(50),
                  side: const BorderSide(color: Color(0xFFFECACA), width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Clear Record'),
                onPressed: onClear,
              ),
            ),
          ],
        ),
      );
}

/// Post-clear confirmation card (Figma's "Record Cleared" state).
class _ClearedCard extends StatelessWidget {
  const _ClearedCard({this.onBack});
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: WaecColors.canvasLight,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.delete_outline,
                          size: 24, color: Color(0xFF94A3B8)),
                    ),
                    const SizedBox(height: 16),
                    const Text('Record Cleared',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: WaecColors.navy)),
                    const SizedBox(height: 8),
                    const Text(
                      'All locally stored result data has been permanently '
                      'erased from this device.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: WaecColors.navy,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(160, 48),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: onBack,
                      child: const Text('Return to Home'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}


