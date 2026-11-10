import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_overlay/src/filters.dart';
import 'package:pdf_overlay/src/objects.dart';
import 'package:pdf_overlay/src/parser.dart';
import 'package:pdf_overlay/src/serializer.dart';
import 'package:test/test.dart';

PdfParser parser(String s, [LengthResolver? r]) =>
    PdfParser(Uint8List.fromList(latin1.encode(s)), 0, r);

class _Identity implements Resolver {
  @override
  Object? resolve(Object? o) => o;
}

String written(Object? o) {
  final b = BytesBuilder();
  writeObject(b, o);
  return latin1.decode(b.toBytes());
}

void main() {
  group('parser', () {
    test('numbers', () {
      expect(parser('42').parseObject(), 42);
      expect(parser('-3.5').parseObject(), -3.5);
      expect(parser('.5').parseObject(), 0.5);
      expect(parser('+7').parseObject(), 7);
    });

    test('references vs. plain integers', () {
      expect(parser('12 0 R').parseObject(), const PdfRef(12, 0));
      expect(parser('[1 0 R 2 0 R 3]').parseObject(),
          [const PdfRef(1, 0), const PdfRef(2, 0), 3]);
      expect(parser('[0 0 595 842]').parseObject(), [0, 0, 595, 842]);
    });

    test('names with #xx escapes', () {
      expect(parser('/A#20B').parseObject(), const PdfName('A B'));
    });

    test('literal strings', () {
      final s = parser(r'(a\(b\)c\101\n(nested))').parseObject() as PdfString;
      expect(latin1.decode(s.bytes), 'a(b)cA\n(nested)');
    });

    test('hex strings', () {
      final s = parser('<48 65 6C6c6F7>').parseObject() as PdfString;
      expect(s.bytes, [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x70]);
    });

    test('dictionary with comments and nesting', () {
      final d = parser('<< /A 1 % a comment\n /B [1 2] /C << /D (x) >> >>')
          .parseObject() as Map<String, Object?>;
      expect(d['A'], 1);
      expect(d['B'], [1, 2]);
      expect((d['C'] as Map<String, Object?>).containsKey('D'), isTrue);
    });

    test('stream with direct /Length', () {
      final s = parser('<< /Length 5 >>\nstream\nhello\nendstream')
          .parseObject() as PdfStream;
      expect(latin1.decode(s.raw), 'hello');
    });

    test('stream with indirect /Length', () {
      final s = parser('<< /Length 9 0 R >>\nstream\nhello\nendstream',
          (ref) => 5).parseObject() as PdfStream;
      expect(latin1.decode(s.raw), 'hello');
    });

    test('stream with a wrong /Length falls back to endstream', () {
      final s = parser('<< /Length 99 >>\nstream\r\nhello\r\nendstream')
          .parseObject() as PdfStream;
      expect(latin1.decode(s.raw), 'hello');
    });

    test('indirect object header', () {
      final o = parser('7 2 obj\n<< /K /V >>\nendobj').parseIndirect();
      expect(o.num, 7);
      expect(o.gen, 2);
      expect((o.value as Map<String, Object?>)['K'], const PdfName('V'));
    });
  });

  group('filters', () {
    test('Flate round trip', () {
      final raw = Uint8List.fromList(List<int>.generate(500, (i) => i % 7));
      final packed = Uint8List.fromList(ZLibEncoder().convert(raw));
      final s = PdfStream({'Filter': const PdfName('FlateDecode')}, packed);
      expect(decodeStream(s, _Identity()), raw);
    });

    test('PNG "Up" predictor', () {
      // two rows of 3 bytes, both filtered with tag 2 (Up)
      final filtered = Uint8List.fromList([2, 1, 2, 3, 2, 1, 1, 1]);
      final packed = Uint8List.fromList(ZLibEncoder().convert(filtered));
      final s = PdfStream({
        'Filter': const PdfName('FlateDecode'),
        'DecodeParms': <String, Object?>{'Predictor': 12, 'Columns': 3},
      }, packed);
      expect(decodeStream(s, _Identity()), [1, 2, 3, 2, 3, 4]);
    });

    test('unsupported filter is reported', () {
      final s = PdfStream({'Filter': const PdfName('LZWDecode')}, Uint8List(0));
      expect(() => decodeStream(s, _Identity()),
          throwsA(isA<UnsupportedPdfException>()));
    });
  });

  group('serializer', () {
    test('real numbers never use exponent notation', () {
      expect(formatReal(0.5), '0.5');
      expect(formatReal(12.0), '12');
      expect(formatReal(1e-7), '0');
      expect(formatReal(595.276), '595.276');
    });

    test('dictionary output parses back', () {
      final dict = <String, Object?>{
        'Rect': <Object?>[0, 0.5, 595.28, 842],
        'Name With Space': const PdfName('A B'),
        'S': PdfString(Uint8List.fromList([0, 255, 10])),
        'R': const PdfRef(3, 0),
      };
      final back = parser(written(dict)).parseObject() as Map<String, Object?>;
      expect(back['Rect'], [0, 0.5, 595.28, 842]);
      expect(back['Name With Space'], const PdfName('A B'));
      expect((back['S'] as PdfString).bytes, [0, 255, 10]);
      expect(back['R'], const PdfRef(3, 0));
    });
  });
}
