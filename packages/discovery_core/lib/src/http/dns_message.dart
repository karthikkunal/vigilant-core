import 'dart:typed_data';

import '../models/dns_records.dart';
import 'dns_client.dart';

/// Raised when a DNS response cannot be decoded.
class DnsFormatException implements Exception {
  const DnsFormatException(this.message);

  final String message;

  @override
  String toString() => 'DnsFormatException: $message';
}

/// A decoded DNS response, with answers rendered to presentation form.
class DnsResponse {
  const DnsResponse({
    required this.id,
    required this.responseCode,
    required this.questions,
    required this.answers,
    required this.authorities,
    required this.additionals,
  });

  final int id;

  /// The RCODE from the response header. `0` is NOERROR, `3` is NXDOMAIN.
  final int responseCode;

  final List<String> questions;
  final List<DnsRecord> answers;
  final List<DnsRecord> authorities;
  final List<DnsRecord> additionals;

  /// Whether the responder answered normally.
  ///
  /// NXDOMAIN counts as a normal answer with no records: the name genuinely
  /// does not exist, which is different from the resolver failing.
  bool get isAuthoritative => responseCode == 0 || responseCode == 3;

  /// Whether the responder reported the name as nonexistent.
  bool get isNameError => responseCode == 3;
}

/// Decodes a raw DNS response message into presentation-form records.
///
/// RDATA for names, MX, SOA and CAA is rendered to the same text a resolver
/// would show, so records read identically whichever client produced them.
/// Compression pointers are resolved against the whole message, so this must
/// run over the complete response rather than an isolated RDATA slice.
DnsResponse parseDnsResponse(Uint8List bytes) {
  final reader = _Reader(bytes);
  final id = reader.uint16();
  final flags = reader.uint16();
  final questionCount = reader.uint16();
  final answerCount = reader.uint16();
  final authorityCount = reader.uint16();
  final additionalCount = reader.uint16();

  final questions = <String>[];
  for (var i = 0; i < questionCount; i++) {
    questions.add(reader.name());
    reader.uint16(); // QTYPE
    reader.uint16(); // QCLASS
  }

  List<DnsRecord> readRecords(int count) {
    final records = <DnsRecord>[];
    for (var i = 0; i < count; i++) {
      final name = reader.name();
      final type = reader.uint16();
      reader.uint16(); // CLASS
      final ttl = reader.uint32();
      final dataLength = reader.uint16();
      final dataStart = reader.offset;
      reader.require(dataLength);
      final data = _renderRdata(reader, type, dataStart, dataLength);
      // A name inside RDATA may be compressed, which leaves the cursor after
      // the pointer rather than at the end of the record.
      reader.offset = dataStart + dataLength;
      records.add(
        DnsRecord(
          name: name,
          type: DnsClient.typeName(type) ?? 'TYPE$type',
          ttl: ttl,
          data: data,
        ),
      );
    }
    return records;
  }

  final answers = readRecords(answerCount);
  final authorities = readRecords(authorityCount);
  final additionals = readRecords(additionalCount);

  return DnsResponse(
    id: id,
    responseCode: flags & 0x0F,
    questions: questions,
    answers: answers,
    authorities: authorities,
    additionals: additionals,
  );
}

/// Decodes a DNS response, or returns `null` when the bytes are malformed.
///
/// A truncated or corrupt message is not a resolver failure, so this reports it
/// as "no usable answer" rather than throwing.
DnsResponse? tryParseDnsResponse(Uint8List bytes) {
  try {
    return parseDnsResponse(bytes);
  } on DnsFormatException {
    return null;
  } on RangeError {
    return null;
  }
}

