import 'package:cert_chain/cert_chain.dart';
import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../monitors/monitor_coordinator.dart';
import '../theme/vigilant-core_theme.dart';
import 'dns_resolver.dart';
import 'domain_report_view.dart';
import 'drift_store.dart';
import '../monitors/monitor_form.dart';

/// The domain discovery flow. The input is intentionally the only required
/// action; technical checks are progressively disclosed in the result.
class DomainScanScreen extends StatefulWidget {
  const DomainScanScreen({
    super.key,
    required this.coordinator,
    this.onWatched,
    this.drift,
  });

  final MonitorCoordinator coordinator;
  final VoidCallback? onWatched;

  /// Compares each scan against the last one. Injected by tests; production
  /// keeps baselines on the device.
  final DriftRecorder? drift;

  @override
  State<DomainScanScreen> createState() => _DomainScanScreenState();
}

class _DomainScanScreenState extends State<DomainScanScreen> {
  final TextEditingController _controller = TextEditingController();

  late final DriftRecorder _driftRecorder =
      widget.drift ?? const DriftRecorder(SharedPrefsDriftStore());

  /// Built from the user's resolver preference, which defaults to the device
  /// resolver so a scan does not disclose the domain to a public
  /// DNS-over-HTTPS service. Rebuilt when the preference changes.
  late DiscoveryEngine _engine;

  @override
  void initState() {
    super.initState();
    widget.coordinator.resolver.addListener(_rebuildEngine);
    _engine = _buildEngine();
  }

