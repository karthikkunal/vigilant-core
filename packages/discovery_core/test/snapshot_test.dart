import 'package:discovery_core/discovery_core.dart';
import 'package:test/test.dart';

void main() {
  test('detects added, removed and changed facts', () {
    final before = {
      'dns.NS': 'ns1.example.com',
      'http.hsts': 'missing',
      'dns.A': '93.184.216.34',
    };
    final after = {
      'dns.NS': 'ns1.example.com',
      'http.hsts': 'max-age=31536000',
      'dns.MX': '10 mail.example.com',
    };

    final diffs = diffSnapshots(before, after);
    final byKey = {for (final d in diffs) d.key: d};

    expect(byKey['dns.A']!.isRemoved, isTrue);
    expect(byKey['dns.MX']!.isAdded, isTrue);
    expect(byKey['http.hsts']!.isChanged, isTrue);
    expect(byKey.containsKey('dns.NS'), isFalse);
  });

  test('identical facts produce no differences', () {
    final facts = {'a': '1', 'b': '2'};
    expect(diffSnapshots(facts, facts), isEmpty);
  });

  test('snapshotFacts flattens a report into comparable keys', () {
    final facts = snapshotFacts(_report());

    expect(facts['registration.registrar'], 'Example Registrar');
    expect(
        facts['registration.nameservers'], 'ns1.example.com, ns2.example.com');
    expect(facts['dns.A'], '93.184.216.34');
    expect(facts['email.spf'], 'v=spf1 -all');
    expect(facts['http.statusCode'], '200');
    expect(facts['http.hsts'], 'max-age=31536000');
  });

  group('certificate facts', () {
    test('are populated from a certificate supplied by the platform plugin',
        () {
      // The engine never sets report.certificate, so without the override the
      // TLS posture could never be compared at all.
      final facts = snapshotFacts(_report(), certificate: _certificate());

      expect(facts['cert.notAfter'], '2027-01-01T00:00:00.000Z');
      expect(facts['cert.issuer'], 'Example CA');
      expect(facts['cert.intermediates'], '1');
      expect(facts['cert.trusted'], 'true');
    });

    test('are absent when no chain could be captured', () {
      final facts = snapshotFacts(_report());
      expect(facts.keys.where((k) => k.startsWith('cert.')), isEmpty);
    });

    test('an unknown trust verdict is omitted rather than guessed', () {
      final facts = snapshotFacts(
        _report(),
        certificate: _certificate(trusted: null),
      );
      expect(facts.containsKey('cert.trusted'), isFalse);
    });

    test('the report certificate is used when no override is passed', () {
      final report = DomainReport(
        input: DomainInput.tryParse('example.com')!,
        fetchedAt: DateTime.utc(2026, 1, 1),
        certificate: _certificate(),
      );
      expect(snapshotFacts(report)['cert.issuer'], 'Example CA');
    });
  });

  group('observedAreas', () {
    test('covers every area a complete scan answered', () {
      final areas = observedAreas(
        _report(),
        certificate: _certificate(),
      );
      expect(
        areas,
        containsAll(
            <String>['registration', 'dns', 'email', 'ct', 'http', 'cert']),
      );
    });

    test('omits an area whose probe failed', () {
      final report = _report(
        errors: const [
          ProbeError(probe: 'http', message: 'connection refused')
        ],
      );
      expect(observedAreas(report), isNot(contains('http')));
    });

    test('omits registration when RDAP failed', () {
      final report = _report(
        errors: const [
          ProbeError(probe: 'rdap', message: 'no RDAP for this TLD')
        ],
      );
      expect(observedAreas(report), isNot(contains('registration')));
    });

    test('omits Certificate Transparency when the scan declined it', () {
      // A declined probe returns no CT data, which is indistinguishable from a
      // domain that has none unless includeCt is consulted.
      final report = _report(includeCt: false, ct: null);
      expect(observedAreas(report), isNot(contains('ct')));
    });

    test('omits DNS and email when the resolver could not answer every type',
        () {
      // A degraded resolver leaves unqueried types looking empty, which would
      // otherwise read as every MX and TXT record being deleted.
      final report = _report(
        providerStatuses: const [
          ProviderStatus(
            name: 'DNS',
            status: ProviderHealth.degraded,
            detail: 'This resolver cannot answer MX.',
          ),
        ],
      );
      final areas = observedAreas(report);
      expect(areas, isNot(contains('dns')));
      expect(areas, isNot(contains('email')));
    });

    test('keeps DNS when the resolver merely returned less data', () {
      final report = _report(
        providerStatuses: const [
          ProviderStatus(name: 'DNS', status: ProviderHealth.healthy),
        ],
      );
      expect(observedAreas(report), contains('dns'));
    });

    test('omits DNS when no answers came back at all', () {
      final report = _report(dns: DnsRecordSet.empty, emailAuth: null);
      final areas = observedAreas(report);
      expect(areas, isNot(contains('dns')));
      expect(areas, isNot(contains('email')));
    });

    test('includes cert only when a chain was captured', () {
      expect(observedAreas(_report()), isNot(contains('cert')));
      expect(
        observedAreas(_report(), certificate: _certificate()),
        contains('cert'),
      );
    });
  });

  group('diffReports', () {
    test('a first scan records a baseline and reports no change', () {
      final drift = diffReports(report: _report());

      expect(drift.isFirstObservation, isTrue);
      expect(drift.hasChanges, isFalse);
      expect(drift.current.facts, isNotEmpty);
    });

    test('reports a real change in an observed area', () {
      final before = diffReports(report: _report()).current;
      final after =
          _report(emailAuth: const EmailAuthInfo(dmarc: 'v=DMARC1; p=reject'));

      final drift = diffReports(report: after, previous: before);
      final keys = drift.differences.map((d) => d.key).toList();

      expect(drift.isFirstObservation, isFalse);
      expect(keys, contains('email.dmarc'));
      expect(drift.hasNotableChanges, isTrue);
    });

    test('a declined CT probe on the second scan is not a removal', () {
      // The regression this guards. The first scan enumerated subdomains; the
      // second was run without asking for them. Nothing about the domain
      // changed, so reporting the first scan's CT facts as removed would be
      // inventing a change out of a privacy choice.
      final before = diffReports(
        report: _report(
          ct: const CtInfo(
            entries: [
              CtEntry(
                id: 1,
                commonName: 'example.com',
                issuerName: 'Example CA',
                nameValue: 'example.com\nwww.example.com',
              ),
              CtEntry(
                id: 2,
                commonName: 'mail.example.com',
                issuerName: 'Example CA',
                nameValue: 'mail.example.com',
              ),
            ],
            subdomains: {'www.example.com', 'mail.example.com'},
          ),
        ),
      ).current;
      expect(before.facts['ct.entryCount'], '2');

      // The facts really are gone from the second scan, so the only thing
      // stopping them being reported as removals is the observation gate.
      final second = _report(includeCt: false, ct: null);
      expect(snapshotFacts(second).containsKey('ct.subdomains'), isFalse);

      final drift = diffReports(report: second, previous: before);

      expect(drift.differences, isEmpty);
    });

    test('a CT probe that genuinely lost subdomains is still reported', () {
      // The gate must not swallow real change: both scans ran CT, so a
      // subdomain that disappeared really did disappear.
      final before = diffReports(
        report: _report(
          ct: const CtInfo(
            entries: [
              CtEntry(
                id: 1,
                commonName: 'example.com',
                issuerName: 'Example CA',
                nameValue: 'example.com\nwww.example.com\nmail.example.com',
              ),
            ],
            subdomains: {'www.example.com', 'mail.example.com'},
          ),
        ),
      ).current;

      final drift = diffReports(
        report: _report(
          ct: const CtInfo(
            entries: [
              CtEntry(
                id: 1,
                commonName: 'example.com',
                issuerName: 'Example CA',
                nameValue: 'example.com\nwww.example.com',
              ),
            ],
            subdomains: {'www.example.com'},
          ),
        ),
        previous: before,
      );

      expect(drift.differences.map((d) => d.key), contains('ct.subdomains'));
      // The list shrank rather than vanishing, so this is a changed value, not
      // a removed key.
      expect(drift.differences.single.isChanged, isTrue);
      expect(
        drift.differences.single.after,
        'www.example.com',
        reason: 'the subdomain that is still there',
      );
    });

    test('a failed probe on the second scan is not a removal', () {
      final before = diffReports(
        report: _report(
          http: const HttpFindings(statusCode: 200, hsts: 'max-age=31536000'),
        ),
      ).current;

      final drift = diffReports(
        report: _report(
          omitHttp: true,
          errors: const [ProbeError(probe: 'http', message: 'timed out')],
        ),
        previous: before,
      );

      expect(drift.differences, isEmpty);
    });

    test('a degraded resolver on the second scan is not a removal', () {
      final before = diffReports(
        report: _report(
          dns: const DnsRecordSet({
            'MX': [
              DnsRecord(
                name: 'example.com',
                type: 'MX',
                ttl: 300,
                data: '10 mail.example.com',
              ),
            ],
          }),
        ),
      ).current;
      expect(before.facts['dns.MX'], '10 mail.example.com');

      final drift = diffReports(
        report: _report(
          providerStatuses: const [
            ProviderStatus(
              name: 'DNS',
              status: ProviderHealth.degraded,
              detail: 'This resolver cannot answer MX.',
            ),
          ],
        ),
        previous: before,
      );

      expect(drift.differences, isEmpty);
    });

    test('a genuinely deleted record in an observed area is reported', () {
      final before = diffReports(
        report: _report(
          dns: const DnsRecordSet({
            'A': [
              DnsRecord(
                name: 'example.com',
                type: 'A',
                ttl: 300,
                data: '93.184.216.34',
              ),
            ],
            'MX': [
              DnsRecord(
                name: 'example.com',
                type: 'MX',
                ttl: 300,
                data: '10 mail.example.com',
              ),
            ],
          }),
        ),
      ).current;

      // DNS answered, was not degraded, and genuinely returned no MX now.
      final drift = diffReports(
        report: _report(
          dns: const DnsRecordSet({
            'A': [
              DnsRecord(
                name: 'example.com',
                type: 'A',
                ttl: 300,
                data: '93.184.216.34',
              ),
            ],
          }),
        ),
        previous: before,
      );

      final removed = drift.differences.where((d) => d.key == 'dns.MX');
      expect(removed, hasLength(1));
      expect(removed.single.isRemoved, isTrue);
    });

    test('certificate facts are compared across scans', () {
      final before = diffReports(
        report: _report(),
        certificate: _certificate(notAfter: DateTime.utc(2027, 1, 1)),
      ).current;

      final drift = diffReports(
        report: _report(),
        previous: before,
        certificate: _certificate(
          issuer: 'Other CA',
          notAfter: DateTime.utc(2028, 1, 1),
        ),
      );

      final keys = drift.differences.map((d) => d.key).toList();
      expect(keys, containsAll(<String>['cert.notAfter', 'cert.issuer']));
      expect(drift.hasNotableChanges, isTrue);
    });

    test('a scan that could not capture a chain does not erase TLS facts', () {
      final before = diffReports(
        report: _report(),
        certificate: _certificate(),
      ).current;

      final drift = diffReports(
        report: _report(),
        previous: before,
        certificate: null,
      );

      expect(drift.differences, isEmpty);
    });

    test('records the observation time it was given', () {
      final at = DateTime.utc(2026, 9, 27, 10);
      final drift = diffReports(report: _report(), observedAt: at);
      expect(drift.current.at, at);
    });
  });

  group('notability', () {
    test('separates actionable change from ordinary churn', () {
      expect(isNotableDrift('email.dmarc'), isTrue);
      expect(isNotableDrift('http.hsts'), isTrue);
      expect(isNotableDrift('cert.trusted'), isTrue);
      expect(isNotableDrift('registration.expiresAt'), isTrue);
      expect(isNotableDrift('dns.MX'), isTrue);

      // Addresses, subdomains and entry counts change on their own.
      expect(isNotableDrift('dns.A'), isFalse);
      expect(isNotableDrift('ct.subdomains'), isFalse);
      expect(isNotableDrift('ct.entryCount'), isFalse);
    });

    test('reports the area a key belongs to', () {
      expect(driftArea('dns.MX'), 'dns');
      expect(driftArea('http.hsts'), 'http');
      expect(driftArea('lonely'), 'lonely');
    });
  });

  group('DomainSnapshot storage', () {
    test('round-trips through encode and read', () {
      final snapshot = DomainSnapshot(
        at: DateTime.utc(2026, 9, 27, 10, 30),
        facts: const {
          'dns.A': '93.184.216.34',
          'http.hsts': 'max-age=31536000'
        },
      );

      final restored = DomainSnapshot.read(snapshot.encode())!;

      expect(restored.at, snapshot.at);
      expect(restored.facts, snapshot.facts);
    });

    test('drops an unreadable document rather than failing the scan', () {
      expect(DomainSnapshot.read(null), isNull);
      expect(DomainSnapshot.read(''), isNull);
      expect(DomainSnapshot.read('not json'), isNull);
      expect(DomainSnapshot.read('[]'), isNull);
      expect(DomainSnapshot.read('{"v":2,"at":"x","facts":{}}'), isNull);
      expect(DomainSnapshot.read('{"v":1,"facts":{}}'), isNull);
      expect(DomainSnapshot.read('{"v":1,"at":"nonsense","facts":{}}'), isNull);
    });

    test('keeps only string facts when decoding', () {
      final restored = DomainSnapshot.read(
        '{"v":1,"at":"2026-09-27T10:30:00.000Z",'
        '"facts":{"dns.A":"1.2.3.4","bad":7}}',
      )!;
      expect(restored.facts, {'dns.A': '1.2.3.4'});
    });

    test('a baseline survives a round trip and still diffs', () {
      final stored = DomainSnapshot.read(
        diffReports(report: _report()).current.encode(),
      )!;
      final drift = diffReports(
        report: _report(
            emailAuth: const EmailAuthInfo(dmarc: 'v=DMARC1; p=reject')),
        previous: stored,
      );
      expect(
        drift.differences.map((d) => d.key),
        contains('email.dmarc'),
      );
    });
  });
}

