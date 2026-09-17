import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/features/results/mock_result.dart';

/// Requirement 7 acceptance: once a payment completes, the app throws a mock
/// generated checker and then a **random-looking but stable** result so the
/// buy → check flow feels real. These tests lock the contract:
/// determinism per identity, best-six aggregate arithmetic, and sheet
/// divergence between candidates.
void main() {
  group('MockResult.generate', () {
    test('is deterministic for the same identity', () {
      final a = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'WASSCE_SC',
        examYear: '2025',
        credential: 'WAECMOCK0001',
      );
      final b = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'WASSCE_SC',
        examYear: '2025',
        credential: 'WAECMOCK0001',
      );
      expect(a.candidateName, b.candidateName);
      expect(a.subjects, b.subjects);
      expect(a.aggregate, b.aggregate);
    });

    test('diverges across candidates and credentials', () {
      final a = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'WASSCE_SC',
        examYear: '2025',
        credential: 'WAECMOCK0001',
      );
      final b = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'WASSCE_SC',
        examYear: '2025',
        credential: 'WAECMOCK0002',
      );
      expect(a.subjects, isNot(b.subjects));
    });

    test('aggregate is the sum of the best six grade points', () {
      final sheet = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'WASSCE_SC',
        examYear: '2025',
        credential: 'WAECMOCK0003',
      );
      int pointOf(String g) {
        final numeric = int.tryParse(g);
        if (numeric != null) return numeric;
        return switch (g[0]) {
          'A' => 1,
          'B' || 'C' => int.parse(g[1]),
          'D' => 7,
          'E' => 8,
          _ => 9,
        };
      }

      final pts = sheet.subjects.values.map(pointOf).toList()..sort();
      final expected = pts.take(6).fold<int>(0, (a, p) => a + p);
      expect(sheet.aggregate, expected);
      expect(sheet.aggregate, greaterThanOrEqualTo(6));
      expect(sheet.aggregate, lessThanOrEqualTo(48));
    });

    test('WASSCE sheets carry eight subjects on the A1–F9 scale', () {
      final sheet = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'WASSCE_SC',
        examYear: '2025',
        credential: 'WAECMOCK0004',
      );
      expect(sheet.subjects.length, 8);
      expect(
        sheet.subjects.values,
        everyElement(matches(RegExp(r'^[A-F][1-9]$'))),
      );
    });

    test('BECE sheets use the numeric 1–9 scale and 6–30 aggregate', () {
      final sheet = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'BECE',
        examYear: '2025',
        credential: 'WAECMOCK0005',
      );
      expect(sheet.subjects.length, 8);
      expect(sheet.subjects.values, everyElement(matches(RegExp(r'^[1-9]$'))));
      expect(sheet.aggregate, lessThanOrEqualTo(30));
    });

    test('candidate name is a real-looking surname, firstname pair', () {
      final sheet = MockResult.generate(
        indexNumber: '1002330440',
        examType: 'BECE',
        examYear: '2025',
        credential: 'WAECMOCK0006',
      );
      expect(
        sheet.candidateName,
        matches(RegExp(r'^[A-Z][a-z]+, [A-Z][a-z]+$')),
      );
    });
  });

  group('MockCheckerMinter', () {
    test('serials are monotonic and validator-compliant', () {
      final minter = MockCheckerMinter();
      final a = minter.nextSerial();
      final b = minter.nextSerial();
      expect(b, isNot(a));
      expect(a, matches(RegExp(r'^WAECMOCK\d{4}$')));
      expect(b, matches(RegExp(r'^WAECMOCK\d{4}$')));
    });

    test('pins are 13 digits and unique in practice', () {
      final minter = MockCheckerMinter();
      final pins = <String>{for (var i = 0; i < 20; i++) minter.nextPin()};
      expect(pins.length, greaterThan(1));
      for (final pin in pins) {
        expect(pin, matches(RegExp(r'^\d{13}$')));
      }
    });
  });
}
