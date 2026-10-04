/// A normalised domain the engine can probe.
class DomainInput {
  const DomainInput({
    required this.original,
    required this.host,
    required this.tld,
    required this.registrable,
    required this.isIdn,
  });

  /// The string the user typed.
  final String original;

  /// ASCII hostname, lower-cased, with scheme/port/path and a leading `www.`
  /// removed.
  final String host;

  /// The public suffix, best-effort: the last label, or a known multi-part
  /// suffix such as `co.uk`.
  final String tld;

  /// The registrable domain (`example.com`, `example.co.uk`).
  final String registrable;

  /// Whether the input contained non-ASCII characters (an IDN).
  final bool isIdn;

  /// Suffixes that occupy two labels. This is a pragmatic subset of the public
  /// suffix list; replace with a full PSL when IDN/edge TLDs matter.
  static const _multiPartSuffixes = <String>{
    'co.uk',
    'org.uk',
    'ac.uk',
    'gov.uk',
    'me.uk',
    'ltd.uk',
    'plc.uk',
    'co.jp',
    'ne.jp',
    'or.jp',
    'ac.jp',
    'go.jp',
    'co.nz',
    'net.nz',
    'org.nz',
    'govt.nz',
    'com.au',
    'net.au',
    'org.au',
    'edu.au',
    'gov.au',
    'co.in',
    'net.in',
    'org.in',
    'gen.in',
    'firm.in',
    'com.br',
    'net.br',
    'org.br',
    'gov.br',
    'com.cn',
    'net.cn',
    'org.cn',
    'gov.cn',
    'co.za',
    'org.za',
    'net.za',
    'com.mx',
    'org.mx',
    'gob.mx',
    'co.kr',
    'or.kr',
    'ne.kr',
    'com.sg',
    'net.sg',
    'org.sg',
    'com.hk',
    'net.hk',
    'org.hk',
    'co.id',
    'or.id',
    'web.id',
    'com.tr',
    'net.tr',
    'org.tr',
    'com.tw',
    'net.tw',
    'org.tw',
    'co.il',
    'org.il',
    'net.il',
  };

  static final _scheme = RegExp(r'^[a-z][a-z0-9+.\-]*://');
  static final _label = RegExp(r'^[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?$');

  /// Parses user input. Returns `null` when it is not a usable domain.
  static DomainInput? tryParse(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;

    s = s.replaceFirst(_scheme, '');

    final at = s.indexOf('@');
    if (at != -1) s = s.substring(at + 1);

    final slash = s.indexOf('/');
    if (slash != -1) s = s.substring(0, slash);

    final colon = s.indexOf(':');
    if (colon != -1) s = s.substring(0, colon);

    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    if (s.startsWith('www.')) s = s.substring(4);

    if (s.isEmpty || s.length > 253) return null;

    final labels = s.split('.');
    if (labels.length < 2) return null;

    final isIdn = s.runes.any((r) => r > 127);
    if (!isIdn && !labels.every(_label.hasMatch)) return null;

    final suffixLabels = _suffixLabelCount(labels);
    final tld = labels.sublist(labels.length - suffixLabels).join('.');
    final registrable = labels.length > suffixLabels
        ? labels.sublist(labels.length - suffixLabels - 1).join('.')
        : s;

    return DomainInput(
      original: raw,
      host: s,
      tld: tld,
      registrable: registrable,
      isIdn: isIdn,
    );
  }

  static int _suffixLabelCount(List<String> labels) {
    if (labels.length >= 2) {
      final two = '${labels[labels.length - 2]}.${labels[labels.length - 1]}';
      if (_multiPartSuffixes.contains(two)) return 2;
    }
    return 1;
  }

  @override
  String toString() => registrable;
}
