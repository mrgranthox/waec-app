import 'dart:math';

/// Test-phase result generator (local dev requirement 7).
///
/// Once a payment completes we throw a **mock generated checker**, and when
/// that checker is spent the app must show a result that **looks real**. This
/// module fabricates one — deterministically.
///
/// ## Why deterministic rather than random-on-every-call
///
/// A real WAEC result never changes between re-fetches. Deriving the grade
/// sheet from a stable seed (index number + exam + year + credential serial)
/// means the same retrieval always shows the same sheet — re-opening the
/// result from History shows the same grades — while different candidates and
/// different credentials get unrelated sheets. Pure random would fail the
/// "looks real" bar on the second open.
///
/// ## Production boundary
///
/// This is a local-test-phase seam only. In production the grades come from
/// the Handler service's `FetchResult` pipeline; this generator is never
/// compiled into that path — callers gate it behind the mock/dev API. It never
/// touches the network and never persists anything.
class MockResult {
  const MockResult({
    required this.candidateName,
    required this.subjects,
    required this.aggregate,
    required this.examYear,
  });

  /// Parsed candidate name (surname, first name) derived from the seed.
  final String candidateName;

  /// Subject → grade code. BECE uses the 1–9 numeric scale (1 best),
  /// WASSCE uses A1–F9.
  final Map<String, String> subjects;

  /// Sum of the best six grade points. BECE range 6–30, WASSCE 6–48.
  final int aggregate;

  final String examYear;

  // ── Generators ────────────────────────────────────────────────────────────

  /// Builds a full mock result sheet from stable inputs.
  ///
  /// [credential] is the checker serial (or transaction id) — including it in
  /// the seed means two candidates cannot collide on one sheet.
  factory MockResult.generate({
    required String indexNumber,
    required String examType,
    required String examYear,
    required String credential,
  }) {
    final rng = Random(_seed(indexNumber, examType, examYear, credential));
    final isBece = examType.toUpperCase().contains('BECE');

    final surnames = const <String>[
      'Mensah',
      'Owusu',
      'Boateng',
      'Asante',
      'Amoah',
      'Addai',
      'Darko',
      'Osei',
      'Quartey',
      'Tetteh',
      'Danso',
      'Agyeman',
      'Nkrumah',
      'Appiah',
    ];
    final firstNames = const <String>[
      'Kwame',
      'Ama',
      'Kofi',
      'Akosua',
      'Yaw',
      'Abena',
      'Kojo',
      'Adwoa',
      'Kwabena',
      'Afia',
      'Yaw',
      'Esi',
      'Kwasi',
      'Nana',
    ];

    // Grade pools pass-heavy, like a real cohort distribution.
    final beceGrades = const <String>[
      '1',
      '2',
      '2',
      '3',
      '3',
      '4',
      '4',
      '5',
      '6',
      '7',
    ];
    final wassceGrades = const <String>[
      'A1',
      'B2',
      'B2',
      'B3',
      'B3',
      'C4',
      'C4',
      'C5',
      'C6',
      'C6',
      'D7',
      'E8',
    ];

    final subjects = <String>[
      'English Language',
      'Mathematics',
      'Integrated Science',
      'Social Studies',
      if (!isBece) ...<String>[
        'Elective Mathematics',
        'Physics',
        'Chemistry',
        'Biology',
      ] else ...<String>[
        'Religious & Moral Education',
        'ICT',
        'Ghanaian Language',
        'French',
      ],
    ];

    final sheet = <String, String>{};
    for (final subject in subjects) {
      sheet[subject] = isBece
          ? beceGrades[rng.nextInt(beceGrades.length)]
          : wassceGrades[rng.nextInt(wassceGrades.length)];
    }

    // Aggregate = the standard "best six" sum (BECE 1–9 numeric scale,
    // WASSCE A1=1 through F9=9).
    int pointOf(String g) {
      final numeric = int.tryParse(g);
      if (numeric != null) return numeric;
      return switch (g[0]) {
        'A' => 1,
        'B' || 'C' => int.parse(g[1]),
        'D' => 7,
        'E' => 8,
        _ => 9, // F9
      };
    }

    final points = sheet.values.map(pointOf).toList()..sort();
    final bestSix = points.length > 6 ? points.sublist(0, 6) : points;
    final aggregate = bestSix.fold<int>(0, (a, p) => a + p);

    return MockResult(
      candidateName:
          '${surnames[rng.nextInt(surnames.length)]}, '
          '${firstNames[rng.nextInt(firstNames.length)]}',
      subjects: Map<String, String>.unmodifiable(sheet),
      aggregate: aggregate,
      examYear: examYear,
    );
  }

  /// FNV-1a over every input string — stable across runs and platforms.
  static int _seed(String index, String exam, String year, String credential) {
    var hash = 0x811c9dc5;
    for (final part in <String>[index, exam, year, credential]) {
      for (final code in part.codeUnits) {
        hash ^= code & 0xff;
        hash = (hash * 0x01000193) & 0xFFFFFFFF;
        hash ^= (code >> 8) & 0xff;
        hash = (hash * 0x01000193) & 0xFFFFFFFF;
      }
    }
    return hash;
  }
}

/// Test-phase checker minter (local dev requirement 7) — formats that pass
/// [CheckerValidator]: 8–24 uppercase letters/digits for both credential
/// halves.
///
/// Serials are monotonically numbered under a fixed prefix so a dev tester can
/// read provenance off the screen; PINs are random digits. Mirrors the backend
/// `waec-payment` mock minter's contract.
class MockCheckerMinter {
  MockCheckerMinter({Random? rng}) : _rng = rng ?? Random.secure();

  final Random _rng;
  int _serialCounter = 0;

  /// Mints the next serial: `WAECMOCK` + 4-digit counter (matches the dev
  /// gateway format the rest of the tests already assert on).
  String nextSerial() =>
      'WAECMOCK${(++_serialCounter).toString().padLeft(4, '0')}';

  /// Mints a random 13-digit PIN (WAEC-style).
  String nextPin() =>
      List<String>.generate(13, (_) => '${_rng.nextInt(10)}').join();
}
