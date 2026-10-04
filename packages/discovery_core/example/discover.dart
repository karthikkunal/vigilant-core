import 'package:discovery_core/discovery_core.dart';

/// End-to-end smoke test against the live services.
///
///   dart run example/discover.dart example.com
Future<void> main(List<String> args) async {
  final domain = args.isNotEmpty ? args.first : 'example.com';
  final engine = DiscoveryEngine();

  print('Discovering $domain ...\n');
  final report = await engine.discover(domain);
  final now = DateTime.now().toUtc();

  print('host:        ${report.input.host}');
  print('registrable: ${report.input.registrable}');
  print('tld:         ${report.input.tld}');
  print('');

  final registration = report.registration;
  if (registration != null) {
    print('registration');
    print('  expires:     ${registration.expiresAt}');
    print('  days left:   ${registration.daysUntilExpiry(now)}');
    print('  registrar:   ${registration.registrar}');
    print('  statuses:    ${registration.statuses.join(', ')}');
    print('  nameservers: ${registration.nameservers.length}');
  } else {
    print('registration: none (no RDAP service for this TLD)');
  }
  print('');

  print('dns');
  for (final type in report.dns.types) {
    print('  $type: ${report.dns.ofType(type).length}');
  }

  final email = report.emailAuth;
  if (email != null) {
    print('');
    print('email auth');
    print('  spf:   ${email.hasSpf ? 'present' : 'missing'}');
    print('  dmarc: ${email.hasDmarc ? 'present' : 'missing'}');
    print('  dkim:  ${email.dkim.keys.join(', ')}');
    print('  caa:   ${email.caa.length}');
  }

  final ct = report.ct;
  if (ct != null) {
    print('');
    print('certificate transparency');
    print('  entries:    ${ct.entryCount}');
    print('  subdomains: ${ct.subdomains.length}');
    for (final sub in ct.subdomains.take(5)) {
      print('    - $sub');
    }
  }

  final http = report.http;
  if (http != null) {
    print('');
    print('http');
    print('  status:    ${http.statusCode}');
    print('  redirects: ${http.redirectChain}');
    print('  hsts:      ${http.hsts ?? 'missing'}');
  }

  if (report.errors.isNotEmpty) {
    print('');
    print('probe warnings');
    for (final error in report.errors) {
      print('  ${error.probe}: ${error.message}');
    }
  }
}
