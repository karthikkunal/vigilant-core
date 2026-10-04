/// Email-authentication findings derived from TXT and CAA records.
class EmailAuthInfo {
  const EmailAuthInfo({
    this.spf,
    this.dmarc,
    this.dkim = const {},
    this.caa = const [],
  });

  /// The combined `v=spf1 ...` record, or null when absent.
  final String? spf;

  /// The `v=DMARC1 ...` record at `_dmarc.<domain>`, or null when absent.
  final String? dmarc;

  /// DKIM records found, keyed by selector.
  final Map<String, String> dkim;

  /// CAA record values (issue / issuewild directives).
  final List<String> caa;

  bool get hasSpf => spf != null;
  bool get hasDmarc => dmarc != null;

  /// A rough posture score in 0..3 (SPF, DMARC, CAA present).
  int get score =>
      (hasSpf ? 1 : 0) + (hasDmarc ? 1 : 0) + (caa.isNotEmpty ? 1 : 0);
}
