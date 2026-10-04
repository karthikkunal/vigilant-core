import 'package:discovery_core/discovery_core.dart';
import 'package:test/test.dart';

void main() {
  group('DomainInput.tryParse', () {
    test('strips scheme, www, port and path', () {
      final input =
          DomainInput.tryParse('https://www.Example.com:8443/path?q=1')!;
      expect(input.host, 'example.com');
      expect(input.registrable, 'example.com');
      expect(input.tld, 'com');
      expect(input.isIdn, isFalse);
    });

    test('handles multi-part public suffixes', () {
      final input = DomainInput.tryParse('shop.example.co.uk')!;
      expect(input.tld, 'co.uk');
      expect(input.registrable, 'example.co.uk');
      expect(input.host, 'shop.example.co.uk');
    });

    test('rejects input that is not a domain', () {
      expect(DomainInput.tryParse('localhost'), isNull);
      expect(DomainInput.tryParse(''), isNull);
      expect(DomainInput.tryParse('not a domain'), isNull);
      expect(DomainInput.tryParse('   '), isNull);
    });

    test('accepts IDN input without ASCII validation', () {
      final input = DomainInput.tryParse('münchen.de')!;
      expect(input.isIdn, isTrue);
      expect(input.registrable, 'münchen.de');
    });
  });
}