String _renderRdata(_Reader reader, int type, int start, int length) {
  final end = start + length;
  switch (type) {
    case 1: // A
      if (length != 4) {
        throw DnsFormatException('A record must be 4 bytes, got $length');
      }
      return reader.skipTo(start).ipv4();
    case 28: // AAAA
      if (length != 16) {
        throw DnsFormatException('AAAA record must be 16 bytes, got $length');
      }
      return reader.skipTo(start).ipv6();
    case 2 || 5 || 12: // NS, CNAME, PTR
      return reader.skipTo(start).name();
    case 15: // MX
      final r = reader.skipTo(start);
      final preference = r.uint16();
      return '$preference ${r.name()}';
    case 6: // SOA
      final r = reader.skipTo(start);
      final mname = r.name();
      final rname = r.name();
      final numbers = <int>[
        r.uint32(),
        r.uint32(),
        r.uint32(),
        r.uint32(),
        r.uint32(),
      ];
      return <String>[mname, rname, ...numbers.map((n) => '$n')].join(' ');
    case 16: // TXT
      final r = reader.skipTo(start);
      final strings = <String>[];
      while (r.offset < end) {
        final partLength = r.uint8();
        r.require(partLength);
        strings.add(r.utf8(partLength));
      }
      // A TXT record's logical value is the concatenation of its
      // character-strings. Emitting it unquoted matches what a resolver shows
      // once presentation quoting is removed.
      return strings.join();
    case 257: // CAA
      final r = reader.skipTo(start);
      final flags = r.uint8();
      final tagLength = r.uint8();
      r.require(tagLength);
      final tag = r.utf8(tagLength);
      return '$flags $tag "${r.utf8(end - r.offset)}"';
    default:
      // An unmodelled type is still reported, as hex, rather than dropped.
      return reader
          .skipTo(start)
          .bytesUntil(end)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
  }
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  void require(int count) {
    if (count < 0 || offset + count > bytes.length) {
      throw DnsFormatException(
        'Truncated message: needed $count bytes at offset $offset, '
        'have ${bytes.length}',
      );
    }
  }

  _Reader skipTo(int position) {
    if (position < 0 || position > bytes.length) {
      throw DnsFormatException('Offset $position is outside the message');
    }
    offset = position;
    return this;
  }

  int uint8() {
    require(1);
    return bytes[offset++];
  }

  int uint16() {
    require(2);
    final value = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    return value;
  }

  int uint32() {
    require(4);
    final value = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;
    return value;
  }

  Uint8List bytesUntil(int end) {
    if (end < offset || end > bytes.length) {
      throw DnsFormatException('Cannot read to offset $end');
    }
    final slice = Uint8List.fromList(bytes.sublist(offset, end));
    offset = end;
    return slice;
  }

  String utf8(int count) {
    require(count);
    final value = String.fromCharCodes(bytes.sublist(offset, offset + count));
    offset += count;
    return value;
  }

  /// Reads a domain name, following compression pointers.
  String name() {
    final labels = <String>[];
    var resumeAt = -1;
    var terminated = false;
    for (var hops = 0; offset < bytes.length; hops++) {
      if (hops > 128) {
        throw const DnsFormatException('Too many compression pointers');
      }
      final length = uint8();
      if (length == 0) {
        terminated = true;
        break;
      }
      if ((length & 0xC0) == 0xC0) {
        final pointer = ((length & 0x3F) << 8) | uint8();
        if (pointer >= bytes.length) {
          throw const DnsFormatException('Compression pointer is out of range');
        }
        if (resumeAt < 0) resumeAt = offset;
        offset = pointer;
        continue;
      }
      if (length > 63) {
        throw DnsFormatException('Invalid label length $length');
      }
      require(length);
      labels.add(String.fromCharCodes(bytes.sublist(offset, offset + length)));
      offset += length;
    }
    if (!terminated) {
      throw const DnsFormatException('Name is not terminated');
    }
    if (resumeAt >= 0) offset = resumeAt;
    return labels.join('.');
  }

  String ipv4() {
    require(4);
    final text = <int>[
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
      bytes[offset + 3],
    ].join('.');
    offset += 4;
    return text;
  }

  /// Renders 16 bytes as an RFC 5952 address, compressing the longest run of
  /// zero groups to `::`.
  String ipv6() {
    require(16);
    final groups = <int>[];
    for (var i = 0; i < 8; i++) {
      final base = offset + i * 2;
      groups.add((bytes[base] << 8) | bytes[base + 1]);
    }
    offset += 16;

    // Leftmost-longest run wins; a single zero group is written as 0.
    var bestStart = -1;
    var bestLength = 0;
    var runStart = -1;
    var runLength = 0;
    for (var i = 0; i < groups.length; i++) {
      if (groups[i] == 0) {
        if (runStart < 0) runStart = i;
        runLength++;
        if (runLength > bestLength) {
          bestLength = runLength;
          bestStart = runStart;
        }
      } else {
        runStart = -1;
        runLength = 0;
      }
    }
    if (bestLength < 2) bestStart = -1;
    if (bestStart < 0) {
      return groups.map((g) => g.toRadixString(16)).join(':');
    }

    final head = <String>[];
    final tail = <String>[];
    for (var i = 0; i < groups.length; i++) {
      if (i >= bestStart && i < bestStart + bestLength) continue;
      (i < bestStart ? head : tail).add(groups[i].toRadixString(16));
    }
    return '${head.join(':')}::${tail.join(':')}';
  }
}
