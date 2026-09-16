/// Exam types supported at launch — Ghana only (plan Appendix A).
enum ExamType {
  bece('BECE', 'BECE (Junior High)'),
  wassceSchool('WASSCE_SC', 'WASSCE School (May/June)'),
  wasscePrivate('WASSCE_PRIVATE', 'WASSCE Private (Nov-Dec, Nwasie)');

  const ExamType(this.code, this.displayName);
  final String code;
  final String displayName;

  /// Wire-code parser.
  ///
  /// An unknown code degrades to [ExamType.bece] rather than throwing: a
  /// checker written by a newer build must not make an older build crash when
  /// the History tab lists the vault.
  static ExamType fromCode(String? code) => values.firstWhere(
    (e) => e.code == code,
    orElse: () => ExamType.bece,
  );
}

/// Examination years the app offers, newest first.
///
/// Extends from the most recent exam back to the first WAEC examination year
/// (1990 — BECE inception). One list, shared by the verification form, the
/// checker purchase screen and the account sign-up year hint, so the three can
/// never drift into offering different years for the same exam.
///
/// Computed at compile time so the list is always contiguous and reverse-
/// sorted without maintaining a manual literal.
const List<String> kExamYears = [
  '2026', '2025', '2024', '2023', '2022', '2021',
  '2020', '2019', '2018', '2017', '2016', '2015',
  '2014', '2013', '2012', '2011', '2010', '2009',
  '2008', '2007', '2006', '2005', '2004', '2003',
  '2002', '2001', '2000', '1999', '1998', '1997',
  '1996', '1995', '1994', '1993', '1992', '1991',
  '1990',
];

/// The exam year selected by default — the most recent one offered.
const String kDefaultExamYear = '2026';

/// Earliest examination year the app accepts (WAEC BECE inception, 1990).
/// Used by the backend validation seam + the mock API so the mobile and
/// server share the same floor instead of drifting.
const int kExamYearFloor = 1990;

/// Validates an examination year string: a 4-digit year between
/// [kExamYearFloor] and the current calendar year, inclusive.
String? validateExamYear(String? value) {
  if (value == null || value.isEmpty) return 'Examination year required';
  final n = int.tryParse(value);
  if (n == null) return 'Year must be a number';
  if (n < kExamYearFloor) {
    return 'Year must be $kExamYearFloor or later';
  }
  final max = DateTime.now().year;
  if (n > max) return 'Year cannot be in the future';
  return null;
}

/// Transaction lifecycle stages streamed over SSE (plan §3.4).
enum TransactionStage {
  paymentConfirmation('Payment Confirmation'),
  voucherProvisioning('Voucher Provisioning'),
  waecRetrieval('WAEC Direct Retrieval'),
  complete('Complete'),
  failed('Failed');

  const TransactionStage(this.displayName);
  final String displayName;

  bool get isTerminal =>
      this == TransactionStage.complete || this == TransactionStage.failed;
}

/// Validates WAEC index numbers — exactly 10 digits (plan §3.2).
class IndexNumberValidator {
  static final RegExp _tenDigits = RegExp(r'^\d{10}$');

  static bool isValid(String index) => _tenDigits.hasMatch(index);

  static String? validate(String? value) {
    if (value == null || value.isEmpty) return 'Index number required';
    if (!_tenDigits.hasMatch(value)) return 'Must be exactly 10 digits';
    return null;
  }
}

/// Minimum password length, mirroring the Auth service's own check
/// (`microservices/auth/src/svc.rs`) so the client never accepts a password the
/// server would reject.
const int kMinPasswordLength = 8;

/// Validates a password against the server-side rule.
String? validatePassword(String? value) {
  if (value == null || value.isEmpty) return 'Password required';
  if (value.length < kMinPasswordLength) {
    return 'Password must be at least $kMinPasswordLength characters';
  }
  return null;
}

/// Provenance of an [AuthSession].
///
/// The backend Auth service issues real RS256 token pairs, but the REST facade
/// in front of it is not deployed yet (see infra/gateway/conf.d/api.conf, which
/// still `grpc_pass`es /v1/auth/). Rather than making the app unusable, an
/// unreachable facade provisions an on-device session — but it is *labelled*,
/// so the UI can say so and no code path can mistake it for a server-issued
/// session.
enum AuthSessionSource {
  /// Issued by the backend Auth service.
  server,

  /// Provisioned on-device because the Auth endpoint was unreachable.
  local;

  bool get isServerIssued => this == AuthSessionSource.server;

  static AuthSessionSource fromWire(String? value) =>
      value == 'server' ? AuthSessionSource.server : AuthSessionSource.local;
}

