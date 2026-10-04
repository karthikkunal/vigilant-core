import 'dart:convert';

import '../models/certificate.dart';
import '../models/domain_report.dart';
import '../models/provider_status.dart';

/// A point-in-time flattening of a report, used to detect change between
/// checks. Keys are stable strings (`dns.NS`, `registration.expiresAt`, ...).
class DomainSnapshot {
  const DomainSnapshot({required this.at, required this.facts});

  final DateTime at;
  final Map<String, String> facts;

  /// Encoded for local storage. Only facts are persisted; the report they came
  /// from is not kept, because a report is large and only the comparison is
  /// ever needed again.
  String encode() => jsonEncode({
        'v': 1,
        'at': at.toUtc().toIso8601String(),
        'facts': facts,
      });

  /// Decodes a stored baseline, returning null for anything unreadable.
  ///
  /// A baseline is an optimisation for honesty, not a correctness requirement:
  /// if it cannot be read the next scan simply reports no previous state rather
  /// than failing. So a corrupt or older document is dropped, not repaired.
  static DomainSnapshot? read(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != 1) return null;
      final at = DateTime.tryParse('${decoded['at']}');
      final facts = decoded['facts'];
      if (at == null || facts is! Map) return null;
      return DomainSnapshot(
        at: at.toUtc(),
        facts: {
          for (final entry in facts.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        },
      );
    } on FormatException {
      return null;
    }
  }
}

/// One difference between two snapshots.
class Difference {
  const Difference({required this.key, this.before, this.after});

  final String key;
  final String? before;
  final String? after;

  bool get isAdded => before == null && after != null;
  bool get isRemoved => before != null && after == null;
  bool get isChanged => before != null && after != null && before != after;

  /// The area this key belongs to, e.g. `dns.NS` belongs to `dns`.
  String get area => driftArea(key);

  /// Whether a human would want to be told about this specific change.
  bool get isNotable => isNotableDrift(key);

  @override
  String toString() => '$key: ${before ?? '(none)'} -> ${after ?? '(none)'}';
}

/// Differences between two fact maps, sorted by key.
///
/// This compares what it is given and nothing more. It cannot tell an observed
/// absence from an unobserved value, so callers that hold a partial report must
/// narrow the input with [observedAreas] first — see [diffReports].
List<Difference> diffSnapshots(
  Map<String, String>? previous,
  Map<String, String> current,
) {
  final keys = <String>{...?previous?.keys, ...current.keys};
  final differences = <Difference>[];
  for (final key in keys) {
    final before = previous?[key];
    final after = current[key];
    if (before != after) {
      differences.add(Difference(key: key, before: before, after: after));
    }
  }
  differences.sort((a, b) => a.key.compareTo(b.key));
  return differences;
}

/// The area a fact key belongs to: the part before the first dot.
String driftArea(String key) {
  final dot = key.indexOf('.');
  return dot == -1 ? key : key.substring(0, dot);
}

/// The facts whose change is worth interrupting someone for.
///
/// The rule is that a key qualifies when a change to it is something a person
/// would want to act on — an expiry that moved, a delegation that changed, a
/// mail or TLS policy that weakened, or a trust decision that flipped. Bulk
/// data (addresses, subdomains, entry counts, mail exchangers) churns on its own
/// and is excluded, because a signal that fires on ordinary change trains the
/// reader to ignore it.
///
/// A key absent from this set is still diffed and still shown. It is only
/// excluded from the count of changes worth surfacing.
const notableDriftKeys = <String>{
  // Expiry and delegation: the two facts the app is built to act on.
  'registration.expiresAt',
  'registration.nameservers',
  'registration.registrar',

  // Mail policy. A removed DMARC record or a changed SPF is a downgrade.
  'email.spf',
  'email.dmarc',
  'email.caa',

  // Losing a mail exchanger breaks outbound mail quietly, which is exactly the
  // kind of change that goes unnoticed until someone notices it is not arriving.
  'dns.MX',

  // TLS posture, including the v1 chain gate.
  'cert.notAfter',
  'cert.issuer',
  'cert.intermediates',
  'cert.trusted',

  // Transport policy and reachability.
  'http.hsts',
  'http.statusCode',
};

/// Whether a change to [key] is one worth surfacing rather than merely listing.
bool isNotableDrift(String key) => notableDriftKeys.contains(key);

/// The areas a report actually observed, as fact-key prefixes.
///
/// This is what keeps a partial scan from reading as a changed one.
/// [snapshotFacts] omits a key when the underlying datum is absent, and absence
/// means two different things: the answer was "nothing there", or the probe
/// never ran. Diffing across the second kind invents removals that never
/// happened — declining the Certificate Transparency probe on the second scan
/// would otherwise erase every `ct.*` fact from the first.
///
/// An area is therefore reported only when the probe behind it succeeded. For
/// DNS the test is stricter still, because a resolver that cannot answer every
/// requested type leaves the unqueried ones looking empty: the engine already
/// reports that as a degraded DNS provider, and a degraded resolver must not be
/// allowed to manufacture diffs.
Set<String> observedAreas(
  DomainReport report, {
  CertificateInfo? certificate,
}) {
  final failed = {for (final error in report.errors) error.probe};
  final areas = <String>{};

  if (report.registration != null && !failed.contains('rdap')) {
    areas.add('registration');
  }

  final dns = _providerStatus(report, 'DNS');
  final dnsAnswered = !failed.contains('dns') && report.dns.types.isNotEmpty;
  final dnsComplete = dns == null || dns.status != ProviderHealth.degraded;
  if (dnsAnswered && dnsComplete) {
    areas
      ..add('dns')
      ..add('email');
  }

  if (report.includeCt && report.ct != null && !failed.contains('ct')) {
    areas.add('ct');
  }

  if (report.http != null && !failed.contains('http')) {
    areas.add('http');
  }

  if ((certificate ?? report.certificate) != null) {
    areas.add('cert');
  }

  return areas;
}

