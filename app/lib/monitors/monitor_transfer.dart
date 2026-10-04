import 'package:discovery_core/discovery_core.dart';

import 'monitor_config.dart';

/// One target per line, and nothing else.
///
/// The site list records what is watched, not how. Cadence, latency budgets,
/// failure thresholds, quiet hours, alert style and learned expiry dates are all
/// deliberately left out: they are local choices, some of them sensitive, and a
/// list that carried them would tie a shareable document to this app's internal
/// schema. Importing starts from the defaults, so a list stays readable and
/// editable by hand long after the app has moved on.
///
/// Recognised forms, and the monitor each produces:
///
///     example.com                  an HTTP monitor for the site
///     203.0.113.10                 an HTTP monitor for a host by address
///     db.example.com:5432          a TCP monitor
///     https://example.com/health   an HTTP monitor for one URL
///
/// Blank lines and lines starting with `#` are ignored, so the list can be
/// annotated without breaking it.
class MonitorTargetList {
  const MonitorTargetList(this.targets);

  /// A list pasted from a desktop editor may carry Windows line endings.
  static final RegExp _lineBreak = RegExp(r'\r?\n');

  static final RegExp _port = RegExp(r'^\d{1,5}$');

  /// The literal target text, in the order given.
  final List<String> targets;

  String encode() => targets.join('\n');

  /// Turns one line into a monitor, or null when it names nothing watchable.
  ///
  /// Anything this returns is a monitor the user could have typed into the
  /// add-monitor form. Since a backup is untrusted text, that equivalence is
  /// the rule: a line that could not have come from the app is refused rather
  /// than stored, so a pasted document cannot introduce a target the user never
  /// chose.
  static MonitorConfig? _parse(String line) {
    final raw = line.trim();
    if (raw.isEmpty || raw.startsWith('#')) return null;

    // A full URL is only recognised when a scheme is spelled out, so that a bare
    // host-and-path is never silently turned into a request the user did not
    // describe.
    if (raw.contains('://')) {
      final uri = Uri.tryParse(raw);
      if (uri == null) return null;
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      if (uri.host.isEmpty) return null;
      return MonitorConfig.forUrl(uri);
    }

    final tcp = _splitHostPort(raw);
    if (tcp != null) {
      final (host, port) = tcp;
      if (!_isWatchableHost(host)) return null;
      return MonitorConfig.forTcp(host, port);
    }

    // A line shaped like `host:port` that did not parse is a mistake, not a
    // hostname. Falling through would quietly turn a mistyped port into an HTTP
    // monitor for the host, which is a different target from the one written
    // down, so the line is refused instead.
    if (_looksLikeHostPort(raw)) return null;

    if (!_isWatchableHost(raw)) return null;
    return MonitorConfig.forDomain(raw);
  }

  /// Whether the line was written as a host and a port.
  ///
  /// A bracketed literal is only ever a host and a port. Otherwise a single
  /// colon marks one; more than one means a bare IPv6 address, which is a host.
  static bool _looksLikeHostPort(String raw) {
    if (raw.startsWith('[')) return raw.contains(']:');
    final colon = raw.indexOf(':');
    return colon != -1 && raw.indexOf(':', colon + 1) == -1;
  }

  /// Whether [host] could name something this app would check.
  ///
  /// [MonitorConfig.forDomain] is deliberately lenient — it falls back to the
  /// raw string, because the scan field should not refuse a half-typed name —
  /// so it cannot be used as a gate here. A list entry gets the stricter
  /// treatment instead.
  ///
  /// A dotted name goes through [DomainInput] so internationalised domains are
  /// accepted the same way the scan field accepts them. That parser requires at
  /// least two labels, so single-label names and bare addresses fall through to
  /// a direct shape check, which is also what keeps a LAN host usable.
  static bool _isWatchableHost(String host) {
    if (host.isEmpty || host.length > 253) return false;
    if (DomainInput.tryParse(host) != null) return true;
    if (host.contains(':')) return _ipv6Shape.hasMatch(host);
    return host
        .split('.')
        .every((label) => label.isNotEmpty && _label.hasMatch(label));
  }

