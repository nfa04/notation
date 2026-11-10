import 'link_repository.dart' show linkedNoteIds;
import 'note_data.dart';

/// What a note held when it was last loaded or saved: enough to tell, at the next save, what the save added.
class NoteHeld {
  /// The pages with something on them (an imported PDF has all of its pages).
  final int pages;
  final int highlights;

  /// The notes its text boxes and written document link to.
  final Set<String> links;

  /// The name of its PDF, or null for a note without one.
  final String? pdf;

  const NoteHeld(this.pages, this.highlights, this.links, [this.pdf]);

  factory NoteHeld.of(NoteData n) {
    var pages = 0;
    if (n.pdfPath != null) {
      pages = n.pdfPageCount ?? 1;
    }
    for (final m in [n.strokes, n.textBoxes, n.images, n.highlights]) {
      for (final e in m.entries) {
        if ((e.value as List).isNotEmpty && e.key + 1 > pages) pages = e.key + 1;
      }
    }
    return NoteHeld(
      pages < 1 ? 1 : pages,
      n.highlights.values.fold(0, (sum, l) => sum + l.length),
      {
        ...linkedNoteIds(n.documentText),
        for (final boxes in n.textBoxes.values) for (final b in boxes) ...linkedNoteIds(b.controller.text),
      },
      n.pdfPath == null ? null : (n.pdfName ?? ''),
    );
  }
}

/// What a save of note [noteId] added to it.
class NoteActivity {
  final String noteId;
  final int pagesAdded;
  final int highlightsAdded;

  /// The notes it links to now and did not before.
  final Set<String> newLinks;

  /// How many pages the note has now.
  final int pages;

  /// The note got a PDF (it had none): the name of the file.
  final String? pdfAdded;

  const NoteActivity(this.noteId, {this.pagesAdded = 0, this.highlightsAdded = 0, this.newLinks = const {}, this.pages = 1, this.pdfAdded});

  bool get any => pagesAdded > 0 || highlightsAdded > 0 || newLinks.isNotEmpty || pdfAdded != null;

  /// What [after] added to [before].
  factory NoteActivity.between(String noteId, NoteHeld before, NoteHeld after) => NoteActivity(
        noteId,
        // (a PDF that was put in is one event, not a hundred pages)
        pagesAdded: before.pdf == null && after.pdf != null ? 0 : (after.pages > before.pages ? after.pages - before.pages : 0),
        pdfAdded: before.pdf == null ? after.pdf : null,
        highlightsAdded: after.highlights > before.highlights ? after.highlights - before.highlights : 0,
        newLinks: after.links.difference(before.links),
        pages: after.pages,
      );
}