DomainReport _report({
  RegistrationInfo? registration,
  DnsRecordSet? dns,
  EmailAuthInfo? emailAuth,
  CtInfo? ct,
  HttpFindings? http,
  List<ProbeError> errors = const [],
  List<ProviderStatus> providerStatuses = const [],
  bool includeCt = true,

  /// A probe that failed returns no findings at all, which is why these are
  /// flags rather than nullable values: `http: null` cannot be told apart from
  /// "not overridden" by a defaulting parameter.
  bool omitHttp = false,
}) {
  return DomainReport(
    input: DomainInput.tryParse('example.com')!,
    fetchedAt: DateTime.utc(2026, 1, 1),
    registration: registration ??
        const RegistrationInfo(
          expiresAt: null,
          registrar: 'Example Registrar',
          statuses: ['client transfer prohibited'],
          nameservers: ['ns2.example.com', 'ns1.example.com'],
        ),
    dns: dns ??
        const DnsRecordSet({
          'A': [
            DnsRecord(
              name: 'example.com',
              type: 'A',
              ttl: 300,
              data: '93.184.216.34',
            ),
          ],
        }),
    emailAuth: emailAuth ?? const EmailAuthInfo(spf: 'v=spf1 -all'),
    ct: includeCt
        ? ct ??
            const CtInfo(
              entries: [
                CtEntry(
                  id: 1,
                  commonName: 'example.com',
                  issuerName: 'Example CA',
                  nameValue: 'example.com',
                ),
              ],
              subdomains: {'www.example.com'},
            )
        : null,
    http: omitHttp
        ? null
        : http ?? const HttpFindings(statusCode: 200, hsts: 'max-age=31536000'),
    errors: errors,
    providerStatuses: providerStatuses,
    includeCt: includeCt,
  );
}

CertificateInfo _certificate({
  String issuer = 'Example CA',
  // DateTime.utc is not a const constructor, so this cannot be the default;
  // the fallback is applied in the body instead.
  DateTime? notAfter,
  bool? trusted = true,
}) {
  return CertificateInfo(
    leaf: ChainCertificate(
      subject: 'example.com',
      issuer: issuer,
      notAfter: notAfter ?? DateTime.utc(2027, 1, 1),
    ),
    presentedIntermediates: 1,
    trusted: trusted,
  );
}