  static final RegExp _label = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$',
  );

  /// A rough shape check for an IPv6 literal written without brackets.
  static final RegExp _ipv6Shape = RegExp(r'^[0-9A-Fa-f:.]+$');

  /// Reads [host]:[port] for a bare host, or null when the line is not that.
  ///
  /// Brackets are honoured so an IPv6 literal such as `[2001:db8::1]:443` is
  /// not mistaken for a host with a very long name.
  static (String, int)? _splitHostPort(String raw) {
    String host;
    String port;

    if (raw.startsWith('[')) {
      final close = raw.indexOf(']');
      if (close == -1 || close + 1 >= raw.length || raw[close + 1] != ':') {
        return null;
      }
      host = raw.substring(1, close);
      port = raw.substring(close + 2);
    } else {
      final colon = raw.indexOf(':');
      // More than one colon and no brackets means a bare IPv6 literal, which is
      // a host here, not a host and a port.
      if (colon == -1 || raw.indexOf(':', colon + 1) != -1) return null;
      host = raw.substring(0, colon);
      port = raw.substring(colon + 1);
    }

    if (host.isEmpty || port.isEmpty) return null;
    if (!_port.hasMatch(port)) return null;

    final value = int.tryParse(port);
    if (value == null || value < 1 || value > 65535) return null;
    return (host, value);
  }

  /// Reads a list, keeping the entries that name a watchable target.
  ///
  /// A line that cannot be read is skipped rather than failing the whole import,
  /// because the usual cause is one mistyped line in a list the user is editing.
  /// The count is reported so a skip is never silent. A list where nothing is
  /// readable is an error, since that means the text was not a list of targets.
  static MonitorTargets read(String source) {
    if (source.trim().isEmpty) {
      throw const MonitorTransferException('There is nothing to import.');
    }

    final monitors = <MonitorConfig>[];
    final seen = <String>{};
    final targets = <String>[];
    var unreadable = 0;

    for (final line in source.split(_lineBreak)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final monitor = _parse(trimmed);
      if (monitor == null) {
        unreadable++;
        continue;
      }
      if (!seen.add(monitor.id)) continue;

      monitors.add(monitor);
      targets.add(trimmed);
    }

    if (monitors.isEmpty) {
      throw MonitorTransferException(
        unreadable == 0
            ? 'That list has no sites in it.'
            : 'None of those lines name a site vigilant-core can watch.',
      );
    }

    return MonitorTargets(
      monitors: monitors,
      targets: targets,
      unreadable: unreadable,
    );
  }
}

/// The targets read from a list, and what could not be.
class MonitorTargets {
  const MonitorTargets({
    required this.monitors,
    required this.targets,
    this.unreadable = 0,
  });

  /// Freshly built monitors, in list order, duplicates removed.
  final List<MonitorConfig> monitors;

  /// The lines those monitors came from, for echoing back to the user.
  final List<String> targets;

  /// Lines present in the list that name nothing watchable.
  final int unreadable;
}

/// What an import would do, before it does it.
///
/// A preview exists because import is the one operation here that can add many
/// monitors at once, and a mistaken paste should not be discovered only by
/// looking at the resulting list.
class ImportPreview {
  const ImportPreview({
    required this.additions,
    required this.alreadyPresent,
    required this.unreadable,
  });

  /// Targets that are not on this device yet.
  final List<MonitorConfig> additions;

  /// How many lines named a monitor that already exists.
  final int alreadyPresent;

  /// How many lines could not be read.
  final int unreadable;

  /// Whether the import would change nothing, whether or not lines were
  /// unreadable. A list made entirely of known sites is not an error, it simply
  /// has nothing to add.
  bool get isEmpty => additions.isEmpty;

  int get total => additions.length + alreadyPresent + unreadable;
}

/// Works out what [document] would add to [existing].
///
/// Existing monitors are never modified. A backup is a starting point, not an
/// instruction, so an overlapping import adds what is missing and leaves the
/// devices own settings exactly as they are.
ImportPreview buildImportPreview({
  required MonitorTargets document,
  required Iterable<MonitorConfig> existing,
}) {
  final present = existing.map((m) => m.id).toSet();
  final additions = <MonitorConfig>[];
  var alreadyPresent = 0;

  for (final monitor in document.monitors) {
    if (present.contains(monitor.id)) {
      alreadyPresent++;
    } else {
      additions.add(monitor);
    }
  }

  return ImportPreview(
    additions: additions,
    alreadyPresent: alreadyPresent,
    unreadable: document.unreadable,
  );
}

/// A target line for [monitor], the inverse of `MonitorTargetList._parse`.
///
/// A monitor with nothing but a host is written as that host, so a list of sites
/// reads as a list of sites. The port and the URL form are kept only where they
/// are what makes the target distinct.
String targetLineFor(MonitorConfig monitor) {
  if (monitor.isTcp) {
    final port = monitor.targetPort;
    final host = monitor.targetHost;
    return port == null ? host : '$host:$port';
  }

  final uri = Uri.tryParse(monitor.url);
  if (uri != null && (uri.path != '/' && uri.path.isNotEmpty || uri.hasQuery)) {
    return monitor.url;
  }

  return monitor.targetHost.isEmpty ? monitor.name : monitor.targetHost;
}

/// A problem with the pasted text that the user can act on.
class MonitorTransferException implements Exception {
  const MonitorTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}
