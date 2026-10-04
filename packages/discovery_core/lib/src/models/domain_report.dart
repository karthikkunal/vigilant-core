import '../core/domain_input.dart';
import 'certificate.dart';
import 'ct_entry.dart';
import 'dns_records.dart';
import 'email_auth.dart';
import 'http_findings.dart';
import 'registration.dart';
import 'provider_status.dart';

/// A single probe that failed, kept alongside the probes that succeeded.
class ProbeError {
  const ProbeError({required this.probe, required this.message});

  final String probe;
  final String message;

  @override
  String toString() => '$probe: $message';
}

/// Everything the engine discovered about one domain.
class DomainReport {
  const DomainReport({
    required this.input,
    required this.fetchedAt,
    this.registration,
    this.dns = DnsRecordSet.empty,
    this.emailAuth,
    this.certificate,
    this.ct,
    this.http,
    this.errors = const [],
    this.providerStatuses = const [],
    this.includeCt = true,
  });

  final DomainInput input;
  final DateTime fetchedAt;

  final RegistrationInfo? registration;
  final DnsRecordSet dns;
  final EmailAuthInfo? emailAuth;

  /// Filled by the platform `cert_chain` plugin, not by this package.
  final CertificateInfo? certificate;

  final CtInfo? ct;
  final HttpFindings? http;

  /// Probes that failed; the report is still usable.
  final List<ProbeError> errors;

  /// Per-provider freshness/availability for the scan that produced this report.
  final List<ProviderStatus> providerStatuses;

  /// Whether the Certificate Transparency probe was part of this scan.
  ///
  /// Without it a null [ct] is ambiguous: it could mean the caller declined the
  /// probe, or that the probe ran and came back empty. Those are different
  /// claims, so the engine records which one applies rather than leaving the
  /// presentation layer to guess.
  final bool includeCt;

  bool get isPartial => errors.isNotEmpty;
}
