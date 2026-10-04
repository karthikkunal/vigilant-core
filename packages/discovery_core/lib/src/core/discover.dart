import '../http/ct_client.dart';
import '../http/dns_client.dart';
import '../http/doh_client.dart';
import '../http/http_probe.dart';
import '../http/rdap_client.dart';
import '../models/ct_entry.dart';
import '../models/dns_records.dart';
import '../models/domain_report.dart';
import '../models/email_auth.dart';
import '../models/http_findings.dart';
import '../models/registration.dart';
import '../models/provider_status.dart';
import 'domain_input.dart';
import 'errors.dart';

/// Runs every discovery probe for a domain and assembles a [DomainReport].
///
/// Each probe is independent: one failing is recorded in [DomainReport.errors]
/// and the rest still complete. TLS certificate capture is intentionally absent
/// here — it is supplied by the platform `cert_chain` plugin.
class DiscoveryEngine {
  DiscoveryEngine({
    DnsClient? dns,
    RdapClient? rdap,
    CtClient? ct,
    HttpProbe? http,
    this.webMode = false,
    this.dnsTypes = const ['A', 'AAAA', 'NS', 'MX', 'TXT', 'CAA'],
  })  : dns = dns ?? DohClient(),
        rdap = rdap ?? RdapClient(),
        ct = ct ?? CtClient(tryCrtSh: !webMode),
        http = http ?? HttpProbe();

  /// The resolver to query. Defaults to DNS-over-HTTPS; the app substitutes the
  /// platform resolver on Android via the `system_dns` package.
  final DnsClient dns;
  final RdapClient rdap;
  final CtClient ct;
  final HttpProbe http;

  /// Browser builds cannot read arbitrary target sites or crt.sh responses
  /// cross-origin, so those probes are omitted in web mode.
  final bool webMode;

  final List<String> dnsTypes;

  static const _dkimSelectors = <String>[
    'default',
    'google',
    'selector1',
    'selector2',
    'k1',
    'mail',
  ];

  Future<DomainReport> discover(String raw, {bool includeCt = true}) async {
    final input = DomainInput.tryParse(raw);
    if (input == null) {
      throw DiscoveryException('Not a usable domain: "$raw"');
    }

    RegistrationInfo? registration;
    var dnsRecords = DnsRecordSet.empty;
    var unsupportedDnsTypes = const <String>[];
    EmailAuthInfo? emailAuth;
    CtInfo? ctInfo;
    HttpFindings? httpFindings;
    final errors = <ProbeError>[];
    final probeErrors = <String, String>{};

    Future<void> probe(String name, Future<void> Function() body) async {
      try {
        await body();
      } catch (error) {
        final message = error.toString();
        probeErrors[name] = message;
        errors.add(ProbeError(probe: name, message: message));
      }
    }

    final jobs = <Future<void>>[
      probe('rdap', () async {
        registration = await rdap.lookup(input);
      }),
      probe('dns', () async {
        // A resolver that cannot answer every requested type must not have its
        // gaps read as "the record is absent", so unsupported types are dropped
        // up front and named in the provider status instead.
        final queryable =
            dnsTypes.where(dns.supportedTypes.contains).toList(growable: false);
        final unsupported = dnsTypes
            .where((type) => !dns.supportedTypes.contains(type))
            .toList(growable: false);
        dnsRecords = await dns.lookup(input.registrable, queryable);
        emailAuth = await _emailAuth(input, dnsRecords);
        unsupportedDnsTypes = unsupported;
      }),
    ];
    if (!webMode) {
      jobs.add(probe('http', () async {
        httpFindings = await http.probe(input.host);
      }));
    }
    if (includeCt) {
      jobs.add(probe('ct', () async {
        ctInfo = await ct.lookup(input.registrable);
      }));
    }

    await Future.wait(jobs);

    final providerStatuses = _providerStatuses(
      registration: registration,
      dnsRecords: dnsRecords,
      http: httpFindings,
      ct: ctInfo,
      probeErrors: probeErrors,
      unsupportedDnsTypes: unsupportedDnsTypes,
      includeCt: includeCt,
      includeHttp: !webMode,
    );

    return DomainReport(
      input: input,
      fetchedAt: DateTime.now().toUtc(),
      registration: registration,
      dns: dnsRecords,
      emailAuth: emailAuth,
      ct: ctInfo,
      http: httpFindings,
      errors: errors,
      providerStatuses: providerStatuses,
      includeCt: includeCt,
    );
  }