  @override
  void didUpdateWidget(covariant DomainScanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator) {
      oldWidget.coordinator.resolver.removeListener(_rebuildEngine);
      widget.coordinator.resolver.addListener(_rebuildEngine);
      _rebuildEngine();
    }
  }

  DiscoveryEngine _buildEngine() {
    final choice = resolveDns(widget.coordinator.resolver.value);
    return DiscoveryEngine(webMode: kIsWeb, dns: choice.client);
  }

  void _rebuildEngine() {
    if (!mounted) return;
    setState(() => _engine = _buildEngine());
  }

  bool _loading = false;

  /// Certificate Transparency is opt-in. It is the slowest probe and queries a
  /// third-party index, so a scan that nobody asked to enumerate subdomains
  /// should not disclose the domain to one.
  bool _includeSubdomains = false;
  bool _isWatching = false;
  bool _isWatchingDomains = false;
  bool _isWatched = false;
  DomainReport? _report;
  CertificateInfo? _certificate;

  /// What changed since the last scan of this domain, or null when there was
  /// nothing to compare against.
  DriftReport? _drift;

  /// True when this scan established the baseline a later scan will compare to.
  /// Distinct from "no drift" so the report can say so without claiming a
  /// comparison it did not make.
  bool _isBaseline = false;

  String? _error;

  /// Identifies the in-flight scan. Bumping it retires the previous scan, so a
  /// cancelled or superseded run can never write its result over newer state.
  int _scanGeneration = 0;

  @override
  void dispose() {
    widget.coordinator.resolver.removeListener(_rebuildEngine);
    _controller.dispose();
    super.dispose();
  }

  /// Stops tracking the running scan. The probes themselves are not abortable,
  /// so they are left to finish in the background with their result discarded:
  /// the user is never stranded on a spinner while the network is unresponsive.
  void _cancelScan() {
    setState(() {
      _scanGeneration++;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _discover() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _error = 'Enter a domain to scan.');
      return;
    }
    FocusScope.of(context).unfocus();

    final generation = ++_scanGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _report = null;
      _certificate = null;
      _drift = null;
      _isBaseline = false;
      _isWatched = false;
    });

    try {
      final input = DomainInput.tryParse(query);
      if (input == null) {
        throw const DiscoveryException('That is not a usable domain.');
      }

      // Discovery records per-probe failures in the report instead of throwing,
      // so this only trips on an unexpected fault. The error is captured rather
      // than discarded so the failure is still explained to the user.
      Object? discoverError;
      final report = await _engine
          .discover(input.host, includeCt: _includeSubdomains)
          .then<DomainReport?>(
            (value) => value,
            onError: (Object error) {
              discoverError = error;
              return null;
            },
          );
      if (!mounted || generation != _scanGeneration) return;

      // Resolved after the report settles so a chain capture that never returns
      // cannot hold back results the user is already waiting to read.
      final certificate = await _safeFetchCertificate(input.host);
      if (!mounted || generation != _scanGeneration) return;

      if (report == null) {
        throw discoverError ??
            const DiscoveryException('The scan could not be completed.');
      }

      var isWatched = false;
      try {
        final repository = await widget.coordinator.load();
        isWatched = repository.byId(report.input.host) != null;
      } catch (_) {
        // A scan is still useful when local persistence is unavailable.
      }
      if (!mounted || generation != _scanGeneration) return;

      // Compared after the report and the chain are both in hand: the TLS
      // posture is part of what a scan observed, and it is captured separately
      // from the engine. Drift never gates the scan, so this cannot fail it.
      final drift = await _driftRecorder.compare(
        report: report,
        certificate: certificate,
      );
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        _report = report;
        _certificate = certificate;
        _drift = drift.drift;
        _isBaseline = drift.baselineRecorded && drift.drift == null;
        _isWatched = isWatched;
      });
    } catch (error) {
      if (mounted && generation == _scanGeneration) {
        setState(() => _error = friendlyMonitorError(error));
      }
    } finally {
      if (mounted && generation == _scanGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<CertificateInfo?> _safeFetchCertificate(String host) async {
    try {
      return await CertChain.fetch(host);
    } catch (_) {
      // A missing native capture is represented as an unavailable check.
      return null;
    }
  }

  /// Drops what this device remembers about the scanned domain, so the next scan
  /// of it starts a fresh baseline instead of comparing against a history the
  /// user has asked to be rid of.
  Future<void> _forgetBaseline() async {
    final report = _report;
    if (report == null) return;
    final removed = await _driftRecorder.forget(report.input.host);
    if (!mounted) return;
    setState(() {
      _drift = null;
      _isBaseline = false;
    });
    _showMessage(
      removed
          ? 'Forgot what this device remembered about ${report.input.host}.'
          : 'Could not clear the stored history for ${report.input.host}.',
    );
  }

  Future<void> _watch() async {
    final report = _report;
    if (report == null || _isWatching) return;
    setState(() => _isWatching = true);
    try {
      await widget.coordinator.addDomain(
        report.input.host,
        registrationExpiry: report.registration?.expiresAt,
        certificateExpiry: _certificate?.leaf.notAfter,
      );
      if (!mounted) return;
      setState(() => _isWatched = true);
      _showMessage('Watching ${report.input.host}');
    } catch (error) {
      if (mounted) {
        _showMessage(
          'Could not start monitoring: ${friendlyMonitorError(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _isWatching = false);
    }
  }

  Future<void> _watchSubdomains(List<String> domains) async {
    if (_isWatchingDomains || domains.isEmpty) return;

    // Every host here sits under the scanned registrable domain, so the RDAP
    // result already describes all of them. TLS expiry deliberately is not
    // copied across: each host presents its own certificate, and the scanned
    // host's chain says nothing about a sibling's.
    final registrationExpiry = _report?.registration?.expiresAt;

    final unique = domains.toSet().toList(growable: false)..sort();
    setState(() => _isWatchingDomains = true);
    final added = <String>[];
    final existing = <String>[];
    final failed = <String>[];

    try {
      final repository = await widget.coordinator.load();
      for (final domain in unique) {
        if (repository.byId(domain) != null) {
          existing.add(domain);
          continue;
        }
        try {
          await widget.coordinator.addDomain(
            domain,
            registrationExpiry: registrationExpiry,
          );
          added.add(domain);
        } catch (_) {
          failed.add(domain);
        }
      }
    } catch (_) {
      failed.addAll(unique);
    }

    if (!mounted) return;
    setState(() => _isWatchingDomains = false);
    if (added.isEmpty && existing.isNotEmpty && failed.isEmpty) {
      _showMessage(
        'Already monitoring ${existing.length} selected subdomain(s).',
      );
      return;
    }

    final parts = <String>[
      if (added.isNotEmpty) 'Monitoring ${added.length} subdomain(s)',
      if (existing.isNotEmpty) '${existing.length} already watched',
      if (failed.isNotEmpty) '${failed.length} could not be added',
      if (added.isNotEmpty) 'TLS expiry unknown for these hosts',
    ];
    _showMessage(parts.join(' · '));
    if (added.isNotEmpty) widget.onWatched?.call();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.14,
                          ),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          Icons.travel_explore_rounded,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Scan a website or domain',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Know what is happening with a site you own or rely on before it becomes an incident.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildInputCard(context)),
          SliverToBoxAdapter(child: _buildScanStatus(context)),
          if (_error != null)
            SliverToBoxAdapter(
              child: _ErrorState(message: _error!, onRetry: _discover),
            ),
          if (_report != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: DomainReportView(
                  report: _report!,
                  certificate: _certificate,
                  drift: _drift,
                  isBaseline: _isBaseline,
                  onForgetBaseline: _forgetBaseline,
                  isWatching: _isWatching,
                  isWatchingDomains: _isWatchingDomains,
                  isWatched: _isWatched,
                  onWatch: _watch,
                  onWatchSubdomains: _watchSubdomains,
                  onOpenMonitor: widget.onWatched,
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _buildInputCard(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Find out what is happening',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Domain',
                  hintText: 'example.com',
                  prefixIcon: const Icon(Icons.public_outlined),
                  suffixIcon: IconButton(
                    tooltip: 'Run scan',
                    onPressed: _loading ? null : _discover,
                    icon: const Icon(Icons.arrow_forward_rounded),
                  ),
                ),
                onSubmitted: (_) => _discover(),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 17,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Enter a root domain or a subdomain, such as api.example.com.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _includeSubdomains,
                onChanged: _loading
                    ? null
                    : (value) =>
                          setState(() => _includeSubdomains = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Scan subdomains'),
                subtitle: const Text(
                  'Optional. Slower, and queries a public certificate index.',
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _loading ? null : _discover,
                icon: const Icon(Icons.radar_rounded),
                label: Text(_loading ? 'Scanning…' : 'Run scan'),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 18,
                    color: vigilant-corePalette.healthy,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Local-first checks. vigilant-core has no account or backend; this scan contacts '
                      'the selected site and the public lookup services needed to '
                      'perform discovery.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScanStatus(BuildContext context) {
    if (!_loading && _report == null && _error == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
        child: _ChecksExplainer(includeSubdomains: _includeSubdomains),
      );
    }
    if (!_loading) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Running checks on this device',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _cancelScan,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const LinearProgressIndicator(minHeight: 4),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  const _CheckHint(
                    icon: Icons.badge_outlined,
                    label: 'Registration',
                  ),
                  const _CheckHint(icon: Icons.dns_outlined, label: 'DNS'),
                  const _CheckHint(
                    icon: Icons.lock_outline,
                    label: 'TLS chain',
                  ),
                  const _CheckHint(icon: Icons.public_outlined, label: 'HTTP'),
                  if (_includeSubdomains)
                    const _CheckHint(
                      icon: Icons.verified_outlined,
                      label: 'CT logs',
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChecksExplainer extends StatelessWidget {
  const _ChecksExplainer({required this.includeSubdomains});

  /// Mirrors the option above it, so this card previews the scan that will
  /// actually run. Promising Certificate Transparency here while the probe is
  /// opt-out would claim a check the scan skips.
  final bool includeSubdomains;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What gets checked', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            const _ExplainerRow(
              icon: Icons.badge_outlined,
              title: 'Registration',
              detail: 'Expiry, registrar, nameservers, and risk status',
            ),
            const _ExplainerRow(
              icon: Icons.dns_outlined,
              title: 'DNS and email',
              detail: 'Records plus SPF, DMARC, DKIM, and CAA',
            ),
            const _ExplainerRow(
              icon: Icons.lock_outline,
              title: 'TLS and HTTP',
              detail: 'Certificate chain, trust, redirects, and headers',
            ),
            if (includeSubdomains)
              const _ExplainerRow(
                icon: Icons.verified_outlined,
                title: 'Certificate Transparency',
                detail: 'Public certificate history and discovered subdomains',
              ),
          ],
        ),
      ),
    );
  }
}

class _ExplainerRow extends StatelessWidget {
  const _ExplainerRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 21, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckHint extends StatelessWidget {
  const _CheckHint({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scan could not finish',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                    if (onRetry != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
