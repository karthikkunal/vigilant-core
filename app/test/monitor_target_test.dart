import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/monitors/monitor_target.dart';

void main() {
  group('inferring a website target', () {
    test('a bare domain becomes an HTTPS uptime check', () {
      final result = resolveMonitorTarget('example.com');

      expect(result.isResolved, isTrue);
      final target = result.target!;
      expect(target.kind, ResolvedMonitorKind.uptime);
      expect(target.uri.toString(), 'https://example.com');
      expect(target.host, 'example.com');
      expect(target.port, isNull);
      expect(target.isPlainWebsite, isTrue);
    });

    test('a path is kept, because the check has to reach it', () {
      final result = resolveMonitorTarget('https://example.com/health');

      final target = result.target!;
      expect(target.uri.path, '/health');
      // A path makes it a specific endpoint, so it is not interchangeable with
      // a monitor on the bare host.
      expect(target.isPlainWebsite, isFalse);
    });

    test('a bare host:port is a website on that port, not a socket', () {
      // Typing a port next to a host usually means a web service, so that is
      // what this resolves to. Asking for a socket needs the selector.
      final result = resolveMonitorTarget('example.com:8080');

      final target = result.target!;
      expect(target.kind, ResolvedMonitorKind.uptime);
      expect(target.isTcp, isFalse);
      expect(target.port, 8080);
    });

    test('an explicit http scheme is left alone rather than upgraded', () {
      final result = resolveMonitorTarget('http://example.com');

      expect(result.target!.uri.scheme, 'http');
      expect(result.target!.isPlainWebsite, isFalse);
    });

    test('body rules turn the same target into an assertion check', () {
      final result = resolveMonitorTarget('example.com', assertionCount: 1);

      expect(result.target!.kind, ResolvedMonitorKind.assertion);
      expect(result.target!.hasAssertions, isTrue);
      expect(result.target!.summary, contains('1 body rule'));
    });

    test('the rule count in the summary is pluralised', () {
      expect(
        resolveMonitorTarget('example.com', assertionCount: 2).target!.summary,
        contains('2 body rules'),
      );
    });
  });

  group('inferring a TCP target', () {
    test('the tcp:// scheme is unambiguous', () {
      final result = resolveMonitorTarget('tcp://db.example.com:5432');

      final target = result.target!;
      expect(target.kind, ResolvedMonitorKind.tcp);
      expect(target.isTcp, isTrue);
      expect(target.host, 'db.example.com');
      expect(target.port, 5432);
    });

    test('the selector turns a bare host:port into a socket', () {
      final result = resolveMonitorTarget(
        'db.example.com:5432',
        choice: MonitorTargetChoice.tcp,
      );

      final target = result.target!;
      expect(target.isTcp, isTrue);
      expect(target.port, 5432);
      expect(target.summary, contains('send nothing'));
    });

    test('the selector still requires a port', () {
      final result = resolveMonitorTarget(
        'db.example.com',
        choice: MonitorTargetChoice.tcp,
      );

      expect(result.isResolved, isFalse);
      expect(result.error, contains('needs a port'));
    });

    test('a socket without a port is rejected rather than defaulted', () {
      final result = resolveMonitorTarget('tcp://db.example.com');

      expect(result.isResolved, isFalse);
      expect(result.error, contains('needs a port'));
    });

    test('body rules and a socket are rejected, not silently dropped', () {
      // Dropping the rules would create a monitor that quietly does less than
      // the user asked for, which is the failure this screen exists to remove.
      final result = resolveMonitorTarget(
        'tcp://db.example.com:5432',
        assertionCount: 2,
      );

      expect(result.isResolved, isFalse);
      expect(result.error, contains('cannot be'));
    });

    test('the website selector overrides a tcp:// scheme', () {
      final result = resolveMonitorTarget(
        'tcp://example.com:443',
        choice: MonitorTargetChoice.website,
      );

      expect(result.isResolved, isTrue);
      expect(result.target!.isTcp, isFalse);
    });
  });

  group('rejecting nonsense', () {
    test('empty input explains itself', () {
      final result = resolveMonitorTarget('   ');

      expect(result.isResolved, isFalse);
      expect(result.error, isNotEmpty);
    });

    test('an out-of-range port is rejected', () {
      final result = resolveMonitorTarget('example.com:99999');

      expect(result.isResolved, isFalse);
      expect(result.error, contains('65535'));
    });

    test('a non-HTTP scheme points at the right alternative', () {
      final result = resolveMonitorTarget('ftp://files.example.com');

      expect(result.isResolved, isFalse);
      expect(result.error, contains('tcp://'));
    });

    test('a scheme with no host is rejected', () {
      expect(resolveMonitorTarget('https://').isResolved, isFalse);
    });
  });

  group('plain-website detection', () {
    test('an explicit https URL on the root is still plain', () {
      // The point is the monitor id, and https://example.com and example.com
      // must land on the same one.
      expect(
        resolveMonitorTarget('https://example.com').target!.isPlainWebsite,
        isTrue,
      );
      expect(
        resolveMonitorTarget('https://example.com/').target!.isPlainWebsite,
        isTrue,
      );
    });

    test('a port, path, query or socket is not plain', () {
      for (final input in [
        'https://example.com:8443',
        'https://example.com/health',
        'https://example.com/?q=1',
      ]) {
        expect(
          resolveMonitorTarget(input).target!.isPlainWebsite,
          isFalse,
          reason: input,
        );
      }
      expect(
        resolveMonitorTarget('tcp://example.com:443').target!.isPlainWebsite,
        isFalse,
      );
    });
  });
}
