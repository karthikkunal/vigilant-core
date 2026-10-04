import 'dart:math' as math;

import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';

import '../ui/status_pill.dart';

/// Presents a discovery report as a verdict first, with technical details
/// available one section at a time.
class DomainReportView extends StatelessWidget {
  const DomainReportView({
    super.key,
    required this.report,
    required this.certificate,
    this.drift,
    this.isBaseline = false,
    this.onForgetBaseline,
    this.onWatch,
    this.onWatchSubdomains,
    this.onOpenMonitor,
    this.isWatching = false,
    this.isWatchingDomains = false,
    this.isWatched = false,
  });

  final DomainReport report;
  final CertificateInfo? certificate;

  /// What changed since the last scan of this domain, or null when there was no
  /// earlier scan to compare against.
  final DriftReport? drift;

  /// Whether this scan is the one that established the baseline. Kept separate
  /// from a null [drift] so the view can say "scan again to see what changed"
  /// only when a baseline really was kept.
  final bool isBaseline;

  /// Drops the stored baseline for this domain.
  final VoidCallback? onForgetBaseline;

  final VoidCallback? onWatch;
  final Future<void> Function(List<String> domains)? onWatchSubdomains;
  final VoidCallback? onOpenMonitor;
  final bool isWatching;
  final bool isWatchingDomains;
  final bool isWatched;

