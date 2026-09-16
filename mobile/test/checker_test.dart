// Checker domain unit tests (requirement 2).
//
// Two things are protected here beyond ordinary behaviour:
//   1. Hard Rule 1 — a Checker must never render or log its serial or PIN.
//   2. Fail-closed parsing — an unknown status or exam code must withhold a
//      credential, not offer one.
import 'package:flutter_test/flutter_test.dart';
import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';

Checker _checker({
  String serial = 'WAE123456789',
  String pin = '123456789012',
  CheckerStatus status = CheckerStatus.unused,
  int? expiresAtUnix,
}) => Checker(
  id: 'ck-1',
  serial: serial,
  pin: pin,
  examType: ExamType.wassceSchool.code,
  examYear: '2025',
  status: status,
  purchasedAtUnix: 1700000000,
  expiresAtUnix: expiresAtUnix,
);

void main() {
  group('CheckerValidator', () {
    test('accepts a clean serial', () {
      expect(CheckerValidator.isValidSerial('WAE12345678'), isTrue);
    });

    test('normalises the separators a pasted scratch card carries', () {
      expect(CheckerValidator.normalise('wae 1234-5678'), 'WAE12345678');
      expect(CheckerValidator.isValidSerial('wae 1234-5678'), isTrue);
    });

    test('rejects a serial that is too short or too long', () {
      expect(CheckerValidator.isValidSerial('WAE123'), isFalse);
      expect(CheckerValidator.isValidSerial('W' * 25), isFalse);
    });

    test('rejects empty and whitespace-only input', () {
      expect(CheckerValidator.isValidSerial(''), isFalse);
      expect(CheckerValidator.isValidSerial('   '), isFalse);
      expect(CheckerValidator.validateSerial(''), 'Checker serial required');
      expect(CheckerValidator.validateSerial(null), 'Checker serial required');
    });

    test('reports a format error rather than a required-field error', () {
      expect(
        CheckerValidator.validateSerial('abc'),
        'Serial must be 8-24 letters or digits',
      );
    });

    test('validates the PIN with the same rules', () {
      expect(CheckerValidator.isValidPin('123456789012'), isTrue);
      expect(CheckerValidator.validatePin(''), 'Checker PIN required');
      expect(
        CheckerValidator.validatePin('123'),
        'PIN must be 8-24 letters or digits',
      );
    });

    test('maskSerial reveals only the last four characters', () {
      // 11-character serial -> 7 masked + '5678' visible.
      expect(CheckerValidator.maskSerial('WAE12345678'), '\u2022' * 7 + '5678');
    });

    test('maskSerial fully masks a serial within the visible window', () {
      expect(CheckerValidator.maskSerial('ABCD'), '\u2022' * 4);
      expect(CheckerValidator.maskSerial('AB'), '\u2022' * 2);
    });

    test('maskSerial never returns the input verbatim', () {
      const serial = 'WAE123456789';
      expect(CheckerValidator.maskSerial(serial), isNot(serial));
      expect(CheckerValidator.maskSerial(serial).contains(serial), isFalse);
    });
  });

  group('CheckerStatus', () {
    test('only an unused checker is redeemable', () {
      expect(CheckerStatus.unused.isRedeemable, isTrue);
      expect(CheckerStatus.redeemed.isRedeemable, isFalse);
      expect(CheckerStatus.expired.isRedeemable, isFalse);
    });

    test('round-trips its own wire names', () {
      for (final s in CheckerStatus.values) {
        expect(CheckerStatus.fromWire(s.name), s);
      }
    });

    test('an unknown wire value fails closed to expired', () {
      expect(CheckerStatus.fromWire('used-up'), CheckerStatus.expired);
      expect(CheckerStatus.fromWire(null), CheckerStatus.expired);
      expect(CheckerStatus.fromWire(''), CheckerStatus.expired);
    });

    test('carries a display name for the history chip', () {
      expect(CheckerStatus.unused.displayName, 'Unused');
      expect(CheckerStatus.redeemed.displayName, 'Used');
      expect(CheckerStatus.expired.displayName, 'Expired');
    });
  });

  group('Checker', () {
    test('is redeemable only while unused', () {
      expect(_checker().isRedeemable, isTrue);
      expect(_checker(status: CheckerStatus.redeemed).isRedeemable, isFalse);
    });

    test('exposes a masked serial, never the raw one', () {
      final c = _checker();
      expect(c.maskedSerial, isNot(c.serial));
      expect(c.maskedSerial.endsWith('6789'), isTrue);
      expect(c.maskedSerial.contains(c.serial), isFalse);
    });

    // Hard Rule 1: an accidental print() or a crash-report expansion of a
    // Checker must not be able to leak the credential.
    test('toString leaks neither the serial nor the PIN', () {
      final c = _checker(serial: 'SERIAL12345', pin: 'PIN987654321');
      final text = c.toString();
      expect(text.contains('SERIAL12345'), isFalse);
      expect(text.contains('PIN987654321'), isFalse);
      expect(text.contains(c.id), isTrue);
      expect(text.contains('unused'), isTrue);
    });

    test('isExpiredAt honours an attached deadline', () {
      final c = _checker(expiresAtUnix: 2000);
      expect(c.isExpiredAt(1999), isFalse);
      expect(c.isExpiredAt(2000), isTrue);
    });

    test('isExpiredAt is true for an expired row regardless of deadline', () {
      expect(_checker(status: CheckerStatus.expired).isExpiredAt(0), isTrue);
    });

    test('isExpiredAt is false when there is no deadline', () {
      expect(_checker().isExpiredAt(9999999999), isFalse);
    });

    test('copyWith changes status but preserves the credential', () {
      final redeemed = _checker().copyWith(
        status: CheckerStatus.redeemed,
        redeemedAtUnix: 42,
      );
      expect(redeemed.status, CheckerStatus.redeemed);
      expect(redeemed.redeemedAtUnix, 42);
      expect(redeemed.serial, 'WAE123456789');
      expect(redeemed.pin, '123456789012');
      expect(redeemed.id, 'ck-1');
    });
  });

  group('ExamType.fromCode', () {
    test('round-trips every code', () {
      for (final t in ExamType.values) {
        expect(ExamType.fromCode(t.code), t);
      }
    });

    test('degrades an unknown code instead of throwing', () {
      expect(ExamType.fromCode('JAMB'), ExamType.bece);
      expect(ExamType.fromCode(null), ExamType.bece);
    });
  });

  group('ChargeInit voucher fields', () {
    ChargeInit withPairs(String s, String p) => ChargeInit(
      transactionId: 'tx-1',
      status: 'pending',
      amountPesewas: 2000,
      checkoutUrl: '',
      displayMessage: '',
      checkerSerial: s,
      checkerPin: p,
    );

    test('hasChecker is false when the charge carried no voucher', () {
      const init = ChargeInit(
        transactionId: 'tx-1',
        status: 'pending',
        amountPesewas: 2000,
        checkoutUrl: 'https://pay',
        displayMessage: 'Approve',
      );
      expect(init.hasChecker, isFalse);
    });

    test('hasChecker needs both halves of the credential', () {
      expect(withPairs('WAE12345678', '').hasChecker, isFalse);
      expect(withPairs('', '123456789012').hasChecker, isFalse);
      expect(withPairs('WAE12345678', '123456789012').hasChecker, isTrue);
    });
  });

  group('CheckerRedemption', () {
    test('reports acceptance for every status but failed', () {
      expect(
        const CheckerRedemption(
          transactionId: 'tx',
          status: 'pending',
          displayMessage: '',
        ).isAccepted,
        isTrue,
      );
      expect(
        const CheckerRedemption(
          transactionId: 'tx',
          status: 'failed',
          displayMessage: '',
        ).isAccepted,
        isFalse,
      );
    });
  });

  group('CheckerException', () {
    test('toString carries the kind but not the message', () {
      const e = CheckerException(
        CheckerFailureKind.checkerRejected,
        'WAEC rejected this checker.',
      );
      expect(e.toString(), 'CheckerException(checkerRejected)');
      expect(e.toString().contains('WAEC rejected'), isFalse);
    });

    test('only unreachable counts as a network failure', () {
      expect(
        const CheckerException(CheckerFailureKind.unreachable, '').isNetworkFailure,
        isTrue,
      );
      expect(
        const CheckerException(CheckerFailureKind.checkerRejected, '')
            .isNetworkFailure,
        isFalse,
      );
    });
  });
}