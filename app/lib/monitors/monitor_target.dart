/// Resolving what a monitor should actually check, from one line of text.
///
/// The add-monitor screen used to be three screens: a domain form, a TCP form
/// and an assertion form, each with its own duplicated fields. This is the
/// decision those three screens each hard-coded, extracted so it can be tested
/// without a widget and so there is exactly one place that decides what a
/// target means.
library;

/// What the user asked to check.
enum MonitorTargetChoice {
  /// Work it out from the text and the presence of body rules.
  auto,

  /// Force an HTTP(S) check, even if the text looks like a socket.
  website,

  /// Force a raw TCP connect.
  tcp,
}

/// The kind of check a resolved target turns into.
enum ResolvedMonitorKind {
  /// HTTP(S) reachability and latency only.
  uptime,

  /// HTTP(S) plus literal response-body rules.
  assertion,

  /// A raw TCP connect, with no application payload.
  tcp,
}

/// A target the app knows how to check, and why it decided that.
class ResolvedMonitorTarget {
  const ResolvedMonitorTarget({
    required this.kind,
    required this.uri,
    required this.host,
    required this.port,
    required this.summary,
  });

  final ResolvedMonitorKind kind;

  /// Always carries an explicit scheme: `https://…` or `tcp://…`, so nothing
  /// downstream has to guess what a bare host meant.
  final Uri uri;

  final String host;
  final int? port;

  /// One line describing the decision, shown to the user so an inferred target
  /// is never a surprise.
  final String summary;

  bool get isTcp => kind == ResolvedMonitorKind.tcp;

  bool get hasAssertions => kind == ResolvedMonitorKind.assertion;

  /// Whether this is just `https://<host>/` — a plain website with no port, no
  /// path and no rules.
  ///
  /// Such a target is created through the same path as a domain added from a
  /// scan, so its id is the bare host in both cases. That matters: ids are the
  /// dedup key, and a monitor keyed `https://example.com` would sit beside a
  /// monitor keyed `example.com` for the same site.
  bool get isPlainWebsite {
    if (isTcp || uri.scheme != 'https') return false;
    if (uri.hasPort) return false;
    if (uri.path.isNotEmpty && uri.path != '/') return false;
    if (uri.hasQuery || uri.hasFragment) return false;
    return true;
  }
}

/// The outcome of interpreting a target line: either something checkable, or a
/// sentence explaining what is missing.
class TargetResolution {
  const TargetResolution._(this.target, this.error);

  const TargetResolution.resolved(ResolvedMonitorTarget target)
    : this._(target, null);

  const TargetResolution.rejected(String error) : this._(null, error);

  final ResolvedMonitorTarget? target;
  final String? error;

  bool get isResolved => target != null;
}

const int _minPort = 1;
const int _maxPort = 65535;