  @override
  Widget build(BuildContext context) {
    final assessment = _ReportAssessment.from(report, certificate);
    final findings = _findings(report, certificate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReportHero(
          report: report,
          assessment: assessment,
          onWatch: onWatch,
          onOpenMonitor: onOpenMonitor,
          isWatching: isWatching,
          isWatched: isWatched,
        ),
        if (drift != null || isBaseline) ...[
          const SizedBox(height: 16),
          _DriftSection(
            drift: drift,
            isBaseline: isBaseline,
            onForget: onForgetBaseline,
          ),
        ],
        const SizedBox(height: 16),
        Text('At a glance', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            // Tiles size to their own content rather than a fixed grid extent,
            // so a larger text scale grows the tile instead of overflowing it.
            const spacing = 10.0;
            final columns = constraints.maxWidth >= 560 ? 3 : 2;
            final tileWidth = math.max(
              0.0,
              (constraints.maxWidth - spacing * (columns - 1)) / columns,
            );
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final finding in findings)
                  SizedBox(
                    width: tileWidth,
                    child: _FindingTile(finding: finding),
                  ),
              ],
            );
          },
        ),
        if (report.ct?.subdomains.isNotEmpty ?? false) ...[
          const SizedBox(height: 20),
          _SubdomainSelectionCard(
            key: ValueKey(
              '${report.fetchedAt.microsecondsSinceEpoch}:'
              '${report.ct!.source}:${report.ct!.subdomains.length}',
            ),
            subdomains: report.ct!.subdomains.toList()..sort(),
            rootDomain: report.input.registrable,
            busy: isWatchingDomains,
            partial: report.ct!.isPartial,
            onWatch: onWatchSubdomains,
          ),
        ],
        const SizedBox(height: 24),
        Text('Detailed checks', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        _registrationSection(context, report),
        _certificateSection(context, certificate),
        _emailSection(context, report.emailAuth),
        _dnsSection(context, report.dns),
        _ctSection(context, report),
        _httpSection(context, report.http),
        if (report.errors.isNotEmpty) _warningsSection(context, report.errors),
        if (report.providerStatuses.isNotEmpty)
          _ProviderStatusCard(statuses: report.providerStatuses),
      ],
    );
  }

  Widget _registrationSection(BuildContext context, DomainReport report) {
    final registration = report.registration;
    if (registration == null) {
      return _SectionCard(
        title: 'Registration',
        icon: Icons.badge_outlined,
        summary: 'No registration data was returned',
        children: const [
          _InfoNote(
            icon: Icons.info_outline_rounded,
            message: 'This registrar or TLD may not publish RDAP data.',
          ),
        ],
      );
    }

    final now = DateTime.now().toUtc();
    final days = registration.daysUntilExpiry(now);
    return _SectionCard(
      title: 'Registration',
      icon: Icons.badge_outlined,
      summary: days == null ? 'Expiry date unavailable' : _expiryText(days),
      initiallyExpanded: true,
      children: [
        _KeyValue(label: 'Expires', value: _date(registration.expiresAt)),
        if (days != null)
          _KeyValue(label: 'Time remaining', value: _daysText(days)),
        if (registration.registrar != null)
          _KeyValue(label: 'Registrar', value: registration.registrar!),
        if (registration.nameservers.isNotEmpty)
          _KeyValue(
            label: 'Nameservers',
            value: registration.nameservers.join('\n'),
          ),
        if (registration.statuses.isNotEmpty)
          _KeyValue(label: 'Status', value: registration.statuses.join('\n')),
        if (registration.hasRiskStatus)
          const _InfoNote(
            icon: Icons.warning_amber_rounded,
            message: 'This domain carries a deletion or transfer status code.',
            tone: StatusTone.attention,
          ),
      ],
    );
  }

  Widget _certificateSection(
    BuildContext context,
    CertificateInfo? certificate,
  ) {
    if (certificate == null) {
      return const _SectionCard(
        title: 'TLS certificate',
        icon: Icons.lock_outline_rounded,
        summary: 'Chain could not be captured',
        children: [
          _InfoNote(
            icon: Icons.info_outline_rounded,
            message: 'The app could not capture the server-presented chain on this device.',
          ),
        ],
      );
    }

    final now = DateTime.now().toUtc();
    final days = certificate.daysRemaining(now);
    final intermediateExpired = certificate.hasExpiredIntermediate(now);
    final children = <Widget>[
      _KeyValue(label: 'Subject', value: certificate.leaf.subject),
      _KeyValue(label: 'Issuer', value: certificate.leaf.issuer),
      _KeyValue(label: 'Expires', value: _date(certificate.leaf.notAfter)),
      if (days != null)
        _KeyValue(label: 'Time remaining', value: _daysText(days)),
      _KeyValue(
        label: 'Presented chain',
        value:
            '${certificate.presentedIntermediates} intermediate certificate(s)',
      ),
      _KeyValue(
        label: 'Platform trust',
        value: certificate.trusted == null
            ? 'Unknown'
            : certificate.trusted!
            ? 'Accepted'
            : 'Not accepted',
      ),
      if (certificate.sans.isNotEmpty)
        _KeyValue(
          label: 'Subject alternatives',
          value: certificate.sans.join('\n'),
        ),
    ];

    if (certificate.missingIntermediate) {
      children.add(
        const _InfoNote(
          icon: Icons.warning_amber_rounded,
          message: 'No intermediate certificate was presented. Browsers may hide the problem while older Android clients fail.',
          tone: StatusTone.attention,
        ),
      );
    }
    if (intermediateExpired) {
      children.add(
        const _InfoNote(
          icon: Icons.error_outline_rounded,
          message: 'An intermediate certificate in the chain has expired.',
          tone: StatusTone.critical,
        ),
      );
    }
    if (certificate.trusted == false) {
      children.add(
        const _InfoNote(
          icon: Icons.error_outline_rounded,
          message: 'The platform trust store did not accept this chain.',
          tone: StatusTone.critical,
        ),
      );
    }

    return _SectionCard(
      title: 'TLS certificate',
      icon: Icons.lock_outline_rounded,
      summary: days == null ? 'Expiry date unavailable' : _expiryText(days),
      initiallyExpanded: true,
      children: children,
    );
  }

  Widget _emailSection(BuildContext context, EmailAuthInfo? email) {
    if (email == null) {
      return const _SectionCard(
        title: 'Email authentication',
        icon: Icons.mail_outline_rounded,
        summary: 'No email records found',
        children: [
          _InfoNote(
            icon: Icons.info_outline_rounded,
            message: 'SPF, DMARC, DKIM, and CAA records are not available for this domain.',
          ),
        ],
      );
    }

    return _SectionCard(
      title: 'Email authentication',
      icon: Icons.mail_outline_rounded,
      summary: '${email.score}/3 core records found',
      children: [
        _KeyValue(label: 'SPF', value: email.hasSpf ? 'Present' : 'Missing'),
        _KeyValue(
          label: 'DMARC',
          value: email.hasDmarc ? 'Present' : 'Missing',
        ),
        _KeyValue(
          label: 'DKIM',
          value: email.dkim.isEmpty
              ? 'No selectors found'
              : email.dkim.keys.join('\n'),
        ),
        _KeyValue(
          label: 'CAA',
          value: email.caa.isEmpty ? 'None found' : email.caa.join('\n'),
        ),
      ],
    );
  }

  Widget _dnsSection(BuildContext context, DnsRecordSet dns) {
    if (dns.types.isEmpty) {
      return const _SectionCard(
        title: 'DNS',
        icon: Icons.dns_outlined,
        summary: 'No records returned',
        children: [
          _InfoNote(
            icon: Icons.info_outline_rounded,
            message: 'The DNS probe completed without a usable answer set.',
          ),
        ],
      );
    }

    return _SectionCard(
      title: 'DNS',
      icon: Icons.dns_outlined,
      summary: '${dns.types.length} record types · ${dns.types.join(', ')}',
      children: [
        for (final type in dns.types) ...[
          _KeyValue(label: type, value: '${dns.ofType(type).length} record(s)'),
          for (final record in dns.ofType(type))
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 8),
              child: SelectableText(
                '${record.name}  ·  TTL ${record.ttl}\n${record.data}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _ctSection(BuildContext context, DomainReport report) {
    final ct = report.ct;
    if (ct == null) {
      // A probe the user declined is not a probe that failed. Reporting "not
      // available for this domain" would claim a fault that does not exist.
      if (!report.includeCt) {
        return const _SectionCard(
          title: 'Certificate Transparency',
          icon: Icons.verified_outlined,
          summary: 'Not requested for this scan',
          children: [
            _InfoNote(
              icon: Icons.info_outline_rounded,
              message: 'Turn on "Scan subdomains" to look for hosts named in publicly logged certificates.',
            ),
          ],
        );
      }
      return const _SectionCard(
        title: 'Certificate Transparency',
        icon: Icons.verified_outlined,
        summary: 'No transparency data returned',
        children: [
          _InfoNote(
            icon: Icons.info_outline_rounded,
            message: 'Certificate Transparency results were not available for this domain.',
          ),
        ],
      );
    }

    final subdomains = ct.subdomains.toList()..sort();
    final partialSuffix = ct.isPartial ? '+' : '';
    final entryCount = '${ct.entryCount}$partialSuffix';
    return _SectionCard(
      title: 'Certificate Transparency',
      icon: Icons.verified_outlined,
      summary:
          '$entryCount log entries · ${subdomains.length}$partialSuffix subdomains',
      children: [
        _KeyValue(label: 'Log entries', value: entryCount),
        for (final entry in ct.entries.take(5))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _KeyValue(
              label: entry.commonName,
              value: '${entry.issuerName}\n${_date(entry.notAfter)}',
            ),
          ),
        if (ct.isPartial)
          const _InfoNote(
            icon: Icons.info_outline_rounded,
            message:
                'Only the available portion of the source history is shown.',
          ),
      ],
    );
  }

  Widget _httpSection(BuildContext context, HttpFindings? http) {
    if (http == null) {
      return const _SectionCard(
        title: 'HTTP',
        icon: Icons.public_outlined,
        summary: 'No HTTP response captured',
        children: [
          _InfoNote(
            icon: Icons.info_outline_rounded,
            message: 'The HTTPS probe did not produce a response to inspect.',
          ),
        ],
      );
    }

    return _SectionCard(
      title: 'HTTP',
      icon: Icons.public_outlined,
      summary: http.statusCode == null
          ? 'No status code'
          : 'HTTP ${http.statusCode}',
      children: [
        _KeyValue(label: 'Status', value: '${http.statusCode ?? '—'}'),
        _KeyValue(label: 'Redirects', value: '${http.redirectCount}'),
        _KeyValue(label: 'HSTS', value: http.hasHsts ? 'Present' : 'Missing'),
        if (http.hsts != null)
          _KeyValue(label: 'HSTS value', value: http.hsts!),
        if (http.redirectChain.isNotEmpty)
          _KeyValue(
            label: 'Redirect chain',
            value: http.redirectChain.join('\n'),
          ),
      ],
    );
  }

  Widget _warningsSection(BuildContext context, List<ProbeError> errors) {
    return _SectionCard(
      title: 'Probe warnings',
      icon: Icons.warning_amber_rounded,
      summary: '${errors.length} check(s) completed with warnings',
      initiallyExpanded: true,
      children: [
        for (final error in errors)
          _InfoNote(
            icon: Icons.info_outline_rounded,
            message: '${error.probe}: ${error.message}',
            tone: StatusTone.attention,
          ),
      ],
    );
  }
}

class _ReportHero extends StatelessWidget {
  const _ReportHero({
    required this.report,
    required this.assessment,
    required this.onWatch,
    required this.onOpenMonitor,
    required this.isWatching,
    required this.isWatched,
  });

  final DomainReport report;
  final _ReportAssessment assessment;
  final VoidCallback? onWatch;
  final VoidCallback? onOpenMonitor;
  final bool isWatching;
  final bool isWatched;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Scan result',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        report.input.registrable,
                        style: theme.textTheme.headlineSmall,
                      ),
                      if (report.input.host != report.input.registrable) ...[
                        const SizedBox(height: 4),
                        Text(
                          report.input.host,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                StatusPill(tone: assessment.tone),
              ],
            ),
            const SizedBox(height: 20),
            Text(assessment.headline, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(assessment.detail, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Checked ${_dateTime(report.fetchedAt)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (onWatch != null || onOpenMonitor != null) ...[
              const SizedBox(height: 20),
              if (isWatched && onOpenMonitor != null)
                FilledButton.icon(
                  onPressed: onOpenMonitor,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open monitor'),
                )
              else
                FilledButton.icon(
                  onPressed: isWatching ? null : onWatch,
                  icon: isWatching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_alert_outlined),
                  label: Text(
                    isWatching
                        ? 'Starting monitor…'
                        : report.input.host == report.input.registrable
                        ? 'Monitor this domain'
                        : 'Monitor this subdomain',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.finding});

  final _Finding finding;

  @override
  Widget build(BuildContext context) {
    final color = finding.tone.color(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        // A minimum keeps short tiles visually even; there is deliberately no
        // maximum, so the tile can grow with the user's text scale.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(finding.icon, size: 17, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      finding.label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                finding.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (finding.detail != null) ...[
                const SizedBox(height: 3),
                Text(
                  finding.detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SubdomainSelectionCard extends StatefulWidget {
  const _SubdomainSelectionCard({
    super.key,
    required this.subdomains,
    required this.rootDomain,
    required this.busy,
    this.partial = false,
    this.onWatch,
  });

  final List<String> subdomains;
  final String rootDomain;
  final bool busy;
  final bool partial;
  final Future<void> Function(List<String> domains)? onWatch;

  @override
  State<_SubdomainSelectionCard> createState() =>
      _SubdomainSelectionCardState();
}

class _SubdomainSelectionCardState extends State<_SubdomainSelectionCard> {
  /// Upper bound on tree rows built in one pass. Certificate Transparency can
  /// return thousands of hosts for a single domain, and the list is laid out
  /// eagerly because it shares the page's scroll view.
  static const int _initialRowLimit = 150;

  final Set<String> _selected = {};
  final Set<String> _collapsed = {};
  final TextEditingController _filterController = TextEditingController();
  int _rowLimit = _initialRowLimit;

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  List<String> get _visibleSubdomains {
    final query = _filterController.text.trim().toLowerCase();
    if (query.isEmpty) return widget.subdomains;
    return widget.subdomains
        .where((subdomain) => subdomain.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Map<int, int> _levelCounts() {
    final counts = <int, int>{};
    final suffix = '.${widget.rootDomain}';
    for (final host in widget.subdomains) {
      if (!host.endsWith(suffix)) continue;
      final relative = host.substring(0, host.length - suffix.length);
      final labels = relative.split('.');
      if (relative.isEmpty || labels.any((label) => label.isEmpty)) continue;
      final level = labels.length;
      counts[level] = (counts[level] ?? 0) + 1;
    }
    return counts;
  }

  bool get _allVisibleSelected =>
      _visibleSubdomains.isNotEmpty &&
      _visibleSubdomains.every(_selected.contains);

  void _toggle(String subdomain, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(subdomain);
      } else {
        _selected.remove(subdomain);
      }
    });
  }

  void _toggleVisible() {
    final visible = _visibleSubdomains;
    setState(() {
      if (_allVisibleSelected) {
        _selected.removeAll(visible);
      } else {
        _selected.addAll(visible);
      }
    });
  }

  Future<void> _addSelected() async {
    final onWatch = widget.onWatch;
    if (_selected.isEmpty || onWatch == null) return;
    final selected = _selected.toList()..sort();
    await onWatch(selected);
  }

  _SubdomainTreeNode _buildTree(List<String> subdomains) {
    final root = _SubdomainTreeNode(
      label: widget.rootDomain,
      path: widget.rootDomain,
      domain: widget.rootDomain,
    );
    final suffix = '.${widget.rootDomain}';

    for (final host in subdomains) {
      if (!host.endsWith(suffix)) continue;
      final relative = host.substring(0, host.length - suffix.length);
      if (relative.isEmpty ||
          relative.split('.').any((label) => label.isEmpty)) {
        continue;
      }

      var node = root;
      final pathParts = <String>[];
      var parentDomain = widget.rootDomain;
      // DNS hierarchy grows from right to left: corpus.example.com is the
      // parent of 120.corpus.example.com, not the other way around.
      for (final label in relative.split('.').reversed) {
        pathParts.add(label);
        final path = pathParts.join('.');
        final domain = '$label.$parentDomain';
        node = node.children.putIfAbsent(
          label,
          () => _SubdomainTreeNode(label: label, path: path, domain: domain),
        );
        parentDomain = domain;
      }
      node.host = host;
    }

    return root;
  }

  List<String> _branchPaths(_SubdomainTreeNode node) {
    final paths = <String>[];
    void visit(_SubdomainTreeNode current) {
      if (current.children.isEmpty) return;
      paths.add(current.path);
      final children = current.children.values.toList()
        ..sort((a, b) => a.label.compareTo(b.label));
      for (final child in children) {
        visit(child);
      }
    }

    visit(node);
    return paths;
  }

  List<_SubdomainTreeRow> _flattenTree(_SubdomainTreeNode root) {
    final rows = <_SubdomainTreeRow>[];
    void visit(_SubdomainTreeNode node, int depth) {
      rows.add(_SubdomainTreeRow(node: node, depth: depth));
      if (node.children.isEmpty || _collapsed.contains(node.path)) return;
      final children = node.children.values.toList()
        ..sort((a, b) => a.label.compareTo(b.label));
      for (final child in children) {
        visit(child, depth + 1);
      }
    }

    visit(root, 0);
    return rows;
  }

  void _toggleNode(_SubdomainTreeNode node) {
    if (node.children.isEmpty) return;
    setState(() {
      if (!_collapsed.remove(node.path)) _collapsed.add(node.path);
    });
  }

  void _toggleAllBranches(_SubdomainTreeNode root) {
    final branchPaths = _branchPaths(root);
    setState(() {
      if (branchPaths.every(_collapsed.contains)) {
        _collapsed.clear();
      } else {
        _collapsed
          ..clear()
          ..addAll(branchPaths.where((path) => path != root.path));
      }
    });
  }

  Widget _buildTreeRow(
    BuildContext context,
    _SubdomainTreeRow row, {
    required bool canWatch,
    required ThemeData theme,
  }) {
    final node = row.node;
    final isCollapsed = _collapsed.contains(node.path);
    final title = node.host ?? node.domain;
    var titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: node.children.isEmpty ? FontWeight.normal : FontWeight.w600,
    );
    if (node.host != null) {
      titleStyle = titleStyle?.copyWith(fontFamily: 'monospace');
    }
    final contentPadding = EdgeInsets.only(left: row.depth * 18.0);

    if (node.host != null) {
      final host = node.host!;
      return CheckboxListTile(
        value: _selected.contains(host),
        onChanged: widget.busy || !canWatch
            ? null
            : (value) => _toggle(host, value ?? false),
        secondary: node.children.isEmpty
            ? null
            : IconButton(
                tooltip: isCollapsed ? 'Expand branch' : 'Collapse branch',
                onPressed: () => _toggleNode(node),
                icon: Icon(
                  isCollapsed ? Icons.chevron_right : Icons.expand_more,
                ),
              ),
        dense: true,
        contentPadding: contentPadding,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
      );
    }

    return ListTile(
      onTap: node.children.isEmpty ? null : () => _toggleNode(node),
      dense: true,
      contentPadding: contentPadding,
      leading: Icon(
        isCollapsed ? Icons.chevron_right : Icons.expand_more,
        size: 20,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visibleSubdomains;
    final canWatch = widget.onWatch != null;
    final countLabel =
        '${widget.subdomains.length}${widget.partial ? '+' : ''}';
    final levelCounts = _levelCounts();
    final levels = levelCounts.keys.toList()..sort();
    final tree = _buildTree(visible);
    final treeRows = _flattenTree(tree);
    final branchPaths = _branchPaths(tree);
    final allBranchesExpanded = branchPaths.every(
      (path) => !_collapsed.contains(path),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Subdomains found · $countLabel',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        canWatch
                            ? 'Nested tree · Select hosts to add to your monitors.'
                            : 'Nested tree · Hosts found in public sources.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (canWatch)
                  TextButton(
                    onPressed: widget.busy || visible.isEmpty
                        ? null
                        : _toggleVisible,
                    child: Text(_allVisibleSelected ? 'Clear' : 'Select all'),
                  ),
              ],
            ),
            if (widget.partial) ...[
              const SizedBox(height: 8),
              Text(
                'More hosts may be available; the source stopped early.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (levelCounts.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.55,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bar_chart_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Relative levels',
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Hosts grouped by depth below ${widget.rootDomain}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final level in levels)
                          Chip(
                            label: Text(
                              'Level $level · ${levelCounts[level]} hosts',
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (widget.subdomains.length > 8) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _filterController,
                onChanged: (_) => setState(() {
                  _collapsed.clear();
                  _rowLimit = _initialRowLimit;
                }),
                decoration: InputDecoration(
                  hintText: 'Filter $countLabel subdomains',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (visible.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _toggleAllBranches(tree),
                  icon: Icon(
                    allBranchesExpanded ? Icons.unfold_less : Icons.unfold_more,
                  ),
                  label: Text(
                    allBranchesExpanded ? 'Collapse tree' : 'Expand tree',
                  ),
                ),
              ),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: Text(
                    'No subdomains match that filter.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else ...[
              // The tree shares the page's scroll view. A nested scrollable
              // would win the vertical drag gesture and trap the user inside
              // this card, so the rows are laid out at their natural height.
              // Very large results are capped to keep the row build bounded.
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: math.min(treeRows.length, _rowLimit),
                itemBuilder: (context, index) => _buildTreeRow(
                  context,
                  treeRows[index],
                  canWatch: canWatch,
                  theme: theme,
                ),
              ),
              if (treeRows.length > _rowLimit) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _rowLimit = treeRows.length),
                    icon: const Icon(Icons.unfold_more_rounded),
                    label: Text('Show all ${treeRows.length} hosts'),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: widget.busy || !canWatch || _selected.isEmpty
                  ? null
                  : _addSelected,
              icon: widget.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      canWatch
                          ? Icons.add_alert_outlined
                          : Icons.visibility_outlined,
                    ),
              label: Text(
                widget.busy
                    ? 'Adding selected…'
                    : !canWatch
                    ? 'Read-only list'
                    : _selected.isEmpty
                    ? 'Select subdomains'
                    : 'Add ${_selected.length} to monitors',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubdomainTreeNode {
  _SubdomainTreeNode({
    required this.label,
    required this.path,
    required this.domain,
  });

  final String label;
  final String path;
  final String domain;
  String? host;
  final Map<String, _SubdomainTreeNode> children = {};
}

class _SubdomainTreeRow {
  const _SubdomainTreeRow({required this.node, required this.depth});

  final _SubdomainTreeNode node;
  final int depth;
}

/// Plain-language names for the facts a scan records.
///
/// The raw keys are an implementation detail (`registration.expiresAt`), so this
/// is where they become something a person can act on. A key with no entry here
/// still renders — an unlabelled fact is better than a silently dropped one.
String _driftLabel(String key) {
  const labels = <String, String>{
    'registration.expiresAt': 'Registration expires',
    'registration.registrar': 'Registrar',
    'registration.statuses': 'Registration status',
    'registration.nameservers': 'Name servers',
    'email.spf': 'SPF policy',
    'email.dmarc': 'DMARC policy',
    'email.caa': 'CA policy',
    'ct.entryCount': 'Certificate log entries',
    'ct.subdomains': 'Subdomains seen in certificates',
    'http.statusCode': 'HTTP status',
    'http.hsts': 'HSTS',
    'http.redirectChain': 'Redirect chain',
    'cert.notAfter': 'Certificate expires',
    'cert.issuer': 'Certificate issuer',
    'cert.intermediates': 'Intermediate certificates',
    'cert.trusted': 'Chain trusted by this device',
  };
  if (labels.containsKey(key)) return labels[key]!;
  if (key.startsWith('dns.')) {
    const types = <String, String>{
      'A': 'Addresses (A)',
      'AAAA': 'Addresses (AAAA)',
      'MX': 'Mail exchangers',
      'NS': 'Name servers',
      'TXT': 'TXT records',
      'CAA': 'CA records',
      'CNAME': 'Aliases (CNAME)',
      'SOA': 'Zone authority (SOA)',
    };
    final type = key.substring(4);
    return types[type] ?? 'DNS $type records';
  }
  return key;
}

/// Renders a stored fact value for a person.
String _driftValue(String? value) {
  if (value == null) return 'not set';
  // `http.hsts` uses an explicit sentinel for "the header was absent", which is
  // a real observation rather than an unknown.
  if (value == 'missing') return 'not set';
  if (value == 'true') return 'yes';
  if (value == 'false') return 'no';
  final asDate = DateTime.tryParse(value);
  if (asDate != null) {
    return '${asDate.year}-${_two(asDate.month)}-${_two(asDate.day)}';
  }
  // Long comma-joined lists are truncated rather than wrapped over five lines.
  const limit = 120;
  if (value.length > limit) {
    return '${value.substring(0, limit - 1).trimRight()}…';
  }
  return value;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Areas a scan can compare, in the order they are named to the user when a
/// scan had to skip some of them.
const _allDriftAreas = <String>[
  'registration',
  'dns',
  'email',
  'ct',
  'http',
  'cert',
];

const _driftAreaNames = <String, String>{
  'registration': 'registration',
  'dns': 'DNS',
  'email': 'email authentication',
  'ct': 'Certificate Transparency',
  'http': 'the HTTPS response',
  'cert': 'the TLS certificate',
};

/// What changed between this scan and the last one.
///
/// Deliberately not an [ExpansionTile]: a change to a domain's delegation or
/// mail policy is the reason to open this screen, so it does not belong behind a
/// collapsed header. The routine changes that come with it do.
class _DriftSection extends StatelessWidget {
  const _DriftSection({
    required this.drift,
    required this.isBaseline,
    this.onForget,
  });

  final DriftReport? drift;
  final bool isBaseline;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = drift;
    final previousAt = report?.previous?.at;

    final String title;
    final String summary;
    if (report == null) {
      title = 'First scan on this device';
      summary =
          'Saved as the baseline for this domain. Scan it again and this screen '
          'will say what changed.';
    } else if (report.hasChanges) {
      final notable = report.notable.length;
      title = 'Changed since ${_when(previousAt)}';
      summary = notable == 0
          ? '${report.differences.length} change(s), none of them security-relevant'
          : '$notable of ${report.differences.length} change(s) worth acting on';
    } else {
      title = 'No change since ${_when(previousAt)}';
      summary = 'Everything this scan checked matched the last one.';
    }

    final notable = report?.notable ?? const <Difference>[];
    final routine = report == null
        ? const <Difference>[]
        : report.differences.where((d) => !d.isNotable).toList(growable: false);
    final skipped = report == null
        ? const <String>[]
        : _allDriftAreas
              .where((area) => !report.observed.contains(area))
              .toList(growable: false);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  report == null
                      ? Icons.flag_outlined
                      : report.hasChanges
                      ? Icons.change_history_outlined
                      : Icons.check_circle_outline,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(summary, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            for (final difference in notable) _DriftRow(difference: difference),
            if (routine.isNotEmpty)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text(
                    '${routine.length} other change(s)',
                    style: theme.textTheme.bodySmall,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final difference in routine)
                            _DriftRow(difference: difference),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (skipped.isNotEmpty)
              _InfoNote(
                icon: Icons.visibility_off_outlined,
                message:
                    'Not compared: ${skipped.map((a) => _driftAreaNames[a] ?? a).join(', ')}. '
                    'A scan only claims a change where it actually looked.',
              ),
            if (onForget != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onForget,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Forget this baseline'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _when(DateTime? at) {
    if (at == null) return 'the last scan';
    final local = at.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)}';
  }
}

class _DriftRow extends StatelessWidget {
  const _DriftRow({required this.difference});

  final Difference difference;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final before = _driftValue(difference.before);
    final after = _driftValue(difference.after);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (difference.isNotable)
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 6),
                  child: Icon(
                    Icons.priority_high,
                    size: 15,
                    color: theme.colorScheme.error,
                  ),
                ),
              Expanded(
                child: Text(
                  _driftLabel(difference.key),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(
              left: difference.isNotable ? 21 : 0,
              top: 2,
            ),
            child: Text(
              difference.isAdded
                  ? 'Added: $after'
                  : difference.isRemoved
                  ? 'Removed: $before'
                  : '$before → $after',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.summary,
    required this.children,
    this.initiallyExpanded = false,
  });

  final String title;
  final IconData icon;
  final String summary;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(summary),
        ),
        children: children,
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoNote extends StatelessWidget {
  const _InfoNote({
    required this.icon,
    required this.message,
    this.tone = StatusTone.unknown,
  });

  final IconData icon;
  final String message;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final color = tone.color(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color == Theme.of(context).colorScheme.outline
                    ? null
                    : color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderStatusCard extends StatelessWidget {
  const _ProviderStatusCard({required this.statuses});

  final List<ProviderStatus> statuses;

  @override
  Widget build(BuildContext context) {
    final available = statuses
        .where((status) => status.status == ProviderHealth.healthy)
        .length;
    return _SectionCard(
      title: 'Provider status',
      icon: Icons.hub_outlined,
      summary: '$available/${statuses.length} source(s) healthy',
      initiallyExpanded: true,
      children: [
        for (final status in statuses) _ProviderStatusRow(status: status),
      ],
    );
  }
}

class _ProviderStatusRow extends StatelessWidget {
  const _ProviderStatusRow({required this.status});

  final ProviderStatus status;

  @override
  Widget build(BuildContext context) {
    final tone = _providerTone(status.status);
    final detail = [
      if (status.source != null) status.source!,
      if (status.detail != null) status.detail!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _providerIcon(status.status),
            size: 18,
            color: tone.color(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: StatusPill(
              tone: tone,
              label: _providerLabel(status.status),
              compact: true,
            ),
          ),
        ],
      ),
    );
  }
}

StatusTone _providerTone(ProviderHealth status) => switch (status) {
  ProviderHealth.healthy => StatusTone.healthy,
  ProviderHealth.degraded => StatusTone.attention,
  ProviderHealth.down => StatusTone.critical,
  ProviderHealth.unknown => StatusTone.unknown,
  ProviderHealth.skipped => StatusTone.paused,
};

String _providerLabel(ProviderHealth status) => switch (status) {
  ProviderHealth.healthy => 'Healthy',
  ProviderHealth.degraded => 'Partial',
  ProviderHealth.down => 'Down',
  ProviderHealth.unknown => 'Unknown',
  ProviderHealth.skipped => 'Skipped',
};

IconData _providerIcon(ProviderHealth status) => switch (status) {
  ProviderHealth.healthy => Icons.check_circle_outline_rounded,
  ProviderHealth.degraded => Icons.warning_amber_rounded,
  ProviderHealth.down => Icons.error_outline_rounded,
  ProviderHealth.unknown => Icons.help_outline_rounded,
  ProviderHealth.skipped => Icons.remove_circle_outline_rounded,
};

class _Finding {
  const _Finding({
    required this.label,
    required this.value,
    required this.tone,
    required this.icon,
    this.detail,
  });

  final String label;
  final String value;
  final StatusTone tone;
  final IconData icon;
  final String? detail;
}

class _ReportAssessment {
  const _ReportAssessment({
    required this.tone,
    required this.headline,
    required this.detail,
  });

  final StatusTone tone;
  final String headline;
  final String detail;

  factory _ReportAssessment.from(
    DomainReport report,
    CertificateInfo? certificate,
  ) {
    final findings = _findings(report, certificate);
    final critical = findings
        .where((f) => f.tone == StatusTone.critical)
        .toList();
    final attention = findings
        .where((f) => f.tone == StatusTone.attention)
        .toList();

    if (critical.isNotEmpty) {
      return _ReportAssessment(
        tone: StatusTone.critical,
        headline: 'A critical issue needs attention',
        detail: critical.first.detail ?? critical.first.value,
      );
    }
    if (attention.isNotEmpty) {
      return _ReportAssessment(
        tone: StatusTone.attention,
        headline: 'A check needs attention',
        detail: attention.first.detail ?? attention.first.value,
      );
    }
    final providerWarnings = report.providerStatuses
        .where(
          (status) =>
              status.status == ProviderHealth.down ||
              status.status == ProviderHealth.degraded,
        )
        .toList();
    if (providerWarnings.isNotEmpty) {
      final provider = providerWarnings.first;
      return _ReportAssessment(
        tone: StatusTone.attention,
        headline: provider.status == ProviderHealth.down
            ? 'A discovery source is unavailable'
            : 'A discovery source returned partial data',
        detail:
            provider.detail ??
            '${provider.name} did not provide a complete current result.',
      );
    }
    return const _ReportAssessment(
      tone: StatusTone.healthy,
      headline: 'No immediate issues found',
      detail: 'The completed checks look healthy. Expand a section for the details.',
    );
  }
}

List<_Finding> _findings(DomainReport report, CertificateInfo? certificate) {
  final now = DateTime.now().toUtc();
  final findings = <_Finding>[];

  final http = report.http;
  if (http == null) {
    findings.add(
      const _Finding(
        label: 'Availability',
        value: 'No response',
        tone: StatusTone.unknown,
        icon: Icons.public_outlined,
        detail: 'HTTP probe unavailable',
      ),
    );
  } else if (http.statusCode != null &&
      http.statusCode! >= 200 &&
      http.statusCode! < 300) {
    findings.add(
      _Finding(
        label: 'Availability',
        value: 'HTTP ${http.statusCode}',
        tone: StatusTone.healthy,
        icon: Icons.public_outlined,
        detail: 'HTTPS responded successfully',
      ),
    );
  } else {
    findings.add(
      _Finding(
        label: 'Availability',
        value: http.statusCode == null ? 'Failed' : 'HTTP ${http.statusCode}',
        tone: StatusTone.critical,
        icon: Icons.public_off_outlined,
        detail: 'The HTTPS response was not successful',
      ),
    );
  }

  if (certificate == null) {
    findings.add(
      const _Finding(
        label: 'TLS',
        value: 'Unavailable',
        tone: StatusTone.unknown,
        icon: Icons.lock_outline_rounded,
        detail: 'The server chain could not be captured',
      ),
    );
  } else {
    final days = certificate.daysRemaining(now);
    final expired = days != null && days < 0;
    final nearExpiry = days != null && days >= 0 && days <= 14;
    final critical =
        expired ||
        certificate.trusted == false ||
        certificate.hasExpiredIntermediate(now);
    final attention =
        !critical && (nearExpiry || certificate.missingIntermediate);
    findings.add(
      _Finding(
        label: 'TLS',
        value: days == null ? 'Unknown expiry' : _daysText(days),
        tone: critical
            ? StatusTone.critical
            : attention
            ? StatusTone.attention
            : StatusTone.healthy,
        icon: critical ? Icons.gpp_bad_outlined : Icons.lock_outline_rounded,
        detail: critical
            ? 'The certificate chain has a trust or expiry issue'
            : attention
            ? 'Certificate needs attention soon'
            : 'Certificate chain looks healthy',
      ),
    );
  }

  final registration = report.registration;
  if (registration == null) {
    findings.add(
      const _Finding(
        label: 'Registration',
        value: 'Unavailable',
        tone: StatusTone.unknown,
        icon: Icons.badge_outlined,
        detail: 'RDAP data was not available',
      ),
    );
  } else {
    final days = registration.daysUntilExpiry(now);
    final risk = registration.hasRiskStatus;
    final nearExpiry = days != null && days >= 0 && days <= 14;
    findings.add(
      _Finding(
        label: 'Registration',
        value: days == null ? 'Unknown expiry' : _daysText(days),
        tone: risk
            ? StatusTone.critical
            : nearExpiry
            ? StatusTone.attention
            : StatusTone.healthy,
        icon: risk ? Icons.report_gmailerrorred_outlined : Icons.badge_outlined,
        detail: risk
            ? 'Domain carries a deletion or transfer status'
            : nearExpiry
            ? 'Registration expires soon'
            : 'Registration looks healthy',
      ),
    );
  }

  final email = report.emailAuth;
  if (email == null) {
    findings.add(
      const _Finding(
        label: 'Email auth',
        value: 'Unavailable',
        tone: StatusTone.unknown,
        icon: Icons.mail_outline_rounded,
        detail: 'Email records were not available',
      ),
    );
  } else {
    final missing = [if (!email.hasSpf) 'SPF', if (!email.hasDmarc) 'DMARC'];
    findings.add(
      _Finding(
        label: 'Email auth',
        value: missing.isEmpty
            ? 'SPF + DMARC'
            : '${missing.join(' + ')} missing',
        tone: missing.isEmpty ? StatusTone.healthy : StatusTone.attention,
        icon: missing.isEmpty
            ? Icons.mark_email_read_outlined
            : Icons.mail_outline_rounded,
        detail: missing.isEmpty
            ? 'Core email authentication records found'
            : 'Some core email authentication records are missing',
      ),
    );
  }

  findings.add(
    _Finding(
      label: 'DNS',
      value: report.dns.types.isEmpty
          ? 'Unavailable'
          : '${report.dns.types.length} types',
      tone: report.dns.types.isEmpty ? StatusTone.unknown : StatusTone.healthy,
      icon: Icons.dns_outlined,
      detail: report.dns.types.isEmpty
          ? 'No DNS answers returned'
          : 'DNS answers returned',
    ),
  );

  final ct = report.ct;
  // Neutral, not a fault: the CT probe is opt-in, so a default scan has no
  // subdomain result to report and should not look like a failed check.
  final ctRequested = report.includeCt;
  findings.add(
    _Finding(
      label: 'Subdomains',
      value: ct == null
          ? ctRequested
                ? 'Unavailable'
                : 'Not scanned'
          : '${ct.subdomains.length}${ct.isPartial ? '+' : ''} found',
      tone: ct == null
          ? StatusTone.unknown
          : ct.isPartial
          ? StatusTone.attention
          : StatusTone.healthy,
      icon: Icons.account_tree_outlined,
      detail: ct == null
          ? ctRequested
                ? 'Transparency data was not available'
                : 'Subdomain discovery was not requested'
          : ct.isPartial
          ? 'Source returned only part of the available history'
          : '${ct.entryCount} certificate log entries',
    ),
  );

  return findings;
}

String _date(DateTime? value) =>
    value == null ? '—' : value.toIso8601String().substring(0, 10);

String _dateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${_date(local)} at $hour:$minute';
}

String _expiryText(int days) => _daysText(days);

String _daysText(int days) {
  if (days < 0) return '${days.abs()}d overdue';
  if (days == 0) return 'Expires today';
  return '${days}d left';
}
