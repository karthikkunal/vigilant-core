import 'dart:typed_data';

import 'package:discovery_core/discovery_core.dart';
import 'package:test/test.dart';

/// Builds a DNS response message so the parser is exercised against real bytes
/// rather than a hand-written fixture that could drift from the format.
class _MessageBuilder {
  _MessageBuilder(
      {this.id = 0x1234, this.responseCode = 0, this.flags = 0x8180});

  final int id;
  final int responseCode;
  final int flags;
  final List<int> _bytes = <int>[];

  int get length => _bytes.length;

  /// A compression pointer is only valid once its target has been written.
  final Map<String, int> _offsets = <String, int>{};
  void addHeader(int questionCount, int answerCount) {
    _u16(id);
    _u16(flags | responseCode);
    _u16(questionCount);
    _u16(answerCount);
    _u16(0); // NSCOUNT
    _u16(0); // ARCOUNT
  }

  void addQuestion(String name, int type) {
    _name(name, compress: false);
    _u16(type);
    _u16(1); // IN
  }

  /// Appends an answer whose RDATA is produced by [rdata].
  ///
  /// RDATA is built before the record header is written, because the header
  /// carries RDLENGTH and the two must agree.
  void addAnswer(
    String name,
    int type,
    List<int> Function() rdata, {
    int ttl = 300,
  }) {
    final start = _bytes.length;
    _name(name, compress: true);
    _u16(type);
    _u16(1); // IN
    _u32(ttl);
    final payload = rdata();
    _u16(payload.length);
    _bytes.addAll(payload);
    assert(_bytes.length > start, 'answer for $name wrote nothing');
  }

  /// Appends an answer whose RDATA is already encoded.
  void addRawAnswer(String name, int type, List<int> rdata, {int ttl = 300}) =>
      addAnswer(name, type, () => rdata, ttl: ttl);

  /// Encodes an uncompressed name for use as RDATA.
  ///
  /// Built into its own buffer rather than appended in place, because the
  /// record header carrying RDLENGTH must be written before the payload.
  static List<int> nameRdata(String name) {
    final out = <int>[];
    for (final label in name.split('.')) {
      out
        ..add(label.length)
        ..addAll(label.codeUnits);
    }
    out.add(0);
    return out;
  }

  Uint8List build() => Uint8List.fromList(_bytes);

  void _u16(int value) {
    _bytes
      ..add((value >> 8) & 0xFF)
      ..add(value & 0xFF);
  }

  void _u32(int value) {
    _bytes
      ..add((value >> 24) & 0xFF)
      ..add((value >> 16) & 0xFF)
      ..add((value >> 8) & 0xFF)
      ..add(value & 0xFF);
  }

  void _name(String name, {bool compress = false, bool record = true}) {
    if (compress) {
      final pointer = _offsets[name];
      if (pointer != null && pointer >= 0) {
        _u16(0xC000 | pointer);
        return;
      }
    }
    final offset = _bytes.length;
    for (final label in name.split('.')) {
      _bytes
        ..add(label.length)
        ..addAll(label.codeUnits);
    }
    _bytes.add(0);
    if (record && !_offsets.containsKey(name)) _offsets[name] = offset;
  }
}

List<int> _txt(List<String> parts) => <int>[
      for (final part in parts) ...<int>[part.length, ...part.codeUnits],
    ];

