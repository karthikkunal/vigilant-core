import 'dart:io';

import 'package:discovery_core/discovery_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  test('reports a reachable TCP port as up', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;

    try {
      final result = await checkTcp(
        host: '127.0.0.1',
        port: server.port,
        now: now,
      );

      expect(result.status, HealthStatus.up);
      expect(result.latencyMs, isNotNull);
      expect(result.reason, isNull);
      final socket = await accepted;
      socket.destroy();
    } finally {
      await server.close();
    }
  });

  test('reports a refused TCP port as down with context', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();

    final result = await checkTcp(
      host: '127.0.0.1',
      port: port,
      now: now,
    );

    expect(result.status, HealthStatus.down);
    expect(result.reason, contains('TCP 127.0.0.1:$port'));
  });

  test('rejects invalid TCP targets without opening a socket', () async {
    final result = await checkTcp(
      host: '',
      port: 443,
      now: now,
    );

    expect(result.status, HealthStatus.down);
    expect(result.reason, 'TCP target host is empty');
  });
}
