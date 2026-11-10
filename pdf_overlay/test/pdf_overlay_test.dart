// Runs mergeOverlay over every fixture in test/fixtures/manifest.json and writes
// the results to build/test_out/. Then verify them independently with:
//
//     python3 tool/verify.py
//
// (qpdf --check, poppler rendering of the overlay pixels, text extraction.)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_overlay/pdf_overlay.dart';
import 'package:pdf_overlay/src/reader.dart';
import 'package:test/test.dart';

/// How many content streams the page has.
int _contentCount(PdfReader r, PdfPage p) {
  final c = r.resolve(p.node['Contents']);
  return c is List ? c.length : (c == null ? 0 : 1);
}

void main() {
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync())
          as List<dynamic>;
  final outDir = Directory('build/test_out')..createSync(recursive: true);

  Uint8List load(String name) =>
      Uint8List.fromList(File('test/fixtures/$name').readAsBytesSync());

  for (final raw in manifest) {
    final e = raw as Map<String, dynamic>;
    final name = e['name'] as String;
    final targets = (e['targets'] as List<dynamic>).cast<int>();
    final outFile = File('${outDir.path}/$name.pdf');

    if (e['expect'] == 'unsupported') {
      test('$name is refused', () {
        if (outFile.existsSync()) outFile.deleteSync();
        expect(
          () => mergeOverlay(load(e['original'] as String),
              load(e['overlay'] as String),
              targetPages: targets),
          throwsA(isA<UnsupportedPdfException>()),
        );
      });
      continue;
    }

    test('$name merges (${e['note']})', () {
      final original = load(e['original'] as String);
      final merged = mergeOverlay(original, load(e['overlay'] as String),
          targetPages: targets);
      outFile.writeAsBytesSync(merged);

      // Pure incremental update: the original is an exact prefix.
      expect(merged.length, greaterThan(original.length));
      expect(merged.sublist(0, original.length), orderedEquals(original));

      // Re-read the result with our own reader: same pages; a page that got an
      // overlay has a stream before and one after its own content, and draws the form.
      final before = PdfReader(original);
      final after = PdfReader(merged);
      final pb = before.pages();
      final pa = after.pages();
      expect(pa.length, pb.length);
      for (var i = 0; i < pa.length; i++) {
        final hit = targets.contains(i);
        expect(
          _contentCount(after, pa[i]),
          _contentCount(before, pb[i]) + (hit ? 2 : 0),
          reason: 'content streams of page $i',
        );
        final forms = after.resolve(after.resolve(pa[i].inherited['Resources']) is Map
            ? (after.resolve(pa[i].inherited['Resources']) as Map)['XObject']
            : null);
        if (hit) {
          expect((forms as Map).keys.where((k) => (k as String).contains('UniOverlay')), isNotEmpty,
              reason: 'the form is a resource of page $i');
        }
      }
    });
  }

  test('rejects mismatched targetPages', () {
    final o = load('classic.pdf');
    final v = load('classic.overlay.pdf'); // 2 overlay pages
    expect(() => mergeOverlay(o, v, targetPages: [0]), throwsArgumentError);
    expect(() => mergeOverlay(o, v, targetPages: [0, 99]), throwsRangeError);
  });

  test('garbage input is UnsupportedPdfException, not a crash', () {
    expect(
      () => mergeOverlay(Uint8List.fromList(utf8.encode('hello')),
          load('classic.overlay.pdf')),
      throwsA(isA<UnsupportedPdfException>()),
    );
  });
}
