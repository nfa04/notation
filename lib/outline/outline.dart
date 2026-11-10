/// One line of the table of contents of a note.
class OutlineEntry {
  final String title;

  /// 1 for the main headings, deeper for the ones under them.
  final int level;

  /// The page (zero-based) it is on.
  final int page;

  /// Where it is in the text of the written document; null: it is not in that.
  final int? at;

  const OutlineEntry(this.title, this.level, this.page, {this.at});

  @override
  bool operator ==(Object other) => other is OutlineEntry && other.title == title && other.level == level && other.page == page;

  @override
  int get hashCode => Object.hash(title, level, page);

  @override
  String toString() => 'OutlineEntry($title, $level, $page)';
}

// (a heading of the written document may start with how it is laid out: `{align=center}# Title`)
final _heading = RegExp(r'^(?:\{(?:align|indent|spacing)=[^}\n]*\})? {0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$');
final _fence = RegExp(r'^ {0,3}(```|~~~)');

/// The headings (`# Title`, up to six levels) of Markdown [text], for page [page]. Lines in a code block are not headings, nor are
/// `#` lines without a space after them (`#tag`). With [places] each says where it is in [text].
List<OutlineEntry> headingsOf(String text, int page, {bool places = false}) {
  final out = <OutlineEntry>[];
  var inCode = false;
  var next = 0;
  for (final line in text.split('\n')) {
    final at = next;
    next += line.length + 1;
    if (_fence.hasMatch(line)) {
      inCode = !inCode;
      continue;
    }
    if (inCode) continue;
    final m = _heading.firstMatch(line);
    if (m == null) continue;
    // **bold** and `code` marks are not part of how the heading reads
    final title = m.group(2)!.replaceAll(RegExp(r'[*_`]'), '').trim();
    if (title.isNotEmpty) out.add(OutlineEntry(title, m.group(1)!.length, page, at: places ? at : null));
  }
  return out;
}

/// The table of contents of a note: the headings of the written document (on page [documentPage], null: there is none) and of every
/// text box, in page order, then top to bottom within a page ([boxes] is per page, each list in reading order).
List<OutlineEntry> buildOutline({String documentText = '', int? documentPage, required Map<int, List<String>> boxes}) {
  final out = <OutlineEntry>[];
  final pages = {...boxes.keys, ?documentPage}.toList()..sort();
  for (final page in pages) {
    if (page == documentPage) out.addAll(headingsOf(documentText, page, places: true));
    for (final text in boxes[page] ?? const <String>[]) {
      out.addAll(headingsOf(text, page));
    }
  }
  return out;
}

/// [entries] with the levels made relative: the shallowest level present is 1, and a level is never more than one deeper than the
/// one before it (a `###` straight under a `#` shows as level 2).
List<OutlineEntry> tidyLevels(List<OutlineEntry> entries) {
  if (entries.isEmpty) return entries;
  final least = entries.map((e) => e.level).reduce((a, b) => a < b ? a : b);
  final out = <OutlineEntry>[];
  var previous = 0;
  for (final e in entries) {
    var level = e.level - least + 1;
    if (level > previous + 1) level = previous + 1;
    out.add(OutlineEntry(e.title, level, e.page, at: e.at));
    previous = level;
  }
  return out;
}
