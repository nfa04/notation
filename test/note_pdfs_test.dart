import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_pdfs.dart';

NotePdf _f(String name, int pages) => NotePdf(name: name, path: '/x/$name', sha256: 'sha-$name', pages: pages);

void main() {
  group('NotePdfs', () {
    test('puts the pages of the files one after the other, and adds files where it is told', () {
      final t = NotePdfs.inOrder([_f('a.pdf', 2), _f('b.pdf', 1)]);
      expect(t.layout.join(' '), '0:0 0:1 1:0');
      final more = t.adding([_f('c.pdf', 2)], at: 1);
      expect(more.layout.join(' '), '0:0 2:0 2:1 0:1 1:0');
      expect(more.files.map((f) => f.name), ['a.pdf', 'b.pdf', 'c.pdf']);
      expect(t.adding([_f('c.pdf', 1)], at: 99).layout.last.toString(), '2:0');
    });

    test('taking a file out takes its pages and numbers the others again', () {
      final t = NotePdfs([_f('a.pdf', 1), _f('b.pdf', 2), _f('c.pdf', 1)], const [PdfPageRef(2, 0), PdfPageRef(1, 1), PdfPageRef.blank(), PdfPageRef(0, 0), PdfPageRef(1, 0)]);
      final without = t.removing(1);
      expect(without.files.map((f) => f.name), ['a.pdf', 'c.pdf']);
      expect(without.layout.join(' '), '1:0 blank 0:0');
    });

    test('is read back as it was written, and refuses what does not fit its files', () {
      final t = NotePdfs([_f('a.pdf', 2), _f('b.pdf', 1)], const [PdfPageRef(1, 0), PdfPageRef.blank(), PdfPageRef(0, 1)]);
      final back = NotePdfs.fromJsonText(t.toJsonText())!;
      expect(back.layout, t.layout);
      expect(back.files.map((f) => f.path), ['/x/a.pdf', '/x/b.pdf']);
      Map<String, Object?> json(Object layout) => {'files': [_f('a.pdf', 2).toJson()], 'layout': layout};
      expect(NotePdfs.fromJson(json([[0, 0], [0, 1]])), isNotNull);
      expect(NotePdfs.fromJson(json([[0, 2]])), isNull, reason: 'no third page');
      expect(NotePdfs.fromJson(json([[1, 0]])), isNull, reason: 'no second file');
      expect(NotePdfs.fromJson(json([[0, 0], [0, 0]])), isNull, reason: 'a page once');
      expect(NotePdfs.fromJson(json([])), isNull);
      expect(NotePdfs.fromJson(json([[0, '0']])), isNull);
      expect(NotePdfs.fromJsonText('not json'), isNull);
      expect(NotePdfs.fromJsonText(null), isNull);
    });
  });

  test('a note file keeps several PDFs, each as a file, and the table of their pages', () {
    final table = NotePdfs([_f('a.pdf', 2), _f('b.pdf', 1)], const [PdfPageRef(1, 0), PdfPageRef.blank(), PdfPageRef(0, 1)]);
    final note = NoteData(id: 'n', title: 't', pdfName: 'a.pdf', pdfPath: '/x/a.pdf', pdfSha256: 'sha-a.pdf', pdfPageCount: 3, pdfs: table, nativePages: {1});
    final a = Uint8List.fromList(utf8.encode('first pdf')), b = Uint8List.fromList(utf8.encode('second pdf'));
    final entries = noteFileEntries(NoteFileParts(note, pdf: a, morePdfs: [b]));
    expect(entries.map((e) => e.$1), containsAll(['source.pdf', 'pdfs/1.pdf']));
    final parsed = decodeNoteFileEntries(entries);
    expect(parsed.warnings, isEmpty);
    expect(parsed.pdf, a);
    expect(parsed.morePdfs, [b]);
    final back = parsed.note.pdfs!;
    expect(back.files.map((f) => (f.name, f.pages, f.sha256)), [('a.pdf', 2, 'sha-a.pdf'), ('b.pdf', 1, 'sha-b.pdf')]);
    expect(back.layout, table.layout);
    expect(parsed.note.pdfPageCount, 3);
    expect(parsed.note.nativePages, {1});
  });

  test('a note file with one PDF has no table', () {
    final note = NoteData(id: 'n', pdfName: 'a.pdf', pdfPath: '/x/a.pdf', pdfSha256: 's', pdfPageCount: 2);
    final parsed = decodeNoteFileEntries(noteFileEntries(NoteFileParts(note, pdf: Uint8List.fromList([1, 2, 3]))));
    expect(parsed.note.pdfs, isNull);
    expect(parsed.morePdfs, isEmpty);
    expect(parsed.note.pdfPageCount, 2);
  });
}
