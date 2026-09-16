/// Exam types supported at launch — Ghana only (plan Appendix A).
enum ExamType {
  bece('BECE', 'BECE (Junior High)'),
  wassceSchool('WASSCE_SC', 'WASSCE School (May/June)'),
  wasscePrivate('WASSCE_PRIVATE', 'WASSCE Private (Nov-Dec, Nwasie)');

  const ExamType(this.code, this.displayName);
  final String code;
  final String displayName;
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
