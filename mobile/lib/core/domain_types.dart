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
