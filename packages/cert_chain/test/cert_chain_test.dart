import 'package:cert_chain/cert_chain.dart';
import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePlatform extends CertChainPlatform with MockPlatformInterfaceMixin {
  String? lastHost;
  int? lastPort;

  @override
  Future<CertificateInfo> fetch(
    String host, {
    int port = 443,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    lastHost = host;
    lastPort = port;
    return const CertificateInfo(
      leaf: ChainCertificate(subject: 'leaf', issuer: 'ca'),
      chain: [ChainCertificate(subject: 'ca', issuer: 'root')],
      presentedIntermediates: 1,
      trusted: true,
    );
  }
}

void main() {
  test('delegates to the platform implementation', () async {
    final fake = _FakePlatform();
    CertChainPlatform.instance = fake;

    final info = await CertChain.fetch('example.com', port: 8443);

    expect(fake.lastHost, 'example.com');
    expect(fake.lastPort, 8443);
    expect(info.presentedIntermediates, 1);
    expect(info.trusted, isTrue);
  });
}
