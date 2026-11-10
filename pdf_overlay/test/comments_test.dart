import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_overlay/pdf_overlay.dart';
import 'package:pdf_overlay/src/objects.dart';
import 'package:pdf_overlay/src/reader.dart';
import 'package:test/test.dart';

Uint8List load(String name) => Uint8List.fromList(File('test/fixtures/$name').readAsBytesSync());

String _decode(PdfString s) {
  final b = s.bytes;
  expect(b.sublist(0, 2), [0xFE, 0xFF]); // UTF-16, with its byte order mark
  return String.fromCharCodes([for (var i = 2; i + 1 < b.length; i += 2) (b[i] << 8) | b[i + 1]]);
}

void main() {
  final outDir = Directory('build/comment_out')..createSync(recursive: true);

  test('a comment becomes a Highlight annotation with its text and a pop-up, the page untouched', () {
    final original = load('classic.pdf');
    final merged = mergeOverlay(original, null, comments: [
      const PdfComment(page: 1, rects: [[50, 100, 150, 120], [50, 120, 90, 140]], contents: 'Ask about this: ünïcode ✓', author: 'Noel'),
      const PdfComment(page: 1, rects: [[10, 10, 40, 20]]), // a mark without words has no pop-up
    ]);
    File('${outDir.path}/classic.pdf').writeAsBytesSync(merged);
    expect(merged.sublist(0, original.length), orderedEquals(original)); // an incremental update

    final after = PdfReader(merged);
    final before = PdfReader(original);
    final pages = after.pages();
    expect(pages.length, before.pages().length);
    List<Map<Object?, Object?>> annots(PdfReader r, PdfPage p) {
      final a = r.resolve(p.node['Annots']);
      return a is List ? [for (final x in a) (r.resolve(x) as Map).cast<Object?, Object?>()] : [];
    }

    expect(annots(after, pages[0]), isEmpty); // other pages are left alone
    final list = annots(after, pages[1]);
    final highlights = list.where((a) => a['Subtype'] == const PdfName('Highlight')).toList();
    final popups = list.where((a) => a['Subtype'] == const PdfName('Popup')).toList();
    expect(highlights.length, 2);
    expect(popups.length, 1);
    final first = highlights.first;
    expect(_decode(first['Contents'] as PdfString), 'Ask about this: ünïcode ✓');
    expect(_decode(first['T'] as PdfString), 'Noel');
    expect((first['QuadPoints'] as List).length, 16); // two marks of four corners
    expect(first['C'], [0.25, 0.45, 1.0]);
    expect(first['CA'], 0.3);
    // the same words on a note icon, which is what Evince and others show
    final notes = list.where((a) => a['Subtype'] == const PdfName('Text')).toList();
    expect(notes.length, 1);
    expect(_decode(notes.single['Contents'] as PdfString), 'Ask about this: ünïcode ✓');
    expect(notes.single.containsKey('Popup'), isTrue);
    expect(highlights.last.containsKey('Contents'), isFalse);
    expect(highlights.last.containsKey('Popup'), isFalse);
    // the pop-up points back at its comment
    expect(popups.single['Parent'], isA<PdfRef>());
  });

  test('comments and an overlay together, and bad pages are refused', () {
    final merged = mergeOverlay(load('classic.pdf'), load('classic.overlay.pdf'),
        targetPages: [0, 2], comments: [const PdfComment(page: 2, rects: [[10, 10, 90, 30]], contents: 'x')]);
    final pages = PdfReader(merged).pages();
    final a = PdfReader(merged).resolve(pages[2].node['Annots']) as List;
    expect(a.length, 3); // the comment, its note and the pop-up; the overlay is page content, not an annotation
    expect(() => mergeOverlay(load('classic.pdf'), null, comments: [const PdfComment(page: 9, rects: [[0, 0, 1, 1]])]), throwsRangeError);
  });

  test('comments on every kind of page are written for checking with a viewer', () {
    for (final name in ['rotations', 'inherit', 'annots', 'objstm', 'linearized']) {
      final original = load('$name.pdf');
      final count = PdfReader(original).pages().length;
      final merged = mergeOverlay(original, null, comments: [
        for (var i = 0; i < count; i++) PdfComment(page: i, rects: const [[20, 20, 120, 50]], contents: 'on page ${i + 1}'),
      ]);
      File('${outDir.path}/$name.pdf').writeAsBytesSync(merged);
    }
  });
}