/// Interprets [raw] as a monitor target.
///
/// The inference is deliberately conservative, because a monitor that silently
/// checks the wrong thing is worse than one that asks:
///
/// * An explicit [choice] outranks the text. Picking TCP makes it a socket
///   even if the text looks like a URL, and picking website does the reverse.
/// * `tcp://host:port` is a socket; `http://` and `https://` are websites.
/// * With [MonitorTargetChoice.auto] and no scheme, `https://` is assumed, so
///   `example.com`, `example.com:8080` and `example.com/health` all work without
///   ceremony. **Bare `host:port` resolves to a website on that port, not a
///   socket**, because that is what typing a port usually means.
/// * Any other scheme is refused. Prefixing it would turn
///   `ftp://files.example.com` into a check of a host called `ftp`.
/// * Body rules, if any were added, make it an assertion check. They are
///   meaningless for TCP, so asking for both is rejected rather than silently
///   dropping the rules.
TargetResolution resolveMonitorTarget(
  String raw, {
  MonitorTargetChoice choice = MonitorTargetChoice.auto,
  int assertionCount = 0,
}) {
  final value = raw.trim();
  if (value.isEmpty) {
    return const TargetResolution.rejected(
      'Enter a domain, a URL, or a host and port.',
    );
  }

  final lowered = value.toLowerCase();
  final hasScheme = value.contains('://');
  final scheme = hasScheme ? lowered.split('://').first : '';

  // An explicit choice outranks what the text looks like: if the user picked a
  // kind, that is the answer, and the text only supplies the address. Guessing
  // over a stated choice is how a monitor ends up checking something nobody
  // asked for.
  final wantsTcp = switch (choice) {
    MonitorTargetChoice.tcp => true,
    MonitorTargetChoice.website => false,
    MonitorTargetChoice.auto => scheme == 'tcp',
  };

  if (wantsTcp) {
    if (assertionCount > 0) {
      return const TargetResolution.rejected(
        'Body rules are checked in an HTTP response, so they cannot be '
        'combined with a TCP port check. Remove the rules, or check a URL.',
      );
    }
    final body = scheme == 'tcp'
        ? value.substring(value.indexOf('://') + 3)
        : value;
    final uri = _tryParse('tcp://$body');
    if (uri == null || uri.host.isEmpty) {
      return const TargetResolution.rejected(
        'Enter a hostname or IP address, for example db.example.com:5432.',
      );
    }
    if (!uri.hasPort) {
      return const TargetResolution.rejected(
        'A TCP check needs a port, for example db.example.com:5432 or '
        'tcp://db.example.com:5432.',
      );
    }
    if (uri.port < _minPort || uri.port > _maxPort) {
      return const TargetResolution.rejected(
        'Enter a TCP port from $_minPort to $_maxPort.',
      );
    }
    return TargetResolution.resolved(
      ResolvedMonitorTarget(
        kind: ResolvedMonitorKind.tcp,
        uri: uri,
        host: uri.host,
        port: uri.port,
        summary: 'TCP port ${uri.host}:${uri.port} — connect, send nothing',
      ),
    );
  }

  // Website, because the text said http(s), because the user forced it, or
  // because there was no scheme to go on.
  //
  // A scheme that is neither http(s) nor tcp is refused here rather than
  // treated as a bare host. Prefixing it would turn `ftp://files.example.com`
  // into a check of host `ftp`, which is a wrong answer rather than a rejected
  // one.
  if (hasScheme && scheme != 'http' && scheme != 'https' && scheme != 'tcp') {
    return TargetResolution.rejected(
      'A ${scheme.isEmpty ? 'URL' : scheme}:// target is not something '
      'vigilant-core can check. Use http:// or https:// for a website, or '
      'tcp://host:port for a socket.',
    );
  }
  final web = scheme == 'tcp'
      ? 'https://${value.substring(value.indexOf('://') + 3)}'
      : (scheme == 'http' || scheme == 'https')
      ? value
      : 'https://$value';
  final uri = _tryParse(web);
  if (uri == null) {
    return const TargetResolution.rejected(
      'That does not look like a domain or URL. Enter something like '
      'example.com or https://example.com/health.',
    );
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return const TargetResolution.rejected(
      'Use an http:// or https:// URL. For a raw socket, use '
      'tcp://host:port.',
    );
  }
  if (uri.host.isEmpty) {
    return const TargetResolution.rejected('Enter a domain or a full URL.');
  }
  if (uri.hasPort && (uri.port < _minPort || uri.port > _maxPort)) {
    return const TargetResolution.rejected(
      'Enter a port from $_minPort to $_maxPort.',
    );
  }

  final rules = switch (assertionCount) {
    0 => '',
    1 => ' + 1 body rule',
    final count => ' + $count body rules',
  };
  return TargetResolution.resolved(
    ResolvedMonitorTarget(
      kind: assertionCount == 0
          ? ResolvedMonitorKind.uptime
          : ResolvedMonitorKind.assertion,
      uri: uri,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      summary: 'Website$rules — $uri',
    ),
  );
}

Uri? _tryParse(String value) {
  try {
    return Uri.parse(value);
  } on FormatException {
    return null;
  }
}
