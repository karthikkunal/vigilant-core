import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/alerts/pager_style.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_transfer.dart';

void main() {
  group('a target list carries addresses and nothing else', () {
    test('writes one bare host per line for site monitors', () {
      final list = MonitorTargetList([
        targetLineFor(MonitorConfig.forDomain('example.com')),
        targetLineFor(MonitorConfig.forDomain('api.apps.example.com')),
      ]).encode();

      expect(list, 'example.com\napi.apps.example.com');
    });

    test('keeps the port for a TCP target', () {
      final line = targetLineFor(MonitorConfig.forTcp('db.example.com', 5432));
      expect(line, 'db.example.com:5432');
    });

    test('keeps a URL when the path is what makes it distinct', () {
      final line = targetLineFor(
        MonitorConfig.forUrl(Uri.parse('https://example.com/health')),
      );
      expect(line, 'https://example.com/health');
    });

    test('drops a bare-root URL back to its host', () {
      final line = targetLineFor(
        MonitorConfig.forUrl(Uri.parse('https://example.com/')),
      );
      expect(line, 'example.com');
    });

    // The whole point of the format: a list of sites reads as a list of sites,
    // and nothing about how they are watched is written down.
    test('carries no configuration of any kind', () {
      final tuned = MonitorConfig.forDomain('example.com').copyWith(
        cadence: const Duration(minutes: 45),
        latencyBudget: const Duration(milliseconds: 9000),
        timeout: const Duration(seconds: 40),
        registrationExpiry: DateTime.utc(2028, 6, 1),
        certificateExpiry: DateTime.utc(2027, 1, 15),
        style: const AlertStyle(sound: AlertSound.alarm),
        policy: const AlertPolicy(
          failureThreshold: 5,
          urgent: true,
          quietHours: QuietHours(startMinutes: 60, endMinutes: 300),
        ),
        enabled: false,
      );

      final line = targetLineFor(tuned);
      expect(line, 'example.com');

      // And nothing about the monitor survives a round trip either.
      final restored = MonitorTargetList.read(line).monitors.single;
      expect(restored.cadence, const Duration(minutes: 5));
      expect(restored.latencyBudget, const Duration(milliseconds: 2500));
      expect(restored.timeout, const Duration(seconds: 10));
      expect(restored.registrationExpiry, isNull);
      expect(restored.certificateExpiry, isNull);
      expect(restored.policy.urgent, isFalse);
      expect(restored.policy.quietHours, isNull);
      expect(restored.style.sound, AlertSound.notification);
      expect(restored.enabled, isTrue);
    });
  });

  group('reading a list', () {
    test('builds a site monitor from a bare domain', () {
      final targets = MonitorTargetList.read('example.com').monitors;
      expect(targets.single.id, 'example.com');
      expect(targets.single.isTcp, isFalse);
    });

    test('builds a site monitor from a bare address', () {
      final targets = MonitorTargetList.read('203.0.113.10').monitors;
      expect(targets.single.targetHost, '203.0.113.10');
    });

    test('builds a TCP monitor from host and port', () {
      final monitor = MonitorTargetList.read('db.example.com:5432')
          .monitors
          .single;
      expect(monitor.isTcp, isTrue);
      expect(monitor.targetHost, 'db.example.com');
      expect(monitor.targetPort, 5432);
    });

    test('builds a URL monitor when a scheme is spelled out', () {
      final monitor = MonitorTargetList.read('https://example.com/health')
          .monitors
          .single;
      expect(monitor.isTcp, isFalse);
      expect(monitor.url, 'https://example.com/health');
    });

    test('ignores blank lines and comments', () {
      final result = MonitorTargetList.read('''
# things I own
example.com

  # and this one
api.example.com
''');

      expect(result.monitors.map((m) => m.id), [
        'example.com',
        'api.example.com',
      ]);
      expect(result.unreadable, 0);
    });

    test('keeps the readable lines and counts the rest', () {
      final result = MonitorTargetList.read('''
example.com
not a domain at all!!
api.example.com
''');

      expect(result.monitors.map((m) => m.id), [
        'example.com',
        'api.example.com',
      ]);
      expect(result.unreadable, 1);
    });

    test('removes a repeated line', () {
      final result = MonitorTargetList.read('example.com\nexample.com');
      expect(result.monitors, hasLength(1));
      expect(result.unreadable, 0);
    });

    test('reads a bracketed IPv6 target with a port', () {
      final monitor = MonitorTargetList.read('[2001:db8::1]:443')
          .monitors
          .single;
      expect(monitor.isTcp, isTrue);
      expect(monitor.targetHost, '2001:db8::1');
      expect(monitor.targetPort, 443);
    });

    test('reads a bare IPv6 literal as a host, not a host and port', () {
      final monitor = MonitorTargetList.read('2001:db8::1').monitors.single;
      expect(monitor.isTcp, isFalse);
    });
  });

  group('refusing text that names nothing watchable', () {
    // A pasted list is untrusted input. Every accepted line becomes a monitor
    // the user could have typed, so anything else is refused rather than stored.
    test('rejects an empty paste', () {
      expect(
        () => MonitorTargetList.read('   \n  \n'),
        throwsA(isA<MonitorTransferException>()),
      );
    });

    test('rejects prose', () {
      expect(
        () => MonitorTargetList.read('my vigilant-core is on fire'),
        throwsA(
          isA<MonitorTransferException>().having(
            (e) => e.message,
            'message',
            contains('None of those lines'),
          ),
        ),
      );
    });

    test('rejects a JSON document, since this is not that format', () {
      expect(
        () => MonitorTargetList.read('{"format": "vigilant-core-monitors"}'),
        throwsA(isA<MonitorTransferException>()),
      );
    });

    test('rejects a non-web scheme', () {
      expect(
        () => MonitorTargetList.read('file:///etc/passwd'),
        throwsA(isA<MonitorTransferException>()),
      );
      expect(
        () => MonitorTargetList.read('ftp://example.com'),
        throwsA(isA<MonitorTransferException>()),
      );
    });

    test('rejects a port outside the valid range', () {
      expect(
        () => MonitorTargetList.read('db.example.com:70000'),
        throwsA(isA<MonitorTransferException>()),
      );
      expect(
        () => MonitorTargetList.read('db.example.com:0'),
        throwsA(isA<MonitorTransferException>()),
      );
    });

    test('rejects a non-numeric port', () {
      expect(
        () => MonitorTargetList.read('db.example.com:http'),
        throwsA(isA<MonitorTransferException>()),
      );
    });
  });

  group('previewing an import', () {
    test('adds only the sites that are missing', () {
      final result = buildImportPreview(
        document: MonitorTargetList.read(
          'existing.example.com\nnew.example.com',
        ),
        existing: [MonitorConfig.forDomain('existing.example.com')],
      );

      expect(result.additions.map((m) => m.id), ['new.example.com']);
      expect(result.alreadyPresent, 1);
      expect(result.unreadable, 0);
    });

    test('a list of only known sites adds nothing', () {
      final result = buildImportPreview(
        document: MonitorTargetList.read('a.example.com\nb.example.com'),
        existing: [
          MonitorConfig.forDomain('a.example.com'),
          MonitorConfig.forDomain('b.example.com'),
        ],
      );
      expect(result.isEmpty, isTrue);
      expect(result.alreadyPresent, 2);
    });

    test('counts an unreadable line in the total', () {
      final result = buildImportPreview(
        document: MonitorTargetList.read('a.example.com\nnope!!'),
        existing: const [],
      );
      expect(result.total, 2);
      expect(result.unreadable, 1);
    });
  });
}
