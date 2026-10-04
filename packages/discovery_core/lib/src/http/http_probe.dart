import 'package:http/http.dart' as http;

import '../models/http_findings.dart';

/// Plain HTTPS probe with redirects disabled, to observe the redirect chain and
/// security headers. It deliberately does not follow redirects so each hop is
/// visible to the report.
class HttpProbe {
  HttpProbe({
    http.Client? client,
    this.maxRedirects = 10,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxRedirects;
  final Duration timeout;

  Future<HttpFindings> probe(String host) async {
    final chain = <String>[];
    var url = Uri.parse('https://$host/');

    var response = await _send(url);
    chain.add(url.toString());

    var redirects = 0;
    while (response.isRedirect && redirects < maxRedirects) {
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null) break;
      url = url.resolve(location);
      chain.add(url.toString());
      response = await _send(url);
      redirects++;
    }

    final headers = response.headers;
    final findings = HttpFindings(
      statusCode: response.statusCode,
      redirectChain: chain,
      hsts: headers['strict-transport-security'],
      headers: headers,
    );
    await response.stream.drain<void>();
    return findings;
  }

  Future<http.StreamedResponse> _send(Uri url) {
    final request = http.Request('GET', url)..followRedirects = false;
    return _client.send(request).timeout(timeout);
  }

  void close() => _client.close();
}
