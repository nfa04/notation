import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../data/note_data.dart';
import '../markdown/document_export.dart' show documentMarkdown;
import '../search/search_query.dart' show InkText;

/// A note as Markdown: its written document, then every page in the order it is read (top to bottom, the things that lie side by side
/// from left to right): text boxes as they are written, what the handwriting reader made of handwriting, formulas, and pictures (as
/// files next to the text). Drawings are not in it (a picture of the page is what keeps those).
class NoteMarkdown {
  final String markdown;

  /// The files the text points at, by their path in the archive (`images/picture-1.png`).
  final Map<String, Uint8List> files;

  /// How many pieces of handwriting were put in as text (they are the reader's guess, not what was typed).
  final int handwriting;

  const NoteMarkdown(this.markdown, this.files, this.handwriting);

  /// What to save: the text alone as `.md`, or - when there are pictures - a ZIP of `<name>.md` and `images/`.
  ({Uint8List bytes, String extension}) pack(String name) {
    if (files.isEmpty) return (bytes: Uint8List.fromList(utf8.encode(markdown)), extension: 'md');
    final archive = Archive()..add(ArchiveFile.bytes('$name.md', utf8.encode(markdown)));
    for (final e in files.entries) {
      archive.add(ArchiveFile.bytes(e.key, e.value)..compression = CompressionType.none);
    }
    return (bytes: Uint8List.fromList(ZipEncoder().encodeBytes(archive)), extension: 'zip');
  }
}

/// How far apart (in page units, the page being 800 wide) two things may start vertically and still be on one line of reading.
const _sameRow = 24.0;

class _Item {
  final double top, left;
  final String text;
  const _Item(this.top, this.left, this.text);
}

/// The Markdown of [note]. [handwriting] and [formulas] are what the readers made of its handwriting (see `NoteTextRepository`);
/// [readPicture] gives the bytes of a picture of the note (null: not there, it is left out); [document] is the written document if it
/// is not the one that was saved. With [handwritingAsText] false the handwriting is left out.
Future<NoteMarkdown> noteToMarkdown(
  NoteData note, {
  List<InkText> handwriting = const [],
  List<({int page, double top, double left, String latex})> formulas = const [],
  Future<Uint8List?> Function(String path)? readPicture,
  String? document,
  bool handwritingAsText = true,
}) async {
  final out = StringBuffer();
  final files = <String, Uint8List>{};
  var inked = 0;
  void block(String text) {
    if (text.trim().isEmpty) return;
    if (out.isNotEmpty) out.write('\n\n');
    out.write(text.trim());
  }

  final title = note.title.trim();
  if (title.isNotEmpty) block('# ${title.replaceAll('\n', ' ')}');
  block(documentMarkdown(document ?? note.documentText));

  final pages = {...note.textBoxes.keys, ...note.images.keys, for (final h in handwriting) h.page, for (final f in formulas) f.page}.toList()..sort();
  final items = <int, List<_Item>>{};
  for (final page in pages) {
    final here = items[page] = [];
    for (final b in note.textBoxes[page] ?? const []) {
      final text = b.controller.text;
      if (text.trim().isNotEmpty) here.add(_Item(b.position.dy, b.position.dx, text));
    }
    for (final image in note.images[page] ?? const []) {
      final bytes = readPicture == null ? null : await readPicture(image.path);
      if (bytes == null) continue;
      final ext = p.extension(image.path).toLowerCase().replaceFirst('.', '');
      final name = 'images/picture-${files.length + 1}.${ext.isEmpty ? 'png' : ext}';
      files[name] = bytes;
      here.add(_Item(image.position.dy, image.position.dx, '![${p.basenameWithoutExtension(image.path).replaceAll(RegExp(r'[\[\]]'), '')}]($name)'));
    }
    if (handwritingAsText) {
      for (final h in handwriting) {
        if (h.page != page || h.text.trim().isEmpty) continue;
        inked++;
        here.add(_Item(h.bounds.top, h.bounds.left, h.text));
      }
    }
    for (final f in formulas) {
      if (f.page == page && f.latex.trim().isNotEmpty) here.add(_Item(f.top, f.left, '\$\$${f.latex.trim()}\$\$'));
    }
  }

  final withContent = [for (final page in pages) if (items[page]!.isNotEmpty) page];
  for (final page in withContent) {
    if (withContent.length > 1) block('## Page ${page + 1}');
    for (final text in _inReadingOrder(items[page]!)) {
      block(text);
    }
  }
  return NoteMarkdown('${out.toString()}\n', files, inked);
}

/// [items] top to bottom; what starts within [_sameRow] of the first of a row belongs to that row, left to right.
List<String> _inReadingOrder(List<_Item> items) {
  final byTop = [...items]..sort((a, b) => a.top.compareTo(b.top));
  final out = <String>[];
  var i = 0;
  while (i < byTop.length) {
    final row = [byTop[i]];
    var j = i + 1;
    while (j < byTop.length && byTop[j].top - byTop[i].top < _sameRow) {
      row.add(byTop[j++]);
    }
    row.sort((a, b) => a.left.compareTo(b.left));
    out.addAll(row.map((r) => r.text));
    i = j;
  }
  return out;
}