void main() {
  test('decodes an A answer', () {
    final builder = _MessageBuilder(id: 0xBEEF)
      ..addHeader(1, 1)
      ..addQuestion('example.com', 1);
    builder.addRawAnswer('example.com', 1, <int>[93, 184, 216, 34]);

    final response = parseDnsResponse(builder.build());

    expect(response.id, 0xBEEF);
    expect(response.questions, ['example.com']);
    expect(response.answers, hasLength(1));
    expect(response.answers.single.type, 'A');
    expect(response.answers.single.data, '93.184.216.34');
    expect(response.answers.single.ttl, 300);
  });

  test('decodes an AAAA answer in RFC 5952 form', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 1)
      ..addQuestion('example.com', 28);
    builder.addRawAnswer('example.com', 28, <int>[
      0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01, //
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);

    final response = parseDnsResponse(builder.build());

    expect(response.answers.single.type, 'AAAA');
    expect(response.answers.single.data, '2606:2800:220:1::');
  });

  test('renders the unspecified, loopback and link-local addresses', () {
    String ipv6(List<int> bytes) {
      final builder = _MessageBuilder()
        ..addHeader(1, 1)
        ..addQuestion('example.com', 28);
      builder.addRawAnswer('example.com', 28, bytes);
      return parseDnsResponse(builder.build()).answers.single.data;
    }

    expect(ipv6(List<int>.filled(16, 0)), '::');
    expect(
      ipv6(<int>[
        0, 0, 0, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 1,
      ]),
      '::1',
    );
    expect(
      ipv6(<int>[
        0xFE, 0x80, 0, 0, 0, 0, 0, 0, //
        0, 0, 0, 0, 0, 0, 0, 0,
      ]),
      'fe80::',
    );
    // No zero group, so nothing is compressed.
    expect(
      ipv6(<int>[
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, //
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
      ]),
      '102:304:506:708:90a:b0c:d0e:f10',
    );
  });

  test('decodes a TXT answer, joining multi-part character-strings', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 1)
      ..addQuestion('example.com', 16);
    builder.addAnswer(
      'example.com',
      16,
      () => _txt(<String>['v=spf1 include:_spf.', 'google.com ~all']),
    );

    final response = parseDnsResponse(builder.build());

    expect(response.answers.single.type, 'TXT');
    expect(
      response.answers.single.data,
      'v=spf1 include:_spf.google.com ~all',
    );
  });

  test('decodes an MX answer', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 1)
      ..addQuestion('example.com', 15);
    builder.addAnswer(
      'example.com',
      15,
      () => <int>[0x00, 0x0A, ..._MessageBuilder.nameRdata('mail.example.com')],
    );

    final response = parseDnsResponse(builder.build());

    expect(response.answers.single.type, 'MX');
    expect(response.answers.single.data, '10 mail.example.com');
  });

  test('decodes an NS answer', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 1)
      ..addQuestion('example.com', 2);
    builder.addAnswer(
        'example.com', 2, () => _MessageBuilder.nameRdata('ns1.example.com'));

    final response = parseDnsResponse(builder.build());

    expect(response.answers.single.type, 'NS');
    expect(response.answers.single.data, 'ns1.example.com');
  });

  test('decodes a CAA answer in presentation form', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 1)
      ..addQuestion('example.com', 257);
    builder.addAnswer('example.com', 257, () {
      const tag = 'issue';
      const value = 'letsencrypt.org';
      return <int>[0, tag.length, ...tag.codeUnits, ...value.codeUnits];
    });

    final response = parseDnsResponse(builder.build());

    expect(response.answers.single.type, 'CAA');
    expect(response.answers.single.data, '0 issue "letsencrypt.org"');
  });

  test('decodes a CNAME answer', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 1)
      ..addQuestion('www.example.com', 5);
    builder.addAnswer(
      'www.example.com',
      5,
      () => _MessageBuilder.nameRdata('example.com'),
    );

    final response = parseDnsResponse(builder.build());

    expect(response.answers.single.type, 'CNAME');
    expect(response.answers.single.data, 'example.com');
  });

  test('follows a compression pointer in a record name', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 2)
      ..addQuestion('example.com', 1);
    builder.addRawAnswer('example.com', 1, <int>[1, 2, 3, 4]);
    // 'example.com' is now known, so the second owner name is a pointer back
    // to the first rather than a second copy of the labels.
    builder.addRawAnswer('example.com', 1, <int>[5, 6, 7, 8]);

    final response = parseDnsResponse(builder.build());

    expect(response.answers, hasLength(2));
    expect(response.answers.first.name, 'example.com');
    expect(response.answers.first.data, '1.2.3.4');
    expect(response.answers.last.name, 'example.com');
    expect(response.answers.last.data, '5.6.7.8');
  });

  test('reports an unmodelled record type as hex rather than dropping it', () {
    final builder = _MessageBuilder()
      ..addHeader(1, 1)
      ..addQuestion('example.com', 99);
    builder.addRawAnswer('example.com', 99, <int>[0xDE, 0xAD, 0xBE, 0xEF]);

    final response = parseDnsResponse(builder.build());

    expect(response.answers.single.type, 'TYPE99');
    expect(response.answers.single.data, 'deadbeef');
  });

  test('treats NXDOMAIN as an authoritative answer with no records', () {
    final builder = _MessageBuilder(
      responseCode: 3,
      flags: 0x8183, // QR + AA + RD + RA, with NXDOMAIN in the low bits
    )
      ..addHeader(1, 0)
      ..addQuestion('nope.example.com', 1);

    final response = parseDnsResponse(builder.build());

    expect(response.isNameError, isTrue);
    expect(response.isAuthoritative, isTrue);
    expect(response.answers, isEmpty);
  });

  test('does not treat SERVFAIL as an answer', () {
    final builder = _MessageBuilder(
      responseCode: 2,
      flags: 0x8182, // QR + AA + RD + RA, with SERVFAIL in the low bits
    )
      ..addHeader(1, 0)
      ..addQuestion('example.com', 1);

    final response = parseDnsResponse(builder.build());

    expect(response.isAuthoritative, isFalse);
    expect(response.isNameError, isFalse);
  });

  group('malformed input', () {
    test('rejects a truncated message', () {
      expect(tryParseDnsResponse(Uint8List.fromList(<int>[0, 1, 2])), isNull);
    });

    test('rejects an empty message', () {
      expect(tryParseDnsResponse(Uint8List(0)), isNull);
    });

    test('rejects a count that overruns the message', () {
      final builder = _MessageBuilder()
        ..addHeader(1, 5)
        ..addQuestion('example.com', 1);

      expect(tryParseDnsResponse(builder.build()), isNull);
    });

    test('rejects a self-referential compression pointer', () {
      // A pointer at offset 12 aimed at offset 12 would loop forever.
      final bytes = <int>[
        0x12, 0x34, // id
        0x81, 0x80, // flags
        0x00, 0x01, // qdcount
        0x00, 0x00, // ancount
        0x00, 0x00, // nscount
        0x00, 0x00, // arcount
        0xC0, 0x0C, // pointer to offset 12, itself
        0x00, 0x01, // qtype
        0x00, 0x01, // qclass
      ];

      expect(tryParseDnsResponse(Uint8List.fromList(bytes)), isNull);
    });

    test('rejects an A record with the wrong length', () {
      final builder = _MessageBuilder()
        ..addHeader(1, 1)
        ..addQuestion('example.com', 1);
      builder.addRawAnswer('example.com', 1, <int>[1, 2, 3]);

      expect(tryParseDnsResponse(builder.build()), isNull);
    });
  });
}
