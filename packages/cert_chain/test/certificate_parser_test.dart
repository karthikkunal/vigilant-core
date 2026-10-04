import 'dart:io';

import 'package:cert_chain/cert_chain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final der = File('test/fixtures/test_cert.der.b64').readAsStringSync().trim();

  test('parses a real certificate from the platform payload', () {
    final info = certificateInfoFromPlatformMap({
      'trusted': true,
      'certs': [der],
    });

    expect(info.trusted, isTrue);
    expect(info.leaf.subject, 'test.example.com');
    expect(info.leaf.issuer, 'test.example.com');
    expect(info.leaf.notBefore, isNotNull);
    expect(info.leaf.notAfter, isNotNull);
    expect(info.leaf.notAfter!.isAfter(info.leaf.notBefore!), isTrue);
    expect(info.leaf.fingerprintSha256, isNotNull);
    expect(
      info.sans,
      containsAll(<String>['test.example.com', 'www.test.example.com']),
    );
  });

  test('a leaf-only chain is flagged as a missing intermediate', () {
    final info = certificateInfoFromPlatformMap({
      'trusted': true,
      'certs': [der],
    });
    expect(info.presentedIntermediates, 0);
    expect(info.missingIntermediate, isTrue);
  });

  test('leaf is first and the rest become the chain', () {
    final info = certificateInfoFromPlatformMap({
      'trusted': false,
      'certs': [der, der],
    });
    expect(info.presentedIntermediates, 1);
    expect(info.chain, hasLength(1));
    expect(info.missingIntermediate, isFalse);
  });

  test('throws when no certificates are presented', () {
    expect(
      () => certificateInfoFromPlatformMap(const {
        'trusted': false,
        'certs': <Object?>[],
      }),
      throwsA(isA<CertificateParseException>()),
    );
  });

  test('throws on malformed DER', () {
    expect(
      () => certificateInfoFromPlatformMap(const {
        'trusted': false,
        'certs': ['not base64 der'],
      }),
      throwsA(isA<CertificateParseException>()),
    );
  });
}