  List<ProviderStatus> _providerStatuses({
    required RegistrationInfo? registration,
    required DnsRecordSet dnsRecords,
    required HttpFindings? http,
    required CtInfo? ct,
    required Map<String, String> probeErrors,
    required List<String> unsupportedDnsTypes,
    required bool includeCt,
    required bool includeHttp,
  }) {
    String? errorFor(String probe) => probeErrors[probe];
    final httpStatus = http?.statusCode;
    final missingTypes = unsupportedDnsTypes.join(', ');

    final statuses = <ProviderStatus>[
      _providerStatus(
        name: 'RDAP',
        source: registration?.source,
        error: errorFor('rdap'),
        available: registration != null,
        unknownDetail: 'This TLD may not publish RDAP data.',
      ),
      _providerStatus(
        name: 'DNS',
        source: dns.sourceLabel,
        error: errorFor('dns'),
        available: dnsRecords.types.isNotEmpty,
        // Partial coverage is reported as degraded, never as a clean result:
        // an absent MX or CAA is a different claim from an unqueried one.
        degraded: unsupportedDnsTypes.isNotEmpty,
        degradedDetail: missingTypes.isEmpty
            ? 'The source returned only partial data.'
            : 'This resolver cannot answer $missingTypes.',
        unknownDetail: 'No DNS answers were returned.',
      ),
      if (includeHttp)
        _providerStatus(
          name: 'HTTP target',
          source: http == null ? null : 'HTTPS',
          error: errorFor('http'),
          available: httpStatus != null,
          healthy: httpStatus != null && httpStatus >= 200 && httpStatus < 300,
          unknownDetail: 'The HTTPS probe returned no status code.',
        )
      else
        const ProviderStatus(
          name: 'HTTP target',
          status: ProviderHealth.skipped,
          detail: 'Not available in the browser build.',
        ),
      if (includeCt)
        _providerStatus(
          name: 'Certificate Transparency',
          source: ct?.source,
          error: errorFor('ct'),
          available: ct != null,
          degraded: ct?.isPartial == true,
          unknownDetail: 'No Certificate Transparency result was returned.',
        )
      else
        const ProviderStatus(
          name: 'Certificate Transparency',
          status: ProviderHealth.skipped,
          detail: 'Not requested for this scan.',
        ),
    ];
    return statuses;
  }

  ProviderStatus _providerStatus({
    required String name,
    required String? error,
    required bool available,
    String? source,
    bool healthy = true,
    bool degraded = false,
    String? degradedDetail,
    String? unknownDetail,
  }) {
    if (error != null) {
      return ProviderStatus(
        name: name,
        status: ProviderHealth.down,
        source: source,
        detail: error,
      );
    }
    if (!available) {
      return ProviderStatus(
        name: name,
        status: ProviderHealth.unknown,
        source: source,
        detail: unknownDetail,
      );
    }
    return ProviderStatus(
      name: name,
      status: degraded
          ? ProviderHealth.degraded
          : healthy
              ? ProviderHealth.healthy
              : ProviderHealth.down,
      source: source,
      detail: degraded
          ? degradedDetail ?? 'The source returned only partial data.'
          : null,
    );
  }

  Future<EmailAuthInfo> _emailAuth(
    DomainInput input,
    DnsRecordSet records,
  ) async {
    // DMARC and the DKIM selectors are seven extra lookups. A resolver that
    // cannot answer TXT must not be asked for them: the engine's contract is
    // that it only queries types the client reports it supports, and the gap
    // is already surfaced by the DNS provider status.
    final canQueryTxt = dns.supportedTypes.contains('TXT');

    String? dmarc;
    if (canQueryTxt) {
      try {
        final answers = await dns.query('_dmarc.${input.registrable}', 'TXT');
        dmarc = _firstTxt(answers, 'v=DMARC1');
      } on Object {
        // No DMARC record (or the query failed); leave it absent.
      }
    }

    final dkim = <String, String>{};
    if (canQueryTxt) {
      for (final selector in _dkimSelectors) {
        try {
          final answers = await dns.query(
              '$selector._domainkey.${input.registrable}', 'TXT');
          final value = _firstTxt(answers, 'v=DKIM1');
          if (value != null) dkim[selector] = value;
        } on Object {
          // Selector not published; ignore.
        }
      }
    }

    return EmailAuthInfo(
      spf: _firstTxt(records.ofType('TXT'), 'v=spf1'),
      dmarc: dmarc,
      dkim: dkim,
      caa: records.ofType('CAA').map((r) => r.data).toList(growable: false),
    );
  }

  String? _firstTxt(List<DnsRecord> records, String prefix) {
    for (final record in records) {
      final value = _unquote(record.data);
      if (value.toLowerCase().startsWith(prefix.toLowerCase())) return value;
    }
    return null;
  }

  String _unquote(String data) {
    var value = data.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value.replaceAll('" "', '');
  }
}