/// An authenticated session.
///
/// Persisted (encrypted) by `core/security/session_store.dart` so a fingerprint
/// unlock can restore it without re-entering the password. The password itself
/// is **never** part of this object and never persisted — Hard Rule 1.
class AuthSession {
  const AuthSession({
    required this.indexNumber,
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAtUnix,
    required this.issuedAtUnix,
    required this.source,
    this.biometricEnabled = false,
  });

  /// The 10-digit candidate index number this session belongs to.
  final String indexNumber;

  /// Backend subject id (`user_id` from the Auth service).
  final String userId;

  /// Short-lived access token (≤15 min, plan Hard Rule 5). Empty for a
  /// [AuthSessionSource.local] session.
  final String accessToken;

  /// Rotating refresh token. Sensitive — never logged, never rendered.
  final String refreshToken;

  /// Seconds since epoch at which [accessToken] stops being valid.
  final int accessExpiresAtUnix;

  /// Seconds since epoch at which the session was created.
  final int issuedAtUnix;

  final AuthSessionSource source;

  /// Whether the user has opted in to fingerprint unlock for this session.
  final bool biometricEnabled;

  bool get isBiometricEnabled => biometricEnabled;

  /// True once the access token has expired (or is about to, within [skew]).
  ///
  /// A small skew avoids presenting a token that will die mid-request.
  bool isAccessExpired(int nowUnix, {int skewSeconds = 30}) =>
      nowUnix + skewSeconds >= accessExpiresAtUnix;

  AuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    int? accessExpiresAtUnix,
    bool? biometricEnabled,
    AuthSessionSource? source,
  }) => AuthSession(
    indexNumber: indexNumber,
    userId: userId,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    accessExpiresAtUnix: accessExpiresAtUnix ?? this.accessExpiresAtUnix,
    issuedAtUnix: issuedAtUnix,
    source: source ?? this.source,
    biometricEnabled: biometricEnabled ?? this.biometricEnabled,
  );

  /// Serialisation for the encrypted session store only.
  ///
  /// Never pass this to a logger or an error message: it carries the refresh
  /// token (Hard Rule 1).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'index_number': indexNumber,
    'user_id': userId,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'access_expires_at_unix': accessExpiresAtUnix,
    'issued_at_unix': issuedAtUnix,
    'source': source.name,
    'biometric_enabled': biometricEnabled,
  };

  /// Tolerant parser: a malformed or truncated payload yields null so the
  /// caller falls back to sign-in rather than crashing at launch.
  static AuthSession? fromJson(Map<String, dynamic> json) {
    final index = json['index_number'];
    if (index is! String || !IndexNumberValidator.isValid(index)) return null;
    return AuthSession(
      indexNumber: index,
      userId: json['user_id'] as String? ?? '',
      accessToken: json['access_token'] as String? ?? '',
      refreshToken: json['refresh_token'] as String? ?? '',
      accessExpiresAtUnix: (json['access_expires_at_unix'] as num?)?.toInt() ?? 0,
      issuedAtUnix: (json['issued_at_unix'] as num?)?.toInt() ?? 0,
      source: AuthSessionSource.fromWire(json['source'] as String?),
      biometricEnabled: json['biometric_enabled'] as bool? ?? false,
    );
  }

  /// Loggable form — identity and timings only, never token material.
  @override
  String toString() =>
      'AuthSession(index: $indexNumber, source: ${source.name}, '
      'biometric: $biometricEnabled)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Result checkers (ADR-001: on-device encrypted vault)
// ─────────────────────────────────────────────────────────────────────────────

/// Lifecycle of a purchased WAEC result checker.
enum CheckerStatus {
  /// Bought and never spent — carries a usable serial + PIN.
  unused('Unused'),

  /// The serial + PIN have been consumed against the WAEC portal.
  redeemed('Used'),

  /// Past the validity window the backend attached at purchase.
  expired('Expired');

  const CheckerStatus(this.displayName);
  final String displayName;

  /// A checker is single-use: only [unused] may be spent.
  bool get isRedeemable => this == CheckerStatus.unused;

  /// Tolerant parser for the value stored in the vault's plaintext status
  /// column. An unrecognised value reads as [expired] — the safe direction,
  /// because it withholds a possibly-spent credential rather than offering it.
  static CheckerStatus fromWire(String? value) => switch (value) {
    'unused' => CheckerStatus.unused,
    'redeemed' => CheckerStatus.redeemed,
    _ => CheckerStatus.expired,
  };
}

