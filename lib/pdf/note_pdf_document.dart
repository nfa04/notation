import 'package:pdfrx/pdfrx.dart';

import '../data/note_pdfs.dart';

/// The pages the editor shows for a note's PDF: those of one file, or, for a note with several PDFs, those of each file in the order the
/// note's page table gives. Page `n` here is page `n` of the note.
class NotePdfDocument {
  /// The pages, in the order they are shown. A blank page of the table has the page next to it here (it is never drawn: the paper is).
  final List<PdfPage> pages;

  /// Which file and page each one is (null: one file, in its own order).
  final List<PdfPageRef>? layout;

  final void Function()? _onDispose;
  final List<PdfDocument> _docs;

  NotePdfDocument._(this.pages, this.layout, this._onDispose, this._docs);

  /// The pages of a file shown as it is; the document is let go with it.
  factory NotePdfDocument.single(PdfDocument doc) => NotePdfDocument._(doc.pages, null, doc.dispose, [doc]);

  /// The pages of [docs] (one per file of the table, in its order) in the order of [layout]. The files stay open for whoever opened them: they
  /// are not let go with this.
  factory NotePdfDocument.table(List<PdfDocument> docs, List<PdfPageRef> layout) {
    final real = <PdfPage?>[
      for (final r in layout) r.isBlank ? null : docs[r.file].pages[r.page],
    ];
    // (a blank page is as big as the page before it, else the one after it)
    PdfPage? nearest(int i) {
      for (var k = i; k >= 0; k--) {
        if (real[k] != null) return real[k];
      }
      for (var k = i; k < real.length; k++) {
        if (real[k] != null) return real[k];
      }
      return null;
    }

    return NotePdfDocument._([for (var i = 0; i < real.length; i++) real[i] ?? nearest(i)!], layout, null, docs);
  }

  /// The outline of the files (a heading of a file that has no page shown is left out), with the page it is on in the note.
  Future<List<({String title, int level, int page})>> outline() async {
    final out = <({String title, int level, int page})>[];
    for (var f = 0; f < _docs.length; f++) {
      // (where a page of the file is shown: its place in the table, else in its own order)
      final at = <int, int>{};
      if (layout == null) {
        for (var i = 0; i < pages.length; i++) {
          at[i] = i;
        }
      } else {
        for (var i = 0; i < layout!.length; i++) {
          if (layout![i].file == f) at[layout![i].page] = i;
        }
      }
      void add(List<PdfOutlineNode> nodes, int level) {
        for (final n in nodes) {
          final page = n.dest?.pageNumber;
          final shown = page == null ? null : at[page - 1];
          if (shown != null && n.title.trim().isNotEmpty) out.add((title: n.title.trim(), level: level, page: shown));
          add(n.children, level + 1);
        }
      }

      try {
        add(await _docs[f].loadOutline(), 1);
      } catch (_) {
        // a file whose outline cannot be read has none
      }
    }
    return out;
  }

  void dispose() => _onDispose?.call();
}