ProviderStatus? _providerStatus(DomainReport report, String name) {
  for (final status in report.providerStatuses) {
    if (status.name == name) return status;
  }
  return null;
}

/// Flattens a report into comparable facts.
///
/// [certificate] overrides the report's own certificate. The discovery engine
/// never sets `report.certificate` — the chain is captured separately by the
/// platform plugin — so without this the `cert.*` facts could never populate and
/// the TLS posture would be the one part of a scan that could never be compared.
Map<String, String> snapshotFacts(
  DomainReport report, {
  CertificateInfo? certificate,
}) {
  final facts = <String, String>{};

  final registration = report.registration;
  if (registration != null) {
    if (registration.expiresAt != null) {
      facts['registration.expiresAt'] =
          registration.expiresAt!.toIso8601String();
    }
    if (registration.registrar != null) {
      facts['registration.registrar'] = registration.registrar!;
    }
    if (registration.statuses.isNotEmpty) {
      facts['registration.statuses'] = _sorted(registration.statuses);
    }
    if (registration.nameservers.isNotEmpty) {
      facts['registration.nameservers'] = _sorted(registration.nameservers);
    }
  }

  for (final type in report.dns.types) {
    final values = report.dns.ofType(type).map((r) => r.data).toList();
    if (values.isNotEmpty) facts['dns.$type'] = _sorted(values);
  }

  final email = report.emailAuth;
  if (email != null) {
    if (email.spf != null) facts['email.spf'] = email.spf!;
    if (email.dmarc != null) facts['email.dmarc'] = email.dmarc!;
    if (email.caa.isNotEmpty) facts['email.caa'] = _sorted(email.caa);
  }

  final ct = report.ct;
  if (ct != null) {
    facts['ct.entryCount'] = '${ct.entryCount}';
    if (ct.subdomains.isNotEmpty) {
      facts['ct.subdomains'] = _sorted(ct.subdomains);
    }
  }

  final http = report.http;
  if (http != null) {
    if (http.statusCode != null) {
      facts['http.statusCode'] = '${http.statusCode}';
    }
    facts['http.hsts'] = http.hsts ?? 'missing';
    if (http.redirectChain.isNotEmpty) {
      facts['http.redirectChain'] = http.redirectChain.join(' -> ');
    }
  }

  final chain = certificate ?? report.certificate;
  if (chain != null) {
    if (chain.leaf.notAfter != null) {
      facts['cert.notAfter'] = chain.leaf.notAfter!.toIso8601String();
    }
    facts['cert.issuer'] = chain.leaf.issuer;
    facts['cert.intermediates'] = '${chain.presentedIntermediates}';
    if (chain.trusted != null) facts['cert.trusted'] = '${chain.trusted}';
  }

  return facts;
}

/// What changed between a stored baseline and the report just produced.
class DriftReport {
  const DriftReport({
    required this.current,
    required this.observed,
    required this.differences,
    this.previous,
  });

  /// The facts for the scan that just ran, and the snapshot to store as the
  /// next baseline.
  final DomainSnapshot current;

  /// The areas this scan actually observed. Differences outside them are
  /// discarded rather than reported.
  final Set<String> observed;

  /// What changed, narrowed to [observed], sorted by key.
  final List<Difference> differences;

  /// The baseline this was compared against, or null on a first scan.
  final DomainSnapshot? previous;

  /// No earlier scan of this domain is stored, so there is nothing to compare.
  bool get isFirstObservation => previous == null;

  /// The subset of [differences] worth surfacing rather than merely listing.
  List<Difference> get notable =>
      differences.where((d) => d.isNotable).toList(growable: false);

  bool get hasChanges => differences.isNotEmpty;
  bool get hasNotableChanges => notable.isNotEmpty;
}

/// Compares a report against a stored baseline and returns the drift.
///
/// The result's [DriftReport.current] is the baseline to persist, so a caller
/// records each scan as it happens. Passing null for [previous] establishes a
/// baseline without reporting change, which is what a first scan should do.
///
/// Only differences inside [DriftReport.observed] are returned. That is the
/// whole point of routing this through here rather than calling [diffSnapshots]
/// directly: a scan that lost a probe, declined CT, or ran on a degraded
/// resolver must not be reported as though the domain changed.
DriftReport diffReports({
  required DomainReport report,
  DomainSnapshot? previous,
  CertificateInfo? certificate,
  DateTime? observedAt,
}) {
  final observed = observedAreas(report, certificate: certificate);
  final facts = snapshotFacts(report, certificate: certificate);
  final current = DomainSnapshot(
    at: (observedAt ?? report.fetchedAt).toUtc(),
    facts: facts,
  );

  if (previous == null) {
    return DriftReport(
      current: current,
      observed: observed,
      differences: const [],
    );
  }

  final differences = diffSnapshots(previous.facts, facts)
      .where((d) => observed.contains(d.area))
      .toList(growable: false);

  return DriftReport(
    current: current,
    observed: observed,
    differences: differences,
    previous: previous,
  );
}

String _sorted(Iterable<String> values) {
  final list = values.toList()..sort();
  return list.join(', ');
}