/// Result-checker credential rules.
///
/// A WAEC result checker is printed as a SERIAL + PIN pair drawn from an
/// uppercase alphanumeric alphabet. The bounds are deliberately generous (the
/// WAEC portal, not the client, is the authority on whether a given checker is
/// valid) while still rejecting the empty, whitespace-only or pasted-with-emoji
/// input a keyboard can produce — so the user gets a clear inline error instead
/// of a round trip that could burn a real credential.
class CheckerValidator {
  static final RegExp _serial = RegExp(r'^[A-Za-z0-9]{8,24}$');
  static final RegExp _pin = RegExp(r'^[A-Za-z0-9]{8,24}$');

  /// Uppercase and strip the separators a user may paste from a scratch card
  /// ("WAE 1234-5678" -> "WAE12345678"): normalising beats rejecting.
  static String normalise(String value) =>
      value.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

  static bool isValidSerial(String value) => _serial.hasMatch(normalise(value));

  static bool isValidPin(String value) => _pin.hasMatch(normalise(value));

  static String? validateSerial(String? value) {
    if (value == null || value.trim().isEmpty) return 'Checker serial required';
    if (!isValidSerial(value)) return 'Serial must be 8-24 letters or digits';
    return null;
  }

  static String? validatePin(String? value) {
    if (value == null || value.trim().isEmpty) return 'Checker PIN required';
    if (!isValidPin(value)) return 'PIN must be 8-24 letters or digits';
    return null;
  }

  /// Display form of a serial: everything but the last [visible] characters
  /// masked. The History card shows this, so the full credential is never on
  /// screen — and therefore never in a screenshot or a shoulder-surf.
  static String maskSerial(String serial, {int visible = 4}) {
    final s = normalise(serial);
    if (s.length <= visible) return '\u2022' * s.length;
    return '${'\u2022' * (s.length - visible)}'
        '${s.substring(s.length - visible)}';
  }
}

/// A purchased WAEC result checker.
///
/// **Hard Rule 1 / ADR-001.** [serial] and [pin] *are* the credential. They are
/// held only inside the AES-256-GCM blob of the on-device vault
/// (`core/storage/encrypted_archive.dart`) and must never be logged, traced,
/// reported to analytics, or written to any other store.
///
/// [toString] is deliberately credential-free, so an accidental
/// `print(checker)` or a debugger expansion cannot leak one. Do not add the
/// serial or PIN to it.
class Checker {
  const Checker({
    required this.id,
    required this.serial,
    required this.pin,
    required this.examType,
    required this.examYear,
    required this.status,
    required this.purchasedAtUnix,
    this.redeemedAtUnix,
    this.expiresAtUnix,
    this.transactionId = '',
  });

  /// Vault row id (a UUIDv4 minted at purchase). Safe to log.
  final String id;

  /// The credential's serial. Never log or render in full.
  final String serial;

  /// The credential's PIN. Never log or render in full.
  final String pin;

  /// Wire code of the exam this checker covers (`ExamType.code`). Kept as a
  /// string so an unknown code from a newer build survives a vault round trip
  /// unchanged instead of being coerced into a known enum member.
  final String examType;

  /// Exam year this checker covers.
  final String examYear;

  final CheckerStatus status;

  final int purchasedAtUnix;

  /// Set once the redemption journey reached terminal success.
  final int? redeemedAtUnix;

  /// Backend-attached validity deadline, when it supplies one.
  final int? expiresAtUnix;

  /// Payment transaction that provisioned this checker.
  final String transactionId;

  /// Whether the redemption flow may spend this checker.
  bool get isRedeemable => status.isRedeemable;

  /// Safe-to-render serial (last 4 characters visible).
  String get maskedSerial => CheckerValidator.maskSerial(serial);

  /// True when the checker has outlived its own deadline — the vault can hold
  /// a stale `unused` row if the backend never flipped the status.
  bool isExpiredAt(int nowUnix) =>
      status == CheckerStatus.expired ||
      (expiresAtUnix != null && nowUnix >= expiresAtUnix!);

  Checker copyWith({CheckerStatus? status, int? redeemedAtUnix}) => Checker(
    id: id,
    serial: serial,
    pin: pin,
    examType: examType,
    examYear: examYear,
    status: status ?? this.status,
    purchasedAtUnix: purchasedAtUnix,
    redeemedAtUnix: redeemedAtUnix ?? this.redeemedAtUnix,
    expiresAtUnix: expiresAtUnix,
    transactionId: transactionId,
  );

  /// Credential-free by design — see the class documentation.
  @override
  String toString() =>
      'Checker(id: $id, exam: $examType $examYear, status: ${status.name})';
}
