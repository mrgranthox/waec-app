import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'result_canvas.dart';

/// Client-side PDF export — plan §3.10.
///
/// "Files generated client-side; no upload." The [pdf] package renders
/// fully offline; the bytes are handed back for saving/sharing.
class ResultPdfExporter {
  Future<List<int>> export({
    required String candidateName,
    required String indexNumber,
    required String examType,
    required String examYear,
    required List<SubjectGradeView> grades,
    required String aggregate,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('WEST AFRICAN EXAMINATIONS COUNCIL',
                style: pw.TextStyle(
                    fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Text(examType, style: const pw.TextStyle(fontSize: 12)),
            pw.SizedBox(height: 16),
            _kv('Candidate', candidateName),
            _kv('Index number', indexNumber),
            _kv('Exam year', examYear),
            pw.SizedBox(height: 12),
            pw.TableHelper.fromTextArray(
              headers: ['Subject', 'Grade'],
              data: grades.map((g) => [g.subject, g.grade]).toList(),
              headerStyle:
                  pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
            if (aggregate.isNotEmpty) _kv('Aggregate', aggregate),
            pw.SizedBox(height: 24),
            pw.Text('Generated offline by WAEC Direct — no upload.',
                style: const pw.TextStyle(fontSize: 8)),
          ],
        ),
      ),
    );
    return doc.save();
  }

  static pw.Widget _kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(k, style: const pw.TextStyle(fontSize: 10)),
            pw.Text(v,
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)),
          ],
        ),
      );
}
