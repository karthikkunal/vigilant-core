import 'dart:convert';

import 'package:discovery_core/discovery_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The last scan's facts for a domain, kept on the device so the next scan of
/// the same domain can say what changed.
///
/// This is deliberately separate from the monitor repository. A baseline is
/// something you get by looking at a domain, not by agreeing to be paged about
/// it, so scanning a domain you never watch still builds history, and watching a
/// domain you never scanned does not.
abstract class DriftStore {
  /// The stored baseline for [host], or null when this domain has not been
  /// scanned on this device before.
  Future<DomainSnapshot?> baseline(String host);

  /// Records [snapshot] as the new baseline for [host].
  Future<void> record(String host, DomainSnapshot snapshot);

  /// Drops the baseline for [host], so the next scan starts a new one.
  Future<void> forget(String host);
}

/// Keeps baselines in one bounded document on the device.
///
/// `shared_preferences` rather than the store the monitors use: that one is
/// `flutter_foreground_task`'s data API, which has no browser implementation, and
/// a scan-time feature that silently stopped working in the web build would be
/// the same defect the monitor store already has.
class SharedPrefsDriftStore implements DriftStore {
  const SharedPrefsDriftStore();

  static const String _key = 'vigilant-core.drift.v1';

  /// How many domains to remember. A baseline is a few hundred bytes, so this
  /// is small, but it is still a list of domains the device is holding on to and
  /// it should not grow without bound.
  static const int maxDomains = 50;

  /// [SharedPreferencesAsync] rather than the cached
  /// `SharedPreferences.getInstance()`. This app runs a second isolate for the
  /// monitoring service, and the cached API gives each isolate its own copy, so a
  /// value written by one is invisible to the other.
  static final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<DomainSnapshot?> baseline(String host) async {
    return DomainSnapshot.read((await _document())[host]);
  }

  @override
  Future<void> record(String host, DomainSnapshot snapshot) async {
    final document = await _document();
    // Re-insert so the map order is recency order, which is what the cap evicts.
    document.remove(host);
    document[host] = snapshot.encode();
    while (document.length > maxDomains) {
      document.remove(document.keys.first);
    }
    await _write(document);
  }

  @override
  Future<void> forget(String host) async {
    final document = await _document();
    if (document.remove(host) == null) return;
    await _write(document);
  }

  Future<Map<String, String>> _document() async {
    final raw = await _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } on FormatException {
      // An unreadable document is dropped rather than repaired. Losing history
      // costs one scan's worth of comparison; guessing at it could invent a
      // change.
      return {};
    }
  }

  Future<void> _write(Map<String, String> document) async {
    if (document.isEmpty) {
      await _prefs.remove(_key);
    } else {
      await _prefs.setString(_key, jsonEncode(document));
    }
  }
}

/// Keeps baselines in memory for the lifetime of the process.
///
/// This is the store the tests use. It is also the shape a caller can fall back
/// to when on-device storage is unavailable: [DriftRecorder] already treats a
/// failing store as "no previous state" rather than an error, so a scan is never
/// at risk either way.
class InMemoryDriftStore implements DriftStore {
  final Map<String, DomainSnapshot> _baselines = {};

  @override
  Future<DomainSnapshot?> baseline(String host) async => _baselines[host];

  @override
  Future<void> record(String host, DomainSnapshot snapshot) async {
    _baselines.remove(host);
    _baselines[host] = snapshot;
  }

  @override
  Future<void> forget(String host) async {
    _baselines.remove(host);
  }
}

/// What a scan learned about change, and whether a baseline was kept.
///
/// [drift] is null on a first scan, which is not an error: there is nothing to
/// have changed yet. [baselineRecorded] is reported separately so the caller can
/// tell "this is the first time, and the baseline was kept" from "this device
/// would not store one". Only the first of those may be shown to the user as a
/// promise that scanning again will say something.
class DriftOutcome {
  const DriftOutcome({required this.baselineRecorded, this.drift});

  const DriftOutcome.unavailable() : baselineRecorded = false, drift = null;

  final bool baselineRecorded;
  final DriftReport? drift;

  bool get hasComparison => drift != null;
}

/// Runs a scan's drift bookkeeping, degrading to "no previous state" if the
/// device cannot store one.
///
/// Drift is an addition to a scan, never a precondition for it, so every
/// failure here is swallowed deliberately: the user still gets their report.
class DriftRecorder {
  const DriftRecorder(this.store);

  final DriftStore store;

  /// Compares [report] against the stored baseline and advances the baseline to
  /// this scan.
  ///
  /// The baseline advances on every scan, including the first — that is what
  /// makes the second scan able to say anything at all. It is not advanced from
  /// a report the caller might later discard, so this runs once per completed
  /// scan and never speculatively.
  Future<DriftOutcome> compare({
    required DomainReport report,
    CertificateInfo? certificate,
  }) async {
    try {
      final previous = await store.baseline(report.input.host);
      final drift = diffReports(
        report: report,
        previous: previous,
        certificate: certificate,
      );
      await store.record(report.input.host, drift.current);
      if (previous == null) {
        return const DriftOutcome(baselineRecorded: true);
      }
      return DriftOutcome(baselineRecorded: true, drift: drift);
    } on Object {
      // Storage that will not answer must not fail the scan, and must not be
      // reported as a stored baseline.
      return const DriftOutcome.unavailable();
    }
  }

  /// Drops the baseline for [host], so the next scan starts a new one.
  Future<bool> forget(String host) async {
    try {
      await store.forget(host);
      return true;
    } on Object {
      return false;
    }
  }
}
