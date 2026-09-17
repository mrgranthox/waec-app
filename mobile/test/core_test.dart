import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/core/design_tokens.dart';
import 'package:waec_direct/core/api_client.dart';

void main() {
  group('Core domain types', () {
    group('ExamType', () {
      test('all exam types have non-empty code and display name', () {
        for (final t in ExamType.values) {
          expect(t.code, isNotEmpty);
          expect(t.displayName, isNotEmpty);
        }
      });

      test('fromCode returns known type for valid code', () {
        expect(ExamType.fromCode('BECE'), equals(ExamType.bece));
        expect(ExamType.fromCode('WASSCE_SC'), equals(ExamType.wassceSchool));
        expect(
          ExamType.fromCode('WASSCE_PRIVATE'),
          equals(ExamType.wasscePrivate),
        );
      });

      test('fromCode falls back to bece for unknown code', () {
        expect(ExamType.fromCode('NOPE'), equals(ExamType.bece));
        expect(ExamType.fromCode(null), equals(ExamType.bece));
      });
    });

    group('Exam years', () {
      test('extends back to 1948, the founding of WAEC', () {
        expect(kExamYears.first, equals('2026'));
        expect(kExamYears.last, equals('1948'));
        expect(kExamYears, contains('1948'));
      });

      test('is contiguous and descending', () {
        for (var i = 0; i < kExamYears.length - 1; i++) {
          final cur = int.parse(kExamYears[i]);
          final next = int.parse(kExamYears[i + 1]);
          expect(
            cur,
            equals(next + 1),
            reason:
                '${kExamYears[i]} should be one more than ${kExamYears[i + 1]}',
          );
        }
      });

      test('kDefaultExamYear is the most recent', () {
        expect(kDefaultExamYear, equals(kExamYears.first));
      });

      test('kExamYearFloor matches the last year', () {
        expect(kExamYearFloor, equals(1948));
        expect(int.parse(kExamYears.last), equals(kExamYearFloor));
      });
    });

    group('validateExamYear', () {
      test('accepts a year within range', () {
        expect(validateExamYear('2024'), isNull);
        expect(validateExamYear('1948'), isNull);
        expect(validateExamYear('2005'), isNull);
      });

      test('rejects years before 1948', () {
        expect(validateExamYear('1947'), isNotEmpty);
        expect(validateExamYear('1900'), isNotEmpty);
        expect(validateExamYear('0'), isNotEmpty);
      });

      test('rejects future years', () {
        final future = DateTime.now().year + 1;
        expect(validateExamYear('$future'), isNotEmpty);
      });

      test('rejects non-numeric input', () {
        expect(validateExamYear('abc'), isNotEmpty);
        expect(validateExamYear('2024x'), isNotEmpty);
      });

      test('rejects empty input', () {
        expect(validateExamYear(''), isNotEmpty);
        expect(validateExamYear(null), isNotEmpty);
      });
    });

    group('TransactionStage', () {
      test('terminal stages are marked', () {
        expect(TransactionStage.complete.isTerminal, isTrue);
        expect(TransactionStage.failed.isTerminal, isTrue);
        expect(TransactionStage.paymentConfirmation.isTerminal, isFalse);
        expect(TransactionStage.voucherProvisioning.isTerminal, isFalse);
        expect(TransactionStage.waecRetrieval.isTerminal, isFalse);
      });
    });

    group('IndexNumberValidator', () {
      test('validates 10-digit strings', () {
        expect(IndexNumberValidator.isValid('1234567890'), isTrue);
        expect(IndexNumberValidator.isValid('0000000000'), isTrue);
        expect(IndexNumberValidator.isValid('9999999999'), isTrue);
      });

      test('rejects short, long, and non-digit input', () {
        expect(IndexNumberValidator.isValid('123456789'), isFalse);
        expect(IndexNumberValidator.isValid('12345678901'), isFalse);
        expect(IndexNumberValidator.isValid('123456789a'), isFalse);
        expect(IndexNumberValidator.isValid(''), isFalse);
        expect(IndexNumberValidator.isValid('   '), isFalse);
      });

      test('validate returns helpful messages', () {
        expect(
          IndexNumberValidator.validate(''),
          equals('Index number required'),
        );
        expect(
          IndexNumberValidator.validate('123'),
          equals('Must be exactly 10 digits'),
        );
        expect(IndexNumberValidator.validate('1234567890'), isNull);
      });
    });

    group('CheckerValidator', () {
      test('accepts well-formed serials', () {
        expect(CheckerValidator.isValidSerial('123456789012345678'), isTrue);
        expect(CheckerValidator.isValidSerial('ABCDEFGHIJKLMNOP'), isTrue);
      });

      test('rejects short or blank serials', () {
        expect(CheckerValidator.isValidSerial(''), isFalse);
        expect(CheckerValidator.isValidSerial('short'), isFalse);
      });

      test('accepts well-formed PINs', () {
        expect(CheckerValidator.isValidPin('12345678'), isTrue);
        expect(CheckerValidator.isValidPin('ABCDEFGH'), isTrue);
        expect(CheckerValidator.isValidPin('Ab12Cd34'), isTrue);
      });

      test('rejects PINs outside length bounds', () {
        expect(CheckerValidator.isValidPin('1234567'), isFalse);
        expect(
          CheckerValidator.isValidPin('1234567890123456789012345'),
          isFalse,
        );
      });

      test('maskSerial hides all but last 4 chars', () {
        expect(
          CheckerValidator.maskSerial('ABCDEFGHIJ'),
          equals('\u2022\u2022\u2022\u2022\u2022\u2022GHIJ'),
        );
        expect(
          CheckerValidator.maskSerial('ABC'),
          equals('\u2022\u2022\u2022'),
        );
      });
    });

    group('Design tokens', () {
      test('WaecColors defines all brand tokens', () {
        expect(WaecColors.navy, isA<Color>());
        expect(WaecColors.mint, isA<Color>());
        expect(WaecColors.canvasLight, isA<Color>());
        expect(WaecColors.canvasDark, isA<Color>());
        expect(WaecColors.success, isA<Color>());
        expect(WaecColors.warning, isA<Color>());
        expect(WaecColors.danger, isA<Color>());
      });

      test('WaecSpacing is a 4pt grid', () {
        expect(WaecSpacing.xs.toInt() % 4, equals(0));
        expect(WaecSpacing.sm.toInt() % 4, equals(0));
        expect(WaecSpacing.md.toInt() % 4, equals(0));
        expect(WaecSpacing.lg.toInt() % 4, equals(0));
        expect(WaecSpacing.xl.toInt() % 4, equals(0));
        expect(WaecSpacing.xxl.toInt() % 4, equals(0));
      });

      test('WaecRadii is sane', () {
        expect(WaecRadii.sm, lessThan(WaecRadii.md));
        expect(WaecRadii.md, lessThan(WaecRadii.lg));
        expect(WaecRadii.lg, lessThan(WaecRadii.pill));
      });
    });

    group('CheckerStatus', () {
      test('isRedeemable reflects correct subset', () {
        expect(CheckerStatus.unused.isRedeemable, isTrue);
        expect(CheckerStatus.redeemed.isRedeemable, isFalse);
        expect(CheckerStatus.expired.isRedeemable, isFalse);
      });
    });

    group('Checker', () {
      test('isExpiredAt respects explicit expiry', () {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final checker = Checker(
          id: 'c1',
          serial: 'SER12345678',
          pin: '12345678',
          examType: 'BECE',
          examYear: '2024',
          status: CheckerStatus.unused,
          purchasedAtUnix: now - 1000,
          expiresAtUnix: now - 100, // already expired
        );
        expect(checker.isExpiredAt(now), isTrue);

        final fresh = Checker(
          id: 'c2',
          serial: 'SER12345678',
          pin: '12345678',
          examType: 'BECE',
          examYear: '2024',
          status: CheckerStatus.unused,
          purchasedAtUnix: now - 1000,
          expiresAtUnix: now + 1000, // not yet expired
        );
        expect(fresh.isExpiredAt(now), isFalse);
      });

      test('maskedSerial is safe to render', () {
        final checker = Checker(
          id: 'c1',
          serial: 'ABCDEFGHIJKLMNOPQRST',
          pin: '12345678',
          examType: 'BECE',
          examYear: '2024',
          status: CheckerStatus.unused,
          purchasedAtUnix: 1000,
        );
        // toString must never include the serial or pin.
        final str = checker.toString();
        expect(str, isNot(contains('ABCDEFGHIJKLMNOPQRST')));
        expect(str, isNot(contains('12345678')));
        expect(str, contains('c1'));
        expect(str, contains('BECE'));
        expect(str, contains('2024'));
      });

      test('copyWith preserves fields', () {
        const original = Checker(
          id: 'c1',
          serial: 'SER12345678',
          pin: '12345678',
          examType: 'BECE',
          examYear: '2024',
          status: CheckerStatus.unused,
          purchasedAtUnix: 1000,
        );
        final updated = original.copyWith(status: CheckerStatus.redeemed);
        expect(updated.id, equals(original.id));
        expect(updated.serial, equals(original.serial));
        expect(updated.pin, equals(original.pin));
        expect(updated.status, equals(CheckerStatus.redeemed));
      });
    });

    group('Price model', () {
      test('display formats as currency', () {
        expect(
          const Price(amountPesewas: 2000, currency: 'GHS').display,
          equals('GHS 20.00'),
        );
        expect(
          const Price(amountPesewas: 1500, currency: 'GHS').display,
          equals('GHS 15.00'),
        );
        expect(
          const Price(amountPesewas: 50, currency: 'GHS').display,
          equals('GHS 0.50'),
        );
      });

      test('display falls back to GHS 20.00 for non-positive amount', () {
        expect(
          const Price(amountPesewas: 0, currency: 'GHS').display,
          equals('GHS 20.00'),
        );
        expect(
          const Price(amountPesewas: -100, currency: 'GHS').display,
          equals('GHS 20.00'),
        );
      });
    });

    group('AuthFailureKind', () {
      test('isNetworkFailure is true only for unreachable', () {
        expect(AuthFailureKind.unreachable.isNetworkFailure, isTrue);
        expect(AuthFailureKind.invalidCredentials.isNetworkFailure, isFalse);
        expect(AuthFailureKind.accountLocked.isNetworkFailure, isFalse);
        expect(AuthFailureKind.unknown.isNetworkFailure, isFalse);
      });
    });

    group('CheckerFailureKind', () {
      test('isNetworkFailure is true only for unreachable', () {
        expect(CheckerFailureKind.unreachable.isNetworkFailure, isTrue);
        expect(CheckerFailureKind.checkerRejected.isNetworkFailure, isFalse);
        expect(CheckerFailureKind.unknown.isNetworkFailure, isFalse);
      });
    });

    group('AuthException', () {
      test('toString never contains the message', () {
        const e = AuthException(
          AuthFailureKind.invalidCredentials,
          'Wrong password',
        );
        expect(e.toString(), equals('AuthException(invalidCredentials)'));
        expect(e.toString(), isNot(contains('Wrong password')));
      });
    });

    group('CheckerException', () {
      test('toString never contains the message', () {
        const e = CheckerException(
          CheckerFailureKind.checkerRejected,
          'Bad PIN',
        );
        expect(e.toString(), equals('CheckerException(checkerRejected)'));
        expect(e.toString(), isNot(contains('Bad PIN')));
      });
    });
  });
}
