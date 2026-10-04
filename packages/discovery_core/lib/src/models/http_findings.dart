/// Findings from a plain HTTPS request with redirects disabled.
class HttpFindings {
  const HttpFindings({
    this.statusCode,
    this.redirectChain = const [],
    this.hsts,
    this.headers = const {},
  });

  final int? statusCode;

  /// URLs visited, starting with the initial request.
  final List<String> redirectChain;

  /// The `Strict-Transport-Security` header value, if present.
  final String? hsts;

  final Map<String, String> headers;

  bool get hasHsts => hsts != null && hsts!.isNotEmpty;

  bool get redirectsToHttps =>
      redirectChain.isNotEmpty &&
      redirectChain.every((u) => u.toLowerCase().startsWith('https://'));

  int get redirectCount => redirectChain.length - 1;
}
