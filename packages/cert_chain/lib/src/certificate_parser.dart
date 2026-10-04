import 'package:basic_utils/basic_utils.dart';
import 'package:discovery_core/discovery_core.dart';

/// Thrown when the platform payload cannot be turned into a chain.
class CertificateParseException implements Exception {
  const CertificateParseException(this.message);

  final String message;

  @override
  String toString() => 'CertificateParseException: $message';
}

/// Parses the platform payload into a [CertificateInfo].
///
/// Payload shape:
///
///     { "trusted": <bool>, "certs": ["<base64 DER>", ...] }
///
/// with the leaf first and any intermediates after it.
CertificateInfo certificateInfoFromPlatformMap(Map<Object?, Object?> payload) {
  final trusted = payload['trusted'] as bool?;
  final raw = (payload['certs'] as List<Object?>?) ?? const <Object?>[];
  final ders = raw.map((e) => e as String).toList(growable: false);

  if (ders.isEmpty) {
    throw const CertificateParseException(
      'The server presented no certificates.',
    );
  }

  final parsed = ders.map(_parseDer).toList(growable: false);
  return CertificateInfo(
    leaf: parsed.first.certificate,
    chain: parsed.skip(1).map((p) => p.certificate).toList(growable: false),
    sans: parsed.first.sans,
    presentedIntermediates: parsed.length - 1,
    trusted: trusted,
  );
}

class _Parsed {
  const _Parsed(this.certificate, this.sans);

  final ChainCertificate certificate;
  final List<String> sans;
}

_Parsed _parseDer(String base64Der) {
  try {
    final data = X509Utils.x509CertificateFromPem(_derToPem(base64Der));
    final tbs = data.tbsCertificate;
    if (tbs == null) {
      throw const CertificateParseException(
        'Certificate has no tbsCertificate.',
      );
    }
    return _Parsed(
      ChainCertificate(
        subject: _commonName(tbs.subject),
        issuer: _commonName(tbs.issuer),
        notBefore: tbs.validity.notBefore,
        notAfter: tbs.validity.notAfter,
        fingerprintSha256: data.sha256Thumbprint,
      ),
      tbs.extensions?.subjectAlternativNames ?? const <String>[],
    );
  } on CertificateParseException {
    rethrow;
  } catch (error) {
    throw CertificateParseException('Could not parse a certificate: $error');
  }
}

/// `basic_utils` keys distinguished-name parts by OID (`2.5.4.3`), so map the
/// common ones to their short names and prefer the common name.
const Map<String, String> _oidNames = <String, String>{
  '2.5.4.3': 'CN',
  '2.5.4.4': 'SN',
  '2.5.4.5': 'serialNumber',
  '2.5.4.6': 'C',
  '2.5.4.7': 'L',
  '2.5.4.8': 'ST',
  '2.5.4.10': 'O',
  '2.5.4.11': 'OU',
  '1.2.840.113549.1.9.1': 'E',
};

/// Prefers the common name, falling back to the full distinguished name.
String _commonName(Map<String, String?> parts) {
  final cn = parts['CN'] ?? parts['2.5.4.3'];
  if (cn != null && cn.isNotEmpty) return cn;
  return parts.entries
      .where((e) => e.value != null && e.value!.isNotEmpty)
      .map((e) => '${_oidNames[e.key] ?? e.key}=${e.value}')
      .join(', ');
}

/// Wraps base64 DER in a PEM envelope that [X509Utils] accepts.
String _derToPem(String base64Der) {
  final buffer = StringBuffer('-----BEGIN CERTIFICATE-----\n');
  for (var i = 0; i < base64Der.length; i += 64) {
    final end = i + 64 < base64Der.length ? i + 64 : base64Der.length;
    buffer.writeln(base64Der.substring(i, end));
  }
  buffer.writeln('-----END CERTIFICATE-----');
  return buffer.toString();
}
